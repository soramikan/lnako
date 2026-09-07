const std = @import("std");

/// Build the AOT dictionary type from the runtime's Value and key helpers.
/// Keeping the lookup cache here avoids making runtime_core.zig carry the
/// storage implementation alongside the object and collection runtime.
pub fn make(
    comptime Value: type,
    comptime DictionaryEntry: type,
    comptime aotIndexHash: anytype,
    comptime aotIndexHashUnits: anytype,
    comptime aotIndexKeyMatchesUnits: anytype,
    comptime sameKey: anytype,
    comptime index_threshold: usize,
) type {
    return struct {
        const Self = @This();

        pub const empty: Self = .{};

        entries: std.ArrayList(DictionaryEntry) = .empty,
        index_slots: []u32 = &.{},
        index_valid: bool = false,
        // Diagnostic counters (M0): observable lookup work for benchmark
        // analysis.  They count comparisons actually performed, not results.
        indexed_lookups: u64 = 0,
        linear_lookups: u64 = 0,
        entry_comparisons: u64 = 0,
        index_rebuilds: u64 = 0,
        hits: u64 = 0,
        misses: u64 = 0,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
            if (self.index_slots.len > 0) allocator.free(self.index_slots);
            self.* = .{};
        }

        pub fn len(self: *const Self) usize {
            return self.entries.items.len;
        }

        /// First-in-order entry equal to `key` under `sameKey`, or null.
        pub fn findByKey(self: *Self, key: Value) ?usize {
            if (self.index_valid) {
                self.indexed_lookups += 1;
                const result = self.probeIndex(aotIndexHash(key), key);
                if (result != null) {
                    self.hits += 1;
                } else {
                    self.misses += 1;
                }
                return result;
            }
            self.linear_lookups += 1;
            for (self.entries.items, 0..) |entry, index| {
                self.entry_comparisons += 1;
                if (sameKey(entry.key, key)) {
                    self.hits += 1;
                    return index;
                }
            }
            self.misses += 1;
            return null;
        }

        /// First-in-order entry whose string key equals `units`.  Non-string
        /// keys can never match a unit query, matching the previous scan.
        pub fn findByUnits(self: *Self, units: []const u16) ?usize {
            if (self.index_valid) {
                self.indexed_lookups += 1;
                var slot: usize = @intCast(aotIndexHashUnits(units) & (self.index_slots.len - 1));
                var found: ?usize = null;
                while (self.index_slots[slot] != 0) {
                    const index: usize = self.index_slots[slot] - 1;
                    self.entry_comparisons += 1;
                    if (aotIndexKeyMatchesUnits(self.entries.items[index].key, units)) {
                        if (found == null or index < found.?) found = index;
                    }
                    slot = (slot + 1) & (self.index_slots.len - 1);
                }
                if (found != null) {
                    self.hits += 1;
                } else {
                    self.misses += 1;
                }
                return found;
            }
            self.linear_lookups += 1;
            for (self.entries.items, 0..) |entry, index| {
                self.entry_comparisons += 1;
                if (aotIndexKeyMatchesUnits(entry.key, units)) {
                    self.hits += 1;
                    return index;
                }
            }
            self.misses += 1;
            return null;
        }

        fn probeIndex(self: *Self, hash: u64, key: Value) ?usize {
            const mask = self.index_slots.len - 1;
            var slot: usize = @intCast(hash & mask);
            var found: ?usize = null;
            while (self.index_slots[slot] != 0) {
                const index: usize = self.index_slots[slot] - 1;
                self.entry_comparisons += 1;
                if (sameKey(self.entries.items[index].key, key)) {
                    if (found == null or index < found.?) found = index;
                }
                slot = (slot + 1) & mask;
            }
            return found;
        }

        /// Insert or overwrite, keeping the first position on update.
        pub fn set(self: *Self, allocator: std.mem.Allocator, key: Value, value: Value) !void {
            if (self.findByKey(key)) |index| {
                self.entries.items[index].value = value;
                return;
            }
            try self.appendEntry(allocator, .{ .key = key, .value = value });
        }

        /// Append without a uniqueness check.  Callers that proved the key
        /// is absent (or intentionally produce duplicate keys) use this; the
        /// index still records the position.
        pub fn appendEntry(self: *Self, allocator: std.mem.Allocator, entry: DictionaryEntry) !void {
            try self.entries.append(allocator, entry);
            errdefer _ = self.entries.pop();
            const index = self.entries.items.len - 1;
            if (self.index_valid or self.entries.items.len >= index_threshold) try self.indexInsert(allocator, index);
        }

        /// Remove while preserving order.  The index is rebuilt because
        /// `orderedRemove` shifts every later position; on allocation failure
        /// it stays invalid and lookups fall back to the ordered scan.
        pub fn orderedRemoveEntry(self: *Self, allocator: std.mem.Allocator, index: usize) DictionaryEntry {
            const removed = self.entries.orderedRemove(index);
            self.index_valid = false;
            if (self.entries.items.len >= index_threshold) self.rebuildIndex(allocator) catch {};
            return removed;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.entries.clearRetainingCapacity();
            @memset(self.index_slots, 0);
            // Slots still cover zero entries; keep the buffer but flag it
            // stale so the next insert path rebuilds rather than trusting it.
            self.index_valid = false;
        }

        fn indexInsert(self: *Self, allocator: std.mem.Allocator, entry_index: usize) !void {
            if (!self.index_valid or self.entries.items.len * 2 > self.index_slots.len) {
                try self.rebuildIndex(allocator);
                return;
            }
            const mask = self.index_slots.len - 1;
            var slot: usize = @intCast(aotIndexHash(self.entries.items[entry_index].key) & mask);
            while (self.index_slots[slot] != 0) slot = (slot + 1) & mask;
            self.index_slots[slot] = @intCast(entry_index + 1);
        }

        fn rebuildIndex(self: *Self, allocator: std.mem.Allocator) !void {
            const capacity = std.math.ceilPowerOfTwo(usize, @max(self.entries.items.len * 2, 64)) catch return error.OutOfMemory;
            const slots = try allocator.alloc(u32, capacity);
            @memset(slots, 0);
            errdefer allocator.free(slots);
            const mask = capacity - 1;
            for (self.entries.items, 0..) |entry, index| {
                var slot: usize = @intCast(aotIndexHash(entry.key) & mask);
                while (slots[slot] != 0) slot = (slot + 1) & mask;
                slots[slot] = @intCast(index + 1);
            }
            if (self.index_slots.len > 0) allocator.free(self.index_slots);
            self.index_slots = slots;
            self.index_valid = true;
            self.index_rebuilds += 1;
        }
    };
}
