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
    string_conversions: u64 = 0,
    numeric_conversions: u64 = 0,
    value_copies: u64 = 0,
    frame_pools_hits: u64 = 0,
    frame_pools_misses: u64 = 0,

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
        self.string_conversions +|= other.string_conversions;
        self.numeric_conversions +|= other.numeric_conversions;
        self.value_copies +|= other.value_copies;
        self.frame_pools_hits +|= other.frame_pools_hits;
        self.frame_pools_misses +|= other.frame_pools_misses;
    }
};

test "Counters add saturates" {
    var a: Counters = .{ .dictionary_probes = 10, .dictionary_hits = 5 };
    const b: Counters = .{ .dictionary_probes = 3, .dictionary_misses = 2 };
    a.add(b);
    try std.testing.expectEqual(@as(u64, 13), a.dictionary_probes);
    try std.testing.expectEqual(@as(u64, 5), a.dictionary_hits);
    try std.testing.expectEqual(@as(u64, 2), a.dictionary_misses);
}
