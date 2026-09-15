const std = @import("std");
const allocator_telemetry = @import("../allocator_telemetry.zig");
const runtime_core = @import("runtime_core.zig");

const Value = runtime_core.Value;
const Object = runtime_core.Object;
const RootFrame = runtime_core.RootFrame;
const Runtime = runtime_core.Runtime;

test "AOT文字列はObjectとUTF-16 payloadを一体確保しGCで一体解放する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();

    const allocation = try runtime.allocString(3);
    @memcpy(allocation.units, &[_]u16{ 'A', 0xd83d, 0xde00 });
    var roots = [_]Value{allocation.value};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const object = allocation.value.object().?;
    try std.testing.expect(object.inline_utf16);
    try std.testing.expectEqual(@as(usize, @sizeOf(Object) + 3 * @sizeOf(u16)), @sizeOf(Object) + object.payload.utf16_string.len * @sizeOf(u16));
    try std.testing.expectEqualSlices(u16, &.{ 'A', 0xd83d, 0xde00 }, object.payload.utf16_string);
    try std.testing.expectEqual(@as(u64, 1), runtime.counters.allocations);
    try std.testing.expectEqual(@as(u64, @sizeOf(Object) + 6), runtime.counters.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 1), runtime.counters.string_payload_allocations);
    try std.testing.expectEqual(@as(u64, 6), runtime.counters.string_payload_bytes);
    try std.testing.expectEqual(@as(usize, 0), runtime.collect());
    // The string payload has no child references, but the Object itself is
    // still visited once by the mark queue.
    try std.testing.expectEqual(@as(u64, 1), runtime.counters.gc_scanned_objects);
    try std.testing.expectEqual(@as(u64, @sizeOf(Object)), runtime.counters.gc_scanned_bytes);

    roots[0] = .{};
    try std.testing.expectEqual(@as(usize, 1), runtime.collect());
}

test "AOT createString copies borrowed unrooted units before collection" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const original = try runtime.createString(&.{ 'A', 0xd83d, 0xde00 });
    runtime.next_collection = 0;
    const copied = try runtime.createString(original.object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 0xd83d, 0xde00 }, copied.object().?.payload.utf16_string);
    try std.testing.expectEqual(@as(usize, 1), runtime.object_count);
    try std.testing.expectEqual(@as(u64, 1), runtime.counters.gc_collections);
}

test "AOT Runtime移動後もallocator telemetry contextを保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    const telemetry = try allocator_telemetry.Telemetry.init(std.testing.allocator);
    runtime.allocator_telemetry = telemetry;
    runtime.allocator_telemetry_checked = true;
    runtime.allocator = telemetry.allocator();

    _ = try runtime.createString(&.{'A'});
    var moved = runtime;
    runtime = undefined;
    _ = try moved.createString(&.{ 'B', 'C' });
    moved.syncAllocatorTelemetry();

    try std.testing.expect(moved.counters.allocator_alloc_calls > 0);
    try std.testing.expect(moved.counters.allocator_peak_live_bytes > 0);
    try std.testing.expect(moved.allocator.ptr == telemetry.allocator().ptr);
    moved.deinit();
}
