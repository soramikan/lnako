const std = @import("std");

const Entry = struct {
    name: []u8,
    data: []u8,
    is_directory: bool,
    local_offset: u32 = 0,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.data);
    }
};

pub fn create(allocator: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8) !void {
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    try gatherEntries(allocator, io, source, &entries);
    std.mem.sort(Entry, entries.items, {}, lessThanEntry);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (entries.items) |*entry| {
        entry.local_offset = std.math.cast(u32, output.items.len) orelse return error.Zip64Required;
        const crc = if (entry.is_directory) 0 else std.hash.Crc32.hash(entry.data);
        const size = std.math.cast(u32, entry.data.len) orelse return error.Zip64Required;
        try appendInt(&output, allocator, u32, 0x04034b50);
        try appendInt(&output, allocator, u16, 20);
        try appendInt(&output, allocator, u16, 0x0800);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u32, crc);
        try appendInt(&output, allocator, u32, size);
        try appendInt(&output, allocator, u32, size);
        try appendInt(&output, allocator, u16, std.math.cast(u16, entry.name.len) orelse return error.ZipEntryNameTooLong);
        try appendInt(&output, allocator, u16, 0);
        try output.appendSlice(allocator, entry.name);
        try output.appendSlice(allocator, entry.data);
    }

    const central_offset = std.math.cast(u32, output.items.len) orelse return error.Zip64Required;
    for (entries.items) |entry| {
        const crc = if (entry.is_directory) 0 else std.hash.Crc32.hash(entry.data);
        const size = std.math.cast(u32, entry.data.len) orelse return error.Zip64Required;
        try appendInt(&output, allocator, u32, 0x02014b50);
        try appendInt(&output, allocator, u16, 0x0314);
        try appendInt(&output, allocator, u16, 20);
        try appendInt(&output, allocator, u16, 0x0800);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u32, crc);
        try appendInt(&output, allocator, u32, size);
        try appendInt(&output, allocator, u32, size);
        try appendInt(&output, allocator, u16, std.math.cast(u16, entry.name.len) orelse return error.ZipEntryNameTooLong);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u32, if (entry.is_directory) 0x41ed0010 else 0x81a40000);
        try appendInt(&output, allocator, u32, entry.local_offset);
        try output.appendSlice(allocator, entry.name);
    }
    const central_size = std.math.cast(u32, output.items.len - central_offset) orelse return error.Zip64Required;
    const count = std.math.cast(u16, entries.items.len) orelse return error.Zip64Required;
    try appendInt(&output, allocator, u32, 0x06054b50);
    try appendInt(&output, allocator, u16, 0);
    try appendInt(&output, allocator, u16, 0);
    try appendInt(&output, allocator, u16, count);
    try appendInt(&output, allocator, u16, count);
    try appendInt(&output, allocator, u32, central_size);
    try appendInt(&output, allocator, u32, central_offset);
    try appendInt(&output, allocator, u16, 0);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = output.items });
}

pub fn extract(io: std.Io, source: []const u8, destination: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, destination);
    var destination_directory = try std.Io.Dir.cwd().openDir(io, destination, .{});
    defer destination_directory.close(io);
    const file = try std.Io.Dir.cwd().openFile(io, source, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    var filename_buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (try iterator.next()) |entry| {
        try entry.extract(&reader, .{}, &filename_buffer, destination_directory);
        const filename = filename_buffer[0..entry.filename_len];
        if (filename.len > 0 and filename[filename.len - 1] == '/') continue;
        if (!try verifyExtractedFile(io, destination_directory, filename, entry.uncompressed_size, entry.crc32)) {
            destination_directory.deleteTree(io, filename) catch {};
            return error.ZipChecksumMismatch;
        }
    }
}

fn verifyExtractedFile(io: std.Io, directory: std.Io.Dir, path: []const u8, expected_size: u64, expected_crc32: u32) !bool {
    const file = try directory.openFile(io, path, .{});
    defer file.close(io);
    var reader_buffer: [8192]u8 = undefined;
    var data_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var crc = std.hash.Crc32.init();
    var size: u64 = 0;
    while (true) {
        const length = try reader.interface.readSliceShort(&data_buffer);
        if (length == 0) break;
        size = std.math.add(u64, size, length) catch return false;
        crc.update(data_buffer[0..length]);
    }
    return size == expected_size and crc.final() == expected_crc32;
}

fn gatherEntries(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entries: *std.ArrayList(Entry)) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, source, .{});
    if (stat.kind != .directory) {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .limited(1024 * 1024 * 1024));
        errdefer allocator.free(data);
        try entries.append(allocator, .{ .name = try normalizedName(allocator, std.fs.path.basename(source), false), .data = data, .is_directory = false });
        return;
    }

    const root_name = std.fs.path.basename(std.mem.trimEnd(u8, source, "/\\"));
    try entries.append(allocator, .{ .name = try normalizedName(allocator, root_name, true), .data = try allocator.alloc(u8, 0), .is_directory = true });
    var directory = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |walked| {
        const joined_name = try std.fs.path.join(allocator, &.{ root_name, walked.path });
        defer allocator.free(joined_name);
        if (walked.kind == .directory) {
            try entries.append(allocator, .{ .name = try normalizedName(allocator, joined_name, true), .data = try allocator.alloc(u8, 0), .is_directory = true });
        } else if (walked.kind == .file) {
            const file_path = try std.fs.path.join(allocator, &.{ source, walked.path });
            defer allocator.free(file_path);
            const data = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024 * 1024));
            errdefer allocator.free(data);
            try entries.append(allocator, .{ .name = try normalizedName(allocator, joined_name, false), .data = data, .is_directory = false });
        }
    }
}

fn normalizedName(allocator: std.mem.Allocator, source: []const u8, directory: bool) ![]u8 {
    const extra: usize = if (directory and (source.len == 0 or source[source.len - 1] != '/')) 1 else 0;
    const result = try allocator.alloc(u8, source.len + extra);
    for (source, 0..) |byte, index| result[index] = if (byte == '\\') '/' else byte;
    if (extra == 1) result[source.len] = '/';
    return result;
}

fn appendInt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(allocator, &bytes);
}

fn lessThanEntry(_: void, left: Entry, right: Entry) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

test "stored ZIPを作成・展開する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "日本語ABC" });
    const temporary_path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(temporary_path);
    const source = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "source.txt" });
    defer std.testing.allocator.free(source);
    const zip_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "result.zip" });
    defer std.testing.allocator.free(zip_path);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "output" });
    defer std.testing.allocator.free(output_path);
    try create(std.testing.allocator, std.testing.io, source, zip_path);
    try extract(std.testing.io, zip_path, output_path);
    const extracted = try std.fs.path.join(std.testing.allocator, &.{ output_path, "source.txt" });
    defer std.testing.allocator.free(extracted);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, extracted, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("日本語ABC", bytes);

    const archive = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, zip_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(archive);
    archive[30 + "source.txt".len] ^= 0xff;
    const corrupted_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "corrupted.zip" });
    defer std.testing.allocator.free(corrupted_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = corrupted_path, .data = archive });
    const corrupted_output = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "corrupted-output" });
    defer std.testing.allocator.free(corrupted_output);
    try std.testing.expectError(error.ZipChecksumMismatch, extract(std.testing.io, corrupted_path, corrupted_output));
}
