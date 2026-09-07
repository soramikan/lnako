const std = @import("std");

/// Lightweight per-execution diagnostic counters. These are intentionally
/// kept outside the hot allocation path so that the runtime can aggregate
/// events without disturbing the behavior it is measuring.
pub const Counters = struct {
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
    }
};

test "Counters add saturates" {
    var a: Counters = .{ .dictionary_probes = 10, .dictionary_hits = 5, .concat_calls = 1, .gc_scanned_objects = 2 };
    const b: Counters = .{ .dictionary_probes = 3, .dictionary_misses = 2, .concat_calls = 4, .gc_scanned_objects = 3 };
    a.add(b);
    try std.testing.expectEqual(@as(u64, 13), a.dictionary_probes);
    try std.testing.expectEqual(@as(u64, 5), a.dictionary_hits);
    try std.testing.expectEqual(@as(u64, 2), a.dictionary_misses);
    try std.testing.expectEqual(@as(u64, 5), a.concat_calls);
    try std.testing.expectEqual(@as(u64, 5), a.gc_scanned_objects);
}
