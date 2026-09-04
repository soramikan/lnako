const std = @import("std");

const SpecificationParts = struct {
    pattern: []const u16,
    flags: []const u16,
    delimited: bool,
};

pub fn splitSpecification(specification: []const u16) SpecificationParts {
    if (specification.len >= 2 and specification[0] == '/') {
        var index = specification.len;
        while (index > 1) {
            index -= 1;
            if (specification[index] == '/' and !escapedAt(specification, index)) {
                if (index > 1) return .{
                    .pattern = specification[1..index],
                    .flags = specification[index + 1 ..],
                    .delimited = true,
                };
                break;
            }
        }
    }
    return .{ .pattern = specification, .flags = &.{}, .delimited = false };
}

/// Format the part of V8's RegExp constructor error that is stable across
/// the interpreter, AOT, and table-regexp routes.  The parser still returns
/// the typed Zig error; callers use this text only for the user-visible
/// failure message.
pub fn compileFailureMessageAlloc(allocator: std.mem.Allocator, specification: []const u16, default_global: bool, failure: anyerror) !?[]u8 {
    const parts = splitSpecification(specification);
    if (failure == error.UnsupportedRegularExpressionFlag or failure == error.DuplicateRegularExpressionFlag) {
        if (!parts.delimited) return null;
        const flags_utf8 = try utf16ToUtf8Lossy(allocator, parts.flags);
        defer allocator.free(flags_utf8);
        return try std.fmt.allocPrint(allocator, "Invalid flags supplied to RegExp constructor '{s}'", .{flags_utf8});
    }
    const reason = switch (failure) {
        error.UnclosedCharacterClass => "Unterminated character class",
        error.UnclosedGroup => "Unterminated group",
        error.QuantifierWithoutAtom => "Nothing to repeat",
        error.LoneQuantifierBrackets => "Lone quantifier brackets",
        error.InvalidCharacterRange => "Range out of order in character class",
        error.InvalidCharacterClass => "Invalid character class",
        error.InvalidCharacterInClass => "Invalid character in character class",
        error.InvalidHexEscape => "Invalid escape",
        error.IncompleteQuantifier => "Incomplete quantifier",
        error.InvalidQuantifierRange => "numbers out of order in {} quantifier",
        error.InvalidBackreference => "Invalid escape",
        error.InvalidDecimalEscape => "Invalid decimal escape",
        error.InvalidNamedReference => "Invalid named reference",
        error.InvalidNamedBackreference => "Invalid named capture referenced",
        error.InvalidNamedCapture => "Invalid capture group name",
        error.DuplicateNamedCapture => "Duplicate capture group name",
        error.UnsupportedGroupAssertion => "Invalid group",
        error.InvalidUnicodeProperty => "Invalid property name",
        error.InvalidUnicodePropertyInClass => "Invalid property name in character class",
        error.InvalidClassEscape => "Invalid escape",
        error.UnsupportedUnicodeSetOperation => "Invalid set operation in character class",
        error.InvalidUnicodeEscape => "Invalid Unicode escape",
        error.InvalidEscape => "\\ at end of pattern",
        error.InvalidIdentityEscape => "Invalid escape",
        error.UnexpectedPatternToken => "Unmatched ')'",
        else => return null,
    };
    const pattern_utf8 = try utf16ToUtf8Lossy(allocator, parts.pattern);
    defer allocator.free(pattern_utf8);
    if (parts.delimited) {
        const flags_utf8 = try utf16ToUtf8Lossy(allocator, parts.flags);
        defer allocator.free(flags_utf8);
        return try std.fmt.allocPrint(allocator, "Invalid regular expression: /{s}/{s}: {s}", .{ pattern_utf8, flags_utf8, reason });
    }
    return try std.fmt.allocPrint(allocator, "Invalid regular expression: /{s}/{s}: {s}", .{ pattern_utf8, if (default_global) "g" else "", reason });
}

fn escapedAt(source: []const u16, index: usize) bool {
    var slashes: usize = 0;
    var cursor = index;
    while (cursor > 0 and source[cursor - 1] == '\\') {
        slashes += 1;
        cursor -= 1;
    }
    return slashes % 2 == 1;
}

fn utf16ToUtf8Lossy(allocator: std.mem.Allocator, units: []const u16) ![]u8 {
    var output = try allocator.alloc(u8, units.len * 3);
    errdefer allocator.free(output);
    var unit_index: usize = 0;
    var output_index: usize = 0;
    while (unit_index < units.len) {
        const first = units[unit_index];
        var codepoint: u21 = undefined;
        if (first >= 0xd800 and first <= 0xdbff and unit_index + 1 < units.len and units[unit_index + 1] >= 0xdc00 and units[unit_index + 1] <= 0xdfff) {
            const second = units[unit_index + 1];
            codepoint = @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
            unit_index += 2;
        } else {
            codepoint = if (first >= 0xd800 and first <= 0xdfff) 0xfffd else @intCast(first);
            unit_index += 1;
        }
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(codepoint, &encoded);
        @memcpy(output[output_index .. output_index + length], encoded[0..length]);
        output_index += length;
    }
    return allocator.realloc(output, output_index);
}
