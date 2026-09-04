const std = @import("std");

pub const max_captures = 64;

pub const Flags = struct {
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    unicode: bool = false,
    unicode_sets: bool = false,
    sticky: bool = false,
    indices: bool = false,
};

pub const Span = struct { start: usize = 0, end: usize = 0, matched: bool = false };
pub const Candidate = struct { position: usize, captures: [max_captures]Span };
pub const Match = struct { span: Span, captures: [max_captures]Span };

pub const UnicodeProperty = struct { property: @import("unicode_properties").Property, negated: bool };

pub const ClassItem = union(enum) {
    literal: u16,
    code_point: u21,
    range: struct { first: u21, last: u21 },
    digit,
    not_digit,
    word,
    not_word,
    space,
    not_space,
    unicode_property: UnicodeProperty,
    nested_class: *CharacterClass,
};

pub const SetOperationKind = enum { intersection, subtraction };

pub const SetOperation = struct {
    kind: SetOperationKind,
    left: *CharacterClass,
    right: *CharacterClass,
};

pub const CharacterClass = struct {
    negated: bool,
    items: []const ClassItem,
    operation: ?*SetOperation = null,
};

pub const Group = struct {
    expression: *Expression,
    capture: ?usize,
    name: ?[]const u16,
    capture_start: usize,
    capture_end: usize,
};

pub const Assertion = struct {
    expression: *Expression,
    positive: bool,
    behind: bool,
    capture_start: usize,
    capture_end: usize,
};

pub const Atom = union(enum) {
    literal: u16,
    code_point: u21,
    dot,
    class: *CharacterClass,
    group: Group,
    assertion: Assertion,
    start_anchor,
    end_anchor,
    word_boundary: bool,
    backreference: usize,
    named_backreference: []const u16,
    // Non-Unicode decimal escapes are resolved after the parser knows the
    // complete capture count.  This is required for forward references such
    // as `\\1(a)`, while still allowing Annex B octal fallback when the
    // referenced capture does not exist.
    legacy_decimal_escape: []const u16,
    unicode_decimal_escape: []const u16,
    legacy_octal_escape: struct { code_unit: u16, trailing: []const u16 },
    unicode_property: UnicodeProperty,
};

pub const Piece = struct { atom: Atom, minimum: usize = 1, maximum: ?usize = 1, lazy: bool = false };
pub const Sequence = struct { pieces: []const Piece };
pub const Expression = struct { alternatives: []const Sequence };

pub const Compiled = struct {
    arena: std.heap.ArenaAllocator,
    expression: *Expression,
    flags: Flags,
    capture_count: usize,
    capture_names: [max_captures]?[]const u16,

    pub fn deinit(self: *Compiled) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
