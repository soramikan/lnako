const std = @import("std");
const types = @import("types.zig");
const matcher = @import("matcher.zig");
const captures = @import("captures.zig");

pub fn replaceUnits(allocator: std.mem.Allocator, source: []const u16, replacement: []const u16, compiled: *const types.Compiled) ![]u16 {
    const matches = try matcher.findAll(allocator, source, compiled);
    defer allocator.free(matches);
    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(allocator);
    var cursor: usize = 0;
    for (matches) |match| {
        try output.appendSlice(allocator, source[cursor..match.span.start]);
        try appendReplacement(allocator, &output, source, replacement, match, compiled);
        cursor = match.span.end;
    }
    try output.appendSlice(allocator, source[cursor..]);
    return output.toOwnedSlice(allocator);
}

fn appendReplacement(allocator: std.mem.Allocator, output: *std.ArrayList(u16), source: []const u16, replacement: []const u16, match: types.Match, compiled: *const types.Compiled) !void {
    var index: usize = 0;
    while (index < replacement.len) {
        if (replacement[index] != '$' or index + 1 >= replacement.len) {
            try output.append(allocator, replacement[index]);
            index += 1;
            continue;
        }
        const marker = replacement[index + 1];
        if (marker == '$') {
            try output.append(allocator, '$');
            index += 2;
        } else if (marker == '&') {
            try output.appendSlice(allocator, source[match.span.start..match.span.end]);
            index += 2;
        } else if (marker == '`') {
            try output.appendSlice(allocator, source[0..match.span.start]);
            index += 2;
        } else if (marker == '\'') {
            try output.appendSlice(allocator, source[match.span.end..]);
            index += 2;
        } else if (marker >= '1' and marker <= '9') {
            var number: usize = marker - '0';
            var consumed: usize = 2;
            if (index + 2 < replacement.len and replacement[index + 2] >= '0' and replacement[index + 2] <= '9') {
                const two_digits = number * 10 + replacement[index + 2] - '0';
                if (two_digits <= compiled.capture_count) {
                    number = two_digits;
                    consumed = 3;
                }
            }
            if (number <= compiled.capture_count) {
                const span = match.captures[number - 1];
                if (span.matched) try output.appendSlice(allocator, source[span.start..span.end]);
                index += consumed;
            } else {
                try output.append(allocator, '$');
                index += 1;
            }
        } else if (marker == '<') {
            var end = index + 2;
            while (end < replacement.len and replacement[end] != '>') end += 1;
            const capture_index = if (end < replacement.len) captures.namedCaptureIndex(compiled, replacement[index + 2 .. end]) else null;
            if (capture_index) |capture| {
                const span = match.captures[capture];
                if (span.matched) try output.appendSlice(allocator, source[span.start..span.end]);
                index = end + 1;
            } else {
                try output.append(allocator, '$');
                index += 1;
            }
        } else {
            try output.append(allocator, '$');
            index += 1;
        }
    }
}
