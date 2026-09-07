const std = @import("std");

/// Lightweight per-execution diagnostic counters. These are intentionally
/// kept outside the hot allocation path so that the runtime can aggregate
/// events without disturbing the behavior it is measuring.
pub const Counters = struct {
    pub const AotEntryCounters = struct {
        calls: u64 = 0,
        successes: u64 = 0,
        failures: u64 = 0,

        pub fn add(self: *AotEntryCounters, other: AotEntryCounters) void {
            self.calls +|= other.calls;
            self.successes +|= other.successes;
            self.failures +|= other.failures;
        }
    };

    dictionary_probes: u64 = 0,
    dictionary_hits: u64 = 0,
    dictionary_misses: u64 = 0,
    dictionary_linear_steps: u64 = 0,
    dictionary_index_lookups: u64 = 0,
    dictionary_entry_comparisons: u64 = 0,
    dictionary_index_rebuilds: u64 = 0,
    array_appends: u64 = 0,
    array_grows: u64 = 0,
    array_copied_bytes: u64 = 0,
    /// `allocations`/`allocated_bytes` below count managed object structures
    /// and their accounted payloads. These fields count allocator vtable
    /// operations observed by the optional runtime telemetry wrapper.
    allocator_alloc_calls: u64 = 0,
    allocator_resize_calls: u64 = 0,
    allocator_remap_calls: u64 = 0,
    allocator_free_calls: u64 = 0,
    allocator_live_bytes: u64 = 0,
    allocator_peak_live_bytes: u64 = 0,
    /// 1 when this counter context owns an active telemetry wrapper. A
    /// borrowed child remains 0 and is measured by its outer context.
    allocator_telemetry_active: u64 = 0,
    allocator_telemetry_init_failures: u64 = 0,
    allocations: u64 = 0,
    allocated_bytes: u64 = 0,
    /// String concatenations and their newly-owned UTF-16 output payload.
    concat_calls: u64 = 0,
    concat_output_bytes: u64 = 0,
    /// Counts UTF-16 payload allocations separately from object headers.
    /// Fused Object+payload allocations count once here as well.
    string_payload_allocations: u64 = 0,
    string_payload_bytes: u64 = 0,
    string_conversions: u64 = 0,
    numeric_conversions: u64 = 0,
    value_copies: u64 = 0,
    frame_pools_hits: u64 = 0,
    frame_pools_misses: u64 = 0,
    root_pushes: u64 = 0,
    root_high_water: u64 = 0,
    object_high_water: u64 = 0,
    object_pool_hits: u64 = 0,
    object_pool_misses: u64 = 0,
    gc_collections: u64 = 0,
    /// Objects visited by the mark phase.  Scanned bytes cover the Object
    /// header visited by the collector; inline UTF-16 units contain no roots.
    gc_scanned_objects: u64 = 0,
    gc_scanned_bytes: u64 = 0,
    gc_reclaimed_objects: u64 = 0,
    gc_reclaimed_bytes: u64 = 0,
    /// Optional AOT entry telemetry.  Each route is counted separately so a
    /// specialized ABI and its generic fallback are never conflated.
    aot_generic_builtin: AotEntryCounters = .{},
    aot_index_get: AotEntryCounters = .{},
    aot_index_set: AotEntryCounters = .{},
    aot_math_f64: AotEntryCounters = .{},
    aot_math_value: AotEntryCounters = .{},
    aot_unicode_length: AotEntryCounters = .{},
    /// Nanoseconds spent in GC mark traversal and sweep, respectively.  They
    /// remain zero unless allocator telemetry is enabled.
    gc_mark_ns: u64 = 0,
    gc_sweep_ns: u64 = 0,

    pub fn add(self: *Counters, other: Counters) void {
        self.dictionary_probes +|= other.dictionary_probes;
        self.dictionary_hits +|= other.dictionary_hits;
        self.dictionary_misses +|= other.dictionary_misses;
        self.dictionary_linear_steps +|= other.dictionary_linear_steps;
        self.dictionary_index_lookups +|= other.dictionary_index_lookups;
        self.dictionary_entry_comparisons +|= other.dictionary_entry_comparisons;
        self.dictionary_index_rebuilds +|= other.dictionary_index_rebuilds;
        self.array_appends +|= other.array_appends;
        self.array_grows +|= other.array_grows;
        self.array_copied_bytes +|= other.array_copied_bytes;
        self.allocator_alloc_calls +|= other.allocator_alloc_calls;
        self.allocator_resize_calls +|= other.allocator_resize_calls;
        self.allocator_remap_calls +|= other.allocator_remap_calls;
        self.allocator_free_calls +|= other.allocator_free_calls;
        self.allocator_live_bytes +|= other.allocator_live_bytes;
        self.allocator_peak_live_bytes +|= other.allocator_peak_live_bytes;
        self.allocator_telemetry_active = @max(self.allocator_telemetry_active, other.allocator_telemetry_active);
        self.allocator_telemetry_init_failures +|= other.allocator_telemetry_init_failures;
        self.allocations +|= other.allocations;
        self.allocated_bytes +|= other.allocated_bytes;
        self.concat_calls +|= other.concat_calls;
        self.concat_output_bytes +|= other.concat_output_bytes;
        self.string_payload_allocations +|= other.string_payload_allocations;
        self.string_payload_bytes +|= other.string_payload_bytes;
        self.string_conversions +|= other.string_conversions;
        self.numeric_conversions +|= other.numeric_conversions;
        self.value_copies +|= other.value_copies;
        self.frame_pools_hits +|= other.frame_pools_hits;
        self.frame_pools_misses +|= other.frame_pools_misses;
        self.root_pushes +|= other.root_pushes;
        self.root_high_water +|= other.root_high_water;
        self.object_high_water +|= other.object_high_water;
        self.object_pool_hits +|= other.object_pool_hits;
        self.object_pool_misses +|= other.object_pool_misses;
        self.gc_collections +|= other.gc_collections;
        self.gc_scanned_objects +|= other.gc_scanned_objects;
        self.gc_scanned_bytes +|= other.gc_scanned_bytes;
        self.gc_reclaimed_objects +|= other.gc_reclaimed_objects;
        self.gc_reclaimed_bytes +|= other.gc_reclaimed_bytes;
        self.aot_generic_builtin.add(other.aot_generic_builtin);
        self.aot_index_get.add(other.aot_index_get);
        self.aot_index_set.add(other.aot_index_set);
        self.aot_math_f64.add(other.aot_math_f64);
        self.aot_math_value.add(other.aot_math_value);
        self.aot_unicode_length.add(other.aot_unicode_length);
        self.gc_mark_ns +|= other.gc_mark_ns;
        self.gc_sweep_ns +|= other.gc_sweep_ns;
    }
};

