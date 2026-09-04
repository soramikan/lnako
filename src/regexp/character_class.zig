const std = @import("std");
const types = @import("types.zig");
const unicode = @import("unicode.zig");

pub fn classMatches(class: *const types.CharacterClass, source: []const u16, position: usize, flags: types.Flags) bool {
    const unit = source[position];
    const code_point = unicode.codePointAt(source, position).?;
    const matched = if (class.operation) |operation| blk: {
        const left = classMatches(operation.left, source, position, flags);
        const right = classMatches(operation.right, source, position, flags);
        break :blk switch (operation.kind) {
            .intersection => left and right,
            .subtraction => left and !right,
        };
    } else blk: {
        var items_match = false;
        for (class.items) |item| {
            items_match = switch (item) {
                .literal => |literal| if (flags.unicode)
                    unicode.codePointsEqual(code_point.value, literal, flags)
                else
                    unicode.unitsEqual(unit, literal, flags.ignore_case),
                .code_point => |literal| if (flags.unicode) unicode.codePointsEqual(code_point.value, literal, flags) else literal <= std.math.maxInt(u16) and unit == literal,
                .range => |range| blk_range: {
                    const value = if (flags.unicode) code_point.value else unit;
                    const folded = unicode.foldCodePoint(value, flags);
                    break :blk_range folded >= unicode.foldCodePoint(range.first, flags) and folded <= unicode.foldCodePoint(range.last, flags);
                },
                .digit => unicode.isDigit(unit),
                .not_digit => !unicode.isDigit(unit),
                .word => if (flags.unicode) unicode.isWordCodePoint(code_point.value, flags) else unicode.isWord(unit),
                .not_word => if (flags.unicode) !unicode.isWordCodePoint(code_point.value, flags) else !unicode.isWord(unit),
                .space => unicode.isWhitespace(unit),
                .not_space => !unicode.isWhitespace(unit),
                .unicode_property => |property| unicode.propertyMatches(property, code_point.value, flags),
                .nested_class => |nested| classMatches(nested, source, position, flags),
            };
            if (items_match) break;
        }
        break :blk items_match;
    };
    return matched != class.negated;
}

pub fn classItemCodePoint(item: types.ClassItem) ?u21 {
    return switch (item) {
        .literal => |literal| literal,
        .code_point => |code_point| code_point,
        else => null,
    };
}

pub fn isSetOperand(class: *const types.CharacterClass) bool {
    if (class.operation != null) return true;
    if (class.items.len != 1) return false;
    return switch (class.items[0]) {
        .range => false,
        else => true,
    };
}
