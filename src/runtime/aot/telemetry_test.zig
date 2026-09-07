const std = @import("std");
const runtime_core = @import("runtime_core.zig");

test "AOT telemetry activation OOM falls back to the base allocator" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var runtime = runtime_core.Runtime{ .allocator = failing.allocator() };
    defer runtime.deinit();
    runtime.perf_counters_checked = true;
    runtime.perf_counters_enabled = true;

    try runtime.ensureAllocatorTelemetry();
    try std.testing.expect(runtime.allocator_telemetry == null);
    try std.testing.expect(runtime.allocator_telemetry_checked);
    try std.testing.expectEqual(@as(u64, 0), runtime.counters.allocator_telemetry_active);
    try std.testing.expectEqual(@as(u64, 1), runtime.counters.allocator_telemetry_init_failures);

    failing.fail_index = std.math.maxInt(usize);
    _ = try runtime.createString(&.{'A'});
}
