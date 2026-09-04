const std = @import("std");
const builtin = @import("builtin");

pub const ChunkedHttpBody = struct {
    body: []u8,
    too_large: bool,
};

pub fn readChunkedHttpBody(allocator: std.mem.Allocator, reader: *std.Io.Reader, maximum_size: usize) !ChunkedHttpBody {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    var too_large = false;
    while (true) {
        const size_line_raw = (try reader.takeDelimiter('\n')) orelse return error.InvalidHttpChunk;
        const size_line = std.mem.trim(u8, std.mem.trimEnd(u8, size_line_raw, "\r"), " \t");
        const extension = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const size_text = std.mem.trim(u8, size_line[0..extension], " \t");
        if (size_text.len == 0) return error.InvalidHttpChunk;
        const chunk_size = std.fmt.parseInt(usize, size_text, 16) catch return error.InvalidHttpChunk;
        if (chunk_size == 0) {
            while (true) {
                const trailer_raw = (try reader.takeDelimiter('\n')) orelse return error.InvalidHttpChunk;
                if (std.mem.trimEnd(u8, trailer_raw, "\r").len == 0) break;
            }
            break;
        }
        if (too_large or chunk_size > maximum_size - body.items.len) {
            too_large = true;
            if (try reader.discardShort(chunk_size) != chunk_size) return error.InvalidHttpChunk;
        } else {
            const destination = try body.addManyAsSlice(allocator, chunk_size);
            try reader.readSliceAll(destination);
        }
        const terminator_raw = (try reader.takeDelimiter('\n')) orelse return error.InvalidHttpChunk;
        if (std.mem.trimEnd(u8, terminator_raw, "\r").len != 0) return error.InvalidHttpChunk;
    }
    if (too_large) {
        body.deinit(allocator);
        return .{ .body = try allocator.alloc(u8, 0), .too_large = true };
    }
    return .{ .body = try body.toOwnedSlice(allocator), .too_large = false };
}

pub fn uploadBasename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |byte, index| if (byte == '/' or byte == '\\') {
        start = index + 1;
    };
    return path[start..];
}

pub fn httpMethod(source: []const u8) !std.http.Method {
    inline for (@typeInfo(std.http.Method).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(source, field.name)) return @enumFromInt(field.value);
    }
    return error.UnsupportedHttpMethod;
}