test "Counters add saturates" {
    var a: Counters = .{ .dictionary_probes = 10, .dictionary_hits = 5, .concat_calls = 1, .gc_scanned_objects = 2, .allocator_alloc_calls = 2, .allocator_telemetry_active = 1, .allocator_telemetry_init_failures = 2, .gc_mark_ns = 4, .aot_math_f64 = .{ .calls = 1, .successes = 1 } };
    const b: Counters = .{ .dictionary_probes = 3, .dictionary_misses = 2, .concat_calls = 4, .gc_scanned_objects = 3, .allocator_alloc_calls = 3, .allocator_telemetry_active = 1, .allocator_telemetry_init_failures = 3, .gc_mark_ns = 6, .aot_math_f64 = .{ .calls = 2, .failures = 1 } };
    a.add(b);
    try std.testing.expectEqual(@as(u64, 13), a.dictionary_probes);
    try std.testing.expectEqual(@as(u64, 5), a.dictionary_hits);
    try std.testing.expectEqual(@as(u64, 2), a.dictionary_misses);
    try std.testing.expectEqual(@as(u64, 5), a.concat_calls);
    try std.testing.expectEqual(@as(u64, 5), a.gc_scanned_objects);
    try std.testing.expectEqual(@as(u64, 5), a.allocator_alloc_calls);
    try std.testing.expectEqual(@as(u64, 1), a.allocator_telemetry_active);
    try std.testing.expectEqual(@as(u64, 5), a.allocator_telemetry_init_failures);
    try std.testing.expectEqual(@as(u64, 10), a.gc_mark_ns);
    try std.testing.expectEqual(@as(u64, 3), a.aot_math_f64.calls);
    try std.testing.expectEqual(@as(u64, 1), a.aot_math_f64.successes);
    try std.testing.expectEqual(@as(u64, 1), a.aot_math_f64.failures);
}
