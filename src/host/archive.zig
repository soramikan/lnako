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

pub fn runArchiveTool(allocator: std.mem.Allocator, io: std.Io, tool: []const u8, operation: lnako.plugins.node.ArchiveOperation, source: []const u8, destination: []const u8) ![]u8 {
    const output_option = if (operation == .extract) try std.fmt.allocPrint(allocator, "-o{s}", .{destination}) else null;
    defer if (output_option) |option| allocator.free(option);
    const argv: []const []const u8 = switch (operation) {
        .compress => &.{ tool, "a", "-r", destination, source, "-y" },
        .extract => &.{ tool, "x", source, output_option.?, "-y" },
    };
    const result = try std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(64 * 1024 * 1024), .stderr_limit = .limited(64 * 1024 * 1024) });
    allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.ArchiveToolFailed;
    }
    return result.stdout;
}

test {
    std.testing.refAllDecls(zip_archive);
}
