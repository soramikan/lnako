const counters = @import("counters.zig");

/// Managed counters deliberately describe GC-managed object structures, not
/// every allocator operation. Interpreter objects keep payload buffers in
/// separate allocations, so callers pass the concrete object structure size
/// plus logical UTF-16 payload; allocator telemetry remains the source for
/// total bytes.
pub fn recordObject(result: *counters.Counters, object_bytes: usize, utf16_units: ?usize) void {
    result.allocations +|= 1;
    result.allocated_bytes +|= @as(u64, @intCast(object_bytes));
    if (utf16_units) |units| {
        const payload_bytes = @as(u64, @intCast(units)) *| @as(u64, @sizeOf(u16));
        result.string_payload_allocations +|= 1;
        result.string_payload_bytes +|= payload_bytes;
        result.allocated_bytes +|= payload_bytes;
    }
}

pub fn recordConcat(result: *counters.Counters, utf16_units: usize) void {
    result.concat_calls +|= 1;
    result.concat_output_bytes +|= @as(u64, @intCast(utf16_units)) *| @as(u64, @sizeOf(u16));
}

pub fn recordGcScan(result: *counters.Counters, object_bytes: usize) void {
    result.gc_scanned_objects +|= 1;
    result.gc_scanned_bytes +|= @as(u64, @intCast(object_bytes));
}

pub fn recordGcReclaim(result: *counters.Counters, object_bytes: usize) void {
    result.gc_reclaimed_objects +|= 1;
    result.gc_reclaimed_bytes +|= @as(u64, @intCast(object_bytes));
}

test "managed value counter helpers account object and UTF-16 payload separately" {
    var result: counters.Counters = .{};
    recordObject(&result, 16, 3);
    recordConcat(&result, 2);
    recordGcScan(&result, 16);
    recordGcReclaim(&result, 16);
    try @import("std").testing.expectEqual(@as(u64, 1), result.allocations);
    try @import("std").testing.expectEqual(@as(u64, 22), result.allocated_bytes);
    try @import("std").testing.expectEqual(@as(u64, 1), result.string_payload_allocations);
    try @import("std").testing.expectEqual(@as(u64, 6), result.string_payload_bytes);
    try @import("std").testing.expectEqual(@as(u64, 1), result.concat_calls);
    try @import("std").testing.expectEqual(@as(u64, 4), result.concat_output_bytes);
    try @import("std").testing.expectEqual(@as(u64, 1), result.gc_scanned_objects);
    try @import("std").testing.expectEqual(@as(u64, 16), result.gc_scanned_bytes);
    try @import("std").testing.expectEqual(@as(u64, 1), result.gc_reclaimed_objects);
    try @import("std").testing.expectEqual(@as(u64, 16), result.gc_reclaimed_bytes);
}
