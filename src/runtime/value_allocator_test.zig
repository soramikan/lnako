const std = @import("std");
const Runtime = @import("value.zig").Runtime;
const allocator_telemetry = @import("allocator_telemetry.zig");

fn sameAllocator(left: std.mem.Allocator, right: std.mem.Allocator) bool {
    return left.ptr == right.ptr and left.vtable == right.vtable;
}

test "InterpreterはRuntimeと同じbase allocatorだけtelemetryを共有する" {
    const base = std.testing.allocator;
    const telemetry = try allocator_telemetry.Telemetry.init(base);
    defer telemetry.deinit();
    var runtime: Runtime = .{
        .backing_allocator = telemetry.allocator(),
        .allocator_telemetry = telemetry,
        .allocator_telemetry_checked = true,
    };

    const shared = runtime.allocatorForInterpreter(base);
    try std.testing.expect(sameAllocator(shared, telemetry.allocator()));
    try std.testing.expect(sameAllocator(runtime.allocatorForInterpreter(telemetry.allocator()), telemetry.allocator()));

    var storage: [32]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const separate = fixed.allocator();
    try std.testing.expect(sameAllocator(runtime.allocatorForInterpreter(separate), separate));
}

test "Runtime init reuses an existing telemetry allocator without nesting" {
    const telemetry = try allocator_telemetry.Telemetry.init(std.testing.allocator);
    defer telemetry.deinit();
    const before = telemetry.snapshot().alloc_calls;
    var runtime = Runtime.init(telemetry.allocator());
    defer runtime.deinit();

    try std.testing.expectEqual(before, telemetry.snapshot().alloc_calls);
    _ = try runtime.stringUtf8("nested");
    try std.testing.expect(telemetry.snapshot().alloc_calls > before);
}

fn failureMessageUtf8AllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    try runtime.custom_failure_message.appendSlice(allocator, "old");
    try runtime.custom_failure_message_units.appendSlice(allocator, &.{ 'o', 'l', 'd' });
    runtime.setFailureMessage("新しい文言") catch |failure| {
        try std.testing.expectEqual(@as(usize, 0), runtime.custom_failure_message.items.len);
        try std.testing.expectEqual(@as(usize, 0), runtime.custom_failure_message_units.items.len);
        return failure;
    };
    try std.testing.expectEqualStrings("新しい文言", runtime.custom_failure_message.items);
}

test "UTF-8例外文言は変換失敗時に古い文言を残さない" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failureMessageUtf8AllocationTest, .{});
}
