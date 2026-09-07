const std = @import("std");
const environment = @import("environment.zig");

/// Environment variable that enables allocator-operation and GC phase timing
/// diagnostics.  The existing `LNAKO_PERF_COUNTERS=1` switch also enables the
/// telemetry so one perf-counter run contains the complete runtime picture.
pub const env_name = "LNAKO_ALLOCATOR_TELEMETRY";

pub fn enabled() bool {
    return environment.valueEquals(env_name, "1") or environment.valueEquals("LNAKO_PERF_COUNTERS", "1");
}

/// Monotonic timestamp used only while telemetry is enabled.
pub fn nowNs() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

pub const Snapshot = struct {
    /// Allocator operation counts are separate from Counters.allocations,
    /// which counts managed object structures.
    alloc_calls: u64 = 0,
    resize_calls: u64 = 0,
    remap_calls: u64 = 0,
    free_calls: u64 = 0,
    /// Bytes currently owned by allocations observed after wrapper activation.
    live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,
    gc_mark_ns: u64 = 0,
    gc_sweep_ns: u64 = 0,
};

/// A stable allocator wrapper context.  Runtime values are copied when the
/// AOT global runtime is installed, so this state must not live inside Runtime
/// itself.  The underlying allocator is retained here and all callbacks use it
/// directly, avoiding recursion through the wrapper.
pub const Telemetry = struct {
    base: std.mem.Allocator,
    metrics: Snapshot = .{},
    /// Allocations made before wrapper activation are still freed through the
    /// wrapper during Runtime teardown.  Keep only allocations observed by
    /// this wrapper so those unknown frees cannot subtract from live bytes.
    observed_allocations: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(base: std.mem.Allocator) !*Telemetry {
        const self = try base.create(Telemetry);
        self.* = .{ .base = base };
        return self;
    }

    pub fn allocator(self: *Telemetry) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn isTelemetryAllocator(candidate: std.mem.Allocator) bool {
        return candidate.vtable == &vtable;
    }

    pub fn snapshot(self: *const Telemetry) Snapshot {
        return self.metrics;
    }

    pub fn recordMarkNs(self: *Telemetry, elapsed_ns: u64) void {
        self.metrics.gc_mark_ns +|= elapsed_ns;
    }

    pub fn recordSweepNs(self: *Telemetry, elapsed_ns: u64) void {
        self.metrics.gc_sweep_ns +|= elapsed_ns;
    }

    pub fn deinit(self: *Telemetry) void {
        self.observed_allocations.deinit(self.base);
        self.base.destroy(self);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Telemetry = @ptrCast(@alignCast(context));
        const result = self.base.rawAlloc(len, alignment, ret_addr);
        self.metrics.alloc_calls +|= 1;
        if (result) |pointer| self.noteAllocation(pointer, len);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Telemetry = @ptrCast(@alignCast(context));
        const result = self.base.rawResize(memory, alignment, new_len, ret_addr);
        self.metrics.resize_calls +|= 1;
        if (result) self.noteResize(memory, new_len);
        return result;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Telemetry = @ptrCast(@alignCast(context));
        const result = self.base.rawRemap(memory, alignment, new_len, ret_addr);
        self.metrics.remap_calls +|= 1;
        if (result) |pointer| self.noteRemap(memory, pointer, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Telemetry = @ptrCast(@alignCast(context));
        self.base.rawFree(memory, alignment, ret_addr);
        self.metrics.free_calls +|= 1;
        if (self.observed_allocations.fetchRemove(@intFromPtr(memory.ptr))) |entry| {
            self.metrics.live_bytes -|= @as(u64, @intCast(entry.value));
        }
    }

    fn noteAllocation(self: *Telemetry, pointer: [*]u8, len: usize) void {
        if (len == 0) return;
        self.observed_allocations.put(self.base, @intFromPtr(pointer), len) catch return;
        self.metrics.live_bytes +|= @as(u64, @intCast(len));
        self.metrics.peak_live_bytes = @max(self.metrics.peak_live_bytes, self.metrics.live_bytes);
    }

    fn noteResize(self: *Telemetry, memory: []u8, new_len: usize) void {
        const size = self.observed_allocations.getPtr(@intFromPtr(memory.ptr)) orelse return;
        self.adjustLive(size.*, new_len);
        size.* = new_len;
    }

    fn noteRemap(self: *Telemetry, memory: []u8, pointer: [*]u8, new_len: usize) void {
        const old_key = @intFromPtr(memory.ptr);
        const old_size = self.observed_allocations.fetchRemove(old_key) orelse return;
        self.adjustLive(old_size.value, 0);
        if (new_len == 0) return;
        self.observed_allocations.put(self.base, @intFromPtr(pointer), new_len) catch return;
        self.metrics.live_bytes +|= @as(u64, @intCast(new_len));
        self.metrics.peak_live_bytes = @max(self.metrics.peak_live_bytes, self.metrics.live_bytes);
    }

    fn adjustLive(self: *Telemetry, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            self.metrics.live_bytes +|= @as(u64, @intCast(new_len - old_len));
        } else {
            self.metrics.live_bytes -|= @as(u64, @intCast(old_len - new_len));
        }
        self.metrics.peak_live_bytes = @max(self.metrics.peak_live_bytes, self.metrics.live_bytes);
    }
};

test "allocator telemetry tracks operations and live bytes" {
    var telemetry = try Telemetry.init(std.testing.allocator);
    defer telemetry.deinit();
    const allocator = telemetry.allocator();

    var bytes = try allocator.alloc(u8, 8);
    try std.testing.expectEqual(@as(u64, 1), telemetry.snapshot().alloc_calls);
    try std.testing.expectEqual(@as(u64, 8), telemetry.snapshot().live_bytes);

    if (allocator.resize(bytes, 12)) bytes = bytes.ptr[0..12];
    try std.testing.expectEqual(@as(u64, 1), telemetry.snapshot().resize_calls);

    if (allocator.remap(bytes, 16)) |remapped| {
        bytes = remapped[0..16];
    }
    try std.testing.expectEqual(@as(u64, 1), telemetry.snapshot().remap_calls);
    allocator.free(bytes);

    const snapshot = telemetry.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.free_calls);
    try std.testing.expectEqual(@as(u64, 0), snapshot.live_bytes);
    try std.testing.expect(snapshot.peak_live_bytes >= 8);
}

test "allocator telemetry accumulates GC phase durations" {
    var telemetry = try Telemetry.init(std.testing.allocator);
    defer telemetry.deinit();
    telemetry.recordMarkNs(3);
    telemetry.recordMarkNs(5);
    telemetry.recordSweepNs(7);
    const snapshot = telemetry.snapshot();
    try std.testing.expectEqual(@as(u64, 8), snapshot.gc_mark_ns);
    try std.testing.expectEqual(@as(u64, 7), snapshot.gc_sweep_ns);
}

test "late activation ignores unknown frees when tracking observed live bytes" {
    const base = std.testing.allocator;
    const preexisting = try base.alloc(u8, 24);
    var telemetry = try Telemetry.init(base);
    defer telemetry.deinit();
    const allocator = telemetry.allocator();

    const observed = try allocator.alloc(u8, 7);
    try std.testing.expectEqual(@as(u64, 7), telemetry.snapshot().live_bytes);

    allocator.free(preexisting);
    try std.testing.expectEqual(@as(u64, 7), telemetry.snapshot().live_bytes);
    allocator.free(observed);
    try std.testing.expectEqual(@as(u64, 0), telemetry.snapshot().live_bytes);
}
