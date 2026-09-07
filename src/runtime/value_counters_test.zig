const std = @import("std");
const value = @import("value.zig");

test "Interpreter Runtime reports managed object, concat, and GC counters" {
    var runtime = value.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.next_collection = 64;

    var left = try runtime.stringUtf8("A");
    var right = try runtime.stringUtf8("B");
    var frame = runtime.rootFrame();
    try frame.protect(&left);
    try frame.protect(&right);
    var joined = try runtime.concatStrings(left.string, right.string);
    try frame.protect(&joined);

    const header_bytes = @as(u64, @sizeOf(value.String));
    try std.testing.expectEqual(@as(u64, 3), runtime.counters.allocations);
    try std.testing.expectEqual(header_bytes * 3 + 8, runtime.counters.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 3), runtime.counters.string_payload_allocations);
    try std.testing.expectEqual(@as(u64, 8), runtime.counters.string_payload_bytes);
    try std.testing.expectEqual(@as(u64, 1), runtime.counters.concat_calls);
    try std.testing.expectEqual(@as(u64, 4), runtime.counters.concat_output_bytes);
    try std.testing.expectEqual(@as(u64, 3), runtime.counters.object_high_water);

    _ = try runtime.collect();
    try std.testing.expectEqual(@as(u64, 1), runtime.counters.gc_collections);
    try std.testing.expectEqual(@as(u64, 3), runtime.counters.gc_scanned_objects);
    try std.testing.expectEqual(header_bytes * 3, runtime.counters.gc_scanned_bytes);

    frame.deinit();
    _ = try runtime.collect();
    try std.testing.expectEqual(@as(u64, 3), runtime.counters.gc_reclaimed_objects);
    try std.testing.expectEqual(header_bytes * 3, runtime.counters.gc_reclaimed_bytes);
}
