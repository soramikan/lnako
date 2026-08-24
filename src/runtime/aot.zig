const std = @import("std");

pub const Tag = enum(u8) {
    undefined = 0,
    null_value = 1,
    boolean = 2,
    number = 3,
    static_utf8_string = 4,
    utf16_string = 5,
    array = 6,
    dictionary = 7,
};

pub const Value = extern struct {
    tag: u8 = @intFromEnum(Tag.undefined),
    payload: u64 = 0,

    pub fn object(self: Value) ?*Object {
        if (self.payload == 0) return null;
        return switch (@as(Tag, @enumFromInt(self.tag))) {
            .utf16_string, .array, .dictionary => @ptrFromInt(self.payload),
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

const Payload = union(enum) {
    utf16_string: []u16,
    array: std.ArrayList(Value),
    dictionary: std.ArrayList(DictionaryEntry),
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
                .utf16_string => {},
                .array => |items| for (items.items) |value| self.markValue(value),
                .dictionary => |entries| for (entries.items) |entry| {
                    self.markValue(entry.key);
                    self.markValue(entry.value);
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
            .array => |*items| items.deinit(self.allocator),
            .dictionary => |*entries| entries.deinit(self.allocator),
        }
        self.allocator.destroy(object);
    }

    fn indexGet(_: *Runtime, container: Value, key: Value) Value {
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

fn sameKey(left: Value, right: Value) bool {
    if (left.tag != right.tag) return false;
    return switch (@as(Tag, @enumFromInt(left.tag))) {
        .undefined, .null_value => true,
        .boolean, .number => left.payload == right.payload,
        .static_utf8_string => std.mem.eql(u8, staticUtf8(left), staticUtf8(right)),
        .utf16_string => std.mem.eql(u16, left.object().?.payload.utf16_string, right.object().?.payload.utf16_string),
        .array, .dictionary => left.payload == right.payload,
    };
}

fn staticUtf8(value: Value) []const u8 {
    const pointer: [*:0]const u8 = @ptrFromInt(value.payload);
    return std.mem.span(pointer);
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

pub export fn lnako_aot_string_new(units: ?[*]const u16, len: usize) callconv(.c) Value {
    const runtime = if (active_runtime) |*value| value else return .{};
    const source = if (units) |pointer| pointer[0..len] else if (len == 0) &.{} else return .{};
    return runtime.createString(source) catch .{};
}

pub export fn lnako_aot_array_new(values: ?[*]const Value, len: usize) callconv(.c) Value {
    const runtime = if (active_runtime) |*value| value else return .{};
    const source = if (values) |pointer| pointer[0..len] else if (len == 0) &.{} else return .{};
    return runtime.createArray(source) catch .{};
}

pub export fn lnako_aot_dictionary_new(values: ?[*]const Value, len: usize) callconv(.c) Value {
    const runtime = if (active_runtime) |*value| value else return .{};
    const source = if (values) |pointer| pointer[0..len] else if (len == 0) &.{} else return .{};
    return runtime.createDictionary(source) catch .{};
}

pub export fn lnako_aot_index_get(container: Value, key: Value) callconv(.c) Value {
    return if (active_runtime) |*runtime| runtime.indexGet(container, key) else .{};
}

pub export fn lnako_aot_index_set(container: Value, key: Value, value: Value) callconv(.c) c_int {
    const runtime = if (active_runtime) |*active| active else return -1;
    runtime.indexSet(container, key, value) catch return -1;
    return 0;
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

fn numberValue(number: f64) Value {
    return .{ .tag = @intFromEnum(Tag.number), .payload = @bitCast(number) };
}

fn staticStringValue(comptime text: [:0]const u8) Value {
    return .{ .tag = @intFromEnum(Tag.static_utf8_string), .payload = @intFromPtr(text.ptr) };
}
