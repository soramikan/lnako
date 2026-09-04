const std = @import("std");
const lnako = @import("lnako");
const zip_archive = @import("../archive/zip.zig");

pub fn runStoredZipArchive(allocator: std.mem.Allocator, io: std.Io, operation: lnako.plugins.node.ArchiveOperation, source: []const u8, destination: []const u8) ![]u8 {
    switch (operation) {
        .compress => try zip_archive.create(allocator, io, source, destination),
        .extract => try zip_archive.extract(io, source, destination),
    }
    return allocator.alloc(u8, 0);
}

test {
    std.testing.refAllDecls(zip_archive);
}
