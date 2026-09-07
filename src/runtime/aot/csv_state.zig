const std = @import("std");

pub const DelimiterDefault = enum { comma, tab };

const comma = [_]u16{','};
const tab = [_]u16{'\t'};
const crlf = [_]u16{ '\r', '\n' };

/// CSV options are process-local in the official plugin. Keep the same
/// lifetime as the AOT runtime so separate builtin calls observe updates from
/// CSVオプション設定 without introducing a JavaScript runtime.
pub const State = struct {
    custom_delimiter: ?[]u16 = null,
    custom_eol: ?[]u16 = null,
    delimiter_default: DelimiterDefault = .comma,
    auto_convert_number: bool = true,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.custom_delimiter) |value| allocator.free(value);
        if (self.custom_eol) |value| allocator.free(value);
        self.* = undefined;
    }

    pub fn delimiter(self: *const @This()) []const u16 {
        return self.custom_delimiter orelse switch (self.delimiter_default) {
            .comma => &comma,
            .tab => &tab,
        };
    }

    pub fn eol(self: *const @This()) []const u16 {
        return self.custom_eol orelse &crlf;
    }

    pub fn useDelimiter(self: *@This(), allocator: std.mem.Allocator, value: DelimiterDefault) void {
        if (self.custom_delimiter) |owned| allocator.free(owned);
        self.custom_delimiter = null;
        self.delimiter_default = value;
    }

    pub fn setDelimiter(self: *@This(), allocator: std.mem.Allocator, value: []const u16) !void {
        const owned = try allocator.dupe(u16, value);
        if (self.custom_delimiter) |old| allocator.free(old);
        self.custom_delimiter = owned;
    }

    pub fn setEol(self: *@This(), allocator: std.mem.Allocator, value: []const u16) !void {
        const owned = try allocator.dupe(u16, value);
        if (self.custom_eol) |old| allocator.free(old);
        self.custom_eol = owned;
    }
};
