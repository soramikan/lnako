const std = @import("std");

pub const Kind = enum { buffer, uint8_array, array_buffer };

pub fn Storage(comptime Value: type) type {
    return struct {
        allocator: std.mem.Allocator,
        bytes: []u8,
        ref_count: usize = 1,
        /// Keep one stable ArrayBuffer wrapper for all views sharing storage.
        backing: Value = .{},

        pub fn retain(self: *@This()) void {
            std.debug.assert(self.ref_count > 0);
            self.ref_count += 1;
        }

        pub fn release(self: *@This()) void {
            std.debug.assert(self.ref_count > 0);
            self.ref_count -= 1;
            if (self.ref_count != 0) return;
            self.allocator.free(self.bytes);
            self.allocator.destroy(self);
        }
    };
}

pub fn Buffer(comptime StorageType: type) type {
    return struct {
        bytes: []u8,
        kind: Kind,
        storage: *StorageType,
        /// Offset from the beginning of the shared storage.  This remains
        /// meaningful for zero-length views.
        byte_offset: usize = 0,
    };
}
