const std = @import("std");
const BigInt = @import("bigint.zig").BigInt;

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
};

pub const Value = extern struct {
    tag: u8 = @intFromEnum(Tag.undefined),
    payload: u64 = 0,

    pub fn object(self: Value) ?*Object {
        if (self.payload == 0) return null;
        return switch (@as(Tag, @enumFromInt(self.tag))) {
            .utf16_string, .array, .dictionary, .iterator, .bigint => @ptrFromInt(self.payload),
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

const BigIntArithmetic = enum(u8) {
    add,
    subtract,
    multiply,
    divide,
    remainder,
    power,
    integer_divide,
};

const BigIntComparison = enum(u8) {
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

    fn deinit(self: *Runtime) void {
        var current = self.objects;
        while (current) |object| {
            const next = object.next;
            self.destroyObject(object);
            current = next;
        }
        self.* = undefined;
    }

    fn createString(self: *Runtime, units: []const u16) !Value {
        try self.beforeAllocation();
        const owned = try self.allocator.dupe(u16, units);
        errdefer self.allocator.free(owned);
        return self.createObject(.{ .utf16_string = owned }, .utf16_string);
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
        while (self.grey) |object| {
            self.grey = object.grey_next;
            object.grey_next = null;
            switch (object.payload) {
                .utf16_string, .bigint => {},
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

    fn destroyObject(self: *Runtime, object: *Object) void {
        switch (object.payload) {
            .utf16_string => |units| self.allocator.free(units),
            .bigint => |*value| value.deinit(),
            .array => |*items| items.deinit(self.allocator),
            .dictionary => |*entries| entries.deinit(self.allocator),
            .iterator => {},
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

fn bigIntArithmetic(runtime: *Runtime, operator: BigIntArithmetic, left: Value, right: Value) !Value {
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

fn bigIntComparison(runtime: *Runtime, operator: BigIntComparison, left: Value, right: Value) !bool {
    const left_is_bigint = left.tag == @intFromEnum(Tag.bigint);
    const right_is_bigint = right.tag == @intFromEnum(Tag.bigint);
    if (!left_is_bigint and !right_is_bigint) return error.ExpectedBigInt;
    const strict = operator == .strict_equal or operator == .strict_not_equal;
    const equality = operator == .abstract_equal or operator == .strict_equal or operator == .abstract_not_equal or operator == .strict_not_equal;
    if (equality) {
        const equal = if (left_is_bigint and right_is_bigint)
            BigInt.eql(left.object().?.payload.bigint, right.object().?.payload.bigint)
        else if (strict)
            false
        else if (left_is_bigint)
            try bigIntEqualsNumber(runtime, left.object().?.payload.bigint, valueToNumber(right))
        else
            try bigIntEqualsNumber(runtime, right.object().?.payload.bigint, valueToNumber(left));
        return if (operator == .abstract_not_equal or operator == .strict_not_equal) !equal else equal;
    }
    const order = if (left_is_bigint and right_is_bigint)
        BigInt.order(left.object().?.payload.bigint, right.object().?.payload.bigint)
    else if (left_is_bigint)
        (try compareBigIntNumber(runtime, left.object().?.payload.bigint, valueToNumber(right))) orelse return false
    else
        invertOrder((try compareBigIntNumber(runtime, right.object().?.payload.bigint, valueToNumber(left))) orelse return false);
    return switch (operator) {
        .less => order == .lt,
        .less_equal => order != .gt,
        .greater => order == .gt,
        .greater_equal => order != .lt,
        else => unreachable,
    };
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
        .array, .dictionary, .iterator => left.payload == right.payload,
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

pub export fn lnako_aot_bigint_truthy(value: *const Value) callconv(.c) c_int {
    const object = value.object() orelse return 0;
    if (object.payload != .bigint) return 0;
    return @intFromBool(!object.payload.bigint.isZero());
}

pub export fn lnako_aot_bigint_arithmetic(out: *Value, left: *const Value, right: *const Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(BigIntArithmetic, opcode) orelse runtimeFailure(error.InvalidBigIntOperator);
    out.* = bigIntArithmetic(runtime, operator, left.*, right.*) catch |failure| runtimeFailure(failure);
}

pub export fn lnako_aot_bigint_compare(out: *Value, left: *const Value, right: *const Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(BigIntComparison, opcode) orelse runtimeFailure(error.InvalidBigIntComparison);
    out.* = .{
        .tag = @intFromEnum(Tag.boolean),
        .payload = @intFromBool(bigIntComparison(runtime, operator, left.*, right.*) catch |failure| runtimeFailure(failure)),
    };
}

pub export fn lnako_aot_shift(out: *Value, left: *const Value, right: *const Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(ShiftOperator, opcode) orelse runtimeFailure(error.InvalidShiftOperator);
    out.* = shift(runtime, operator, left.*, right.*) catch |failure| runtimeFailure(failure);
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

pub export fn lnako_aot_iterator_new(out: *Value, values: ?[*]const Value, len: usize, is_range: bool, direction: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*value| value else return;
    const source = if (values) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createIterator(source, is_range, direction) catch return;
}

pub export fn lnako_aot_iterator_has_next(iterator: *const Value) callconv(.c) c_int {
    return if (active_runtime) |*runtime| @intFromBool(runtime.iteratorHasNext(iterator.*)) else 0;
}

pub export fn lnako_aot_iterator_next(out: *Value, iterator: *const Value, repeat_target: ?*Value, value_target: ?*Value, key_target: ?*Value, range_target: ?*Value) callconv(.c) void {
    out.* = if (active_runtime) |*runtime| runtime.iteratorNext(iterator.*, repeat_target, value_target, key_target, range_target) else .{};
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
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value, u8) callconv(.c) void, @TypeOf(&lnako_aot_bigint_arithmetic));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value, u8) callconv(.c) void, @TypeOf(&lnako_aot_bigint_compare));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value, u8) callconv(.c) void, @TypeOf(&lnako_aot_shift));
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

test "AOT BigInt比較をNumberとの間でも精度を落とさず処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const bigint = try runtime.createBigInt("9007199254740993n");
    try std.testing.expect(try bigIntComparison(&runtime, .greater, bigint, numberValue(9007199254740992.0)));
    try std.testing.expect(try bigIntComparison(&runtime, .abstract_equal, try runtime.createBigInt("1n"), numberValue(1)));
    try std.testing.expect(!(try bigIntComparison(&runtime, .strict_equal, try runtime.createBigInt("1n"), numberValue(1))));
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
}

fn numberValue(number: f64) Value {
    return .{ .tag = @intFromEnum(Tag.number), .payload = @bitCast(number) };
}

fn staticStringValue(comptime text: [:0]const u8) Value {
    return .{ .tag = @intFromEnum(Tag.static_utf8_string), .payload = @intFromPtr(text.ptr) };
}
