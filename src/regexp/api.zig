const std = @import("std");
const types = @import("types.zig");
const parser = @import("parser.zig");
const matcher = @import("matcher.zig");
const replacement_mod = @import("replacement.zig");
const error_message = @import("error_message.zig");
const captures = @import("captures.zig");

pub const Flags = types.Flags;
pub const Span = types.Span;
pub const Match = types.Match;
pub const Compiled = types.Compiled;

pub fn compile(allocator: std.mem.Allocator, pattern: []const u16, flags: types.Flags) !Compiled {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned_pattern = try arena.allocator().dupe(u16, pattern);
    var p = parser.Parser{
        .allocator = arena.allocator(),
        .source = owned_pattern,
        .unicode = flags.unicode,
        .unicode_sets = flags.unicode_sets,
    };
    const expression = try p.parseExpression();
    if (p.index != owned_pattern.len) return error.UnexpectedPatternToken;
    try captures.resolveDecimalEscapes(expression, p.capture_count);
    try captures.resolveNamedBackreferences(expression, p.capture_names[0..p.capture_count]);
    return .{ .arena = arena, .expression = expression, .flags = flags, .capture_count = p.capture_count, .capture_names = p.capture_names };
}

pub fn find(allocator: std.mem.Allocator, compiled: *const Compiled, source: []const u16, start: usize) !?Match {
    return matcher.findOne(allocator, source, compiled, start);
}

pub fn replace(allocator: std.mem.Allocator, source: []const u16, replacement_text: []const u16, compiled: *const Compiled) ![]u16 {
    return replacement_mod.replaceUnits(allocator, source, replacement_text, compiled);
}

pub fn compilePattern(allocator: std.mem.Allocator, specification: []const u16, default_global: bool) !Compiled {
    const parts = error_message.splitSpecification(specification);
    var flags = types.Flags{ .global = default_global };
    if (parts.delimited) {
        flags = .{};
        var seen_flags: u8 = 0;
        for (parts.flags) |flag| {
            const bit: u8 = switch (flag) {
                'g' => 1 << 0,
                'i' => 1 << 1,
                'm' => 1 << 2,
                's' => 1 << 3,
                'u' => 1 << 4,
                'd' => 1 << 5,
                'y' => 1 << 6,
                'v' => 1 << 7,
                else => return error.UnsupportedRegularExpressionFlag,
            };
            if (seen_flags & bit != 0) return error.DuplicateRegularExpressionFlag;
            seen_flags |= bit;
            switch (flag) {
                'g' => flags.global = true,
                'i' => flags.ignore_case = true,
                'm' => flags.multiline = true,
                's' => flags.dot_all = true,
                'u' => flags.unicode = true,
                'd' => flags.indices = true,
                'y' => flags.sticky = true,
                'v' => {
                    flags.unicode = true;
                    flags.unicode_sets = true;
                },
                else => unreachable,
            }
        }
        if (flags.unicode_sets and seen_flags & (1 << 4) != 0) return error.UnsupportedRegularExpressionFlag;
    }
    return compile(allocator, parts.pattern, flags);
}

pub fn findMatches(allocator: std.mem.Allocator, source: []const u16, compiled: *const Compiled) ![]Match {
    return matcher.findAll(allocator, source, compiled);
}

pub fn replaceUnits(allocator: std.mem.Allocator, source: []const u16, replacement_units: []const u16, compiled: *const Compiled) ![]u16 {
    return replacement_mod.replaceUnits(allocator, source, replacement_units, compiled);
}

pub fn compileFailureMessageAlloc(allocator: std.mem.Allocator, specification: []const u16, default_global: bool, failure: anyerror) !?[]u8 {
    return error_message.compileFailureMessageAlloc(allocator, specification, default_global, failure);
}

pub const RawPattern = struct {
    allocator: std.mem.Allocator,
    compiled: Compiled,

    pub fn init(allocator: std.mem.Allocator, pattern: []const u16, ignore_case: bool) !RawPattern {
        return .{
            .allocator = allocator,
            .compiled = try compile(allocator, pattern, .{ .ignore_case = ignore_case }),
        };
    }

    pub fn deinit(self: *RawPattern) void {
        self.compiled.deinit();
        self.* = undefined;
    }

    pub fn matches(self: *const RawPattern, source: []const u16) !bool {
        return try matcher.findOne(self.allocator, source, &self.compiled, 0) != null;
    }
};

pub fn testRaw(allocator: std.mem.Allocator, pattern: []const u16, source: []const u16, ignore_case: bool) !bool {
    var compiled = try RawPattern.init(allocator, pattern, ignore_case);
    defer compiled.deinit();
    return compiled.matches(source);
}
