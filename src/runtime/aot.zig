const std = @import("std");

pub const Tag = enum(u8) {
    undefined = 0,
    null_value = 1,
    boolean = 2,
    number = 3,
    static_utf8_string = 4,
    utf16_string = 5,
};

pub const Value = extern struct {
    tag: u8 = @intFromEnum(Tag.undefined),
    payload: u64 = 0,

    pub fn object(self: Value) ?*Object {
        if (self.tag != @intFromEnum(Tag.utf16_string) or self.payload == 0) return null;
        return @ptrFromInt(self.payload);
    }
};

pub const RootFrame = extern struct {
    previous: ?*RootFrame = null,
    values: ?[*]Value = null,
    len: usize = 0,
};

const Object = struct {
    next: ?*Object = null,
    marked: bool = false,
    kind: Tag,
    utf16: []u16,
};

const Runtime = struct {
    allocator: std.mem.Allocator,
    objects: ?*Object = null,
    roots: ?*RootFrame = null,
    object_count: usize = 0,

    fn deinit(self: *Runtime) void {
        var current = self.objects;
        while (current) |object| {
            const next = object.next;
            self.allocator.free(object.utf16);
            self.allocator.destroy(object);
            current = next;
        }
        self.* = undefined;
    }

    fn createString(self: *Runtime, units: []const u16) !Value {
        const object = try self.allocator.create(Object);
        errdefer self.allocator.destroy(object);
        object.* = .{
            .next = self.objects,
            .kind = .utf16_string,
            .utf16 = try self.allocator.dupe(u16, units),
        };
        self.objects = object;
        self.object_count += 1;
        return .{ .tag = @intFromEnum(Tag.utf16_string), .payload = @intFromPtr(object) };
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
        var reclaimed: usize = 0;
        var link = &self.objects;
        while (link.*) |object| {
            if (object.marked) {
                object.marked = false;
                link = &object.next;
                continue;
            }
            link.* = object.next;
            self.allocator.free(object.utf16);
            self.allocator.destroy(object);
            self.object_count -= 1;
            reclaimed += 1;
        }
        return reclaimed;
    }

    fn markValue(_: *Runtime, value: Value) void {
        const object = value.object() orelse return;
        object.marked = true;
    }
};

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

test "UTF-16文字列をルートから正確にmark-and-sweepする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var values = [_]Value{try runtime.createString(&.{ 0x3042, 0xd83d, 0xde00 })};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &values, values.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.collect());
    try std.testing.expectEqual(@as(usize, 1), runtime.object_count);
    try std.testing.expectEqualSlices(u16, &.{ 0x3042, 0xd83d, 0xde00 }, values[0].object().?.utf16);
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
