const std = @import("std");
const types = @import("types.zig");
const unicode = @import("unicode.zig");
const character_class = @import("character_class.zig");
const captures = @import("captures.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u16,
    unicode: bool = false,
    unicode_sets: bool = false,
    index: usize = 0,
    capture_count: usize = 0,
    capture_names: [types.max_captures]?[]const u16 = [_]?[]const u16{null} ** types.max_captures,

    pub fn parseExpression(self: *Parser) anyerror!*types.Expression {
        var alternatives: std.ArrayList(types.Sequence) = .empty;
        while (true) {
            try alternatives.append(self.allocator, try self.parseSequence());
            if (self.index >= self.source.len or self.source[self.index] != '|') break;
            self.index += 1;
        }
        const expression = try self.allocator.create(types.Expression);
        expression.* = .{ .alternatives = try alternatives.toOwnedSlice(self.allocator) };
        return expression;
    }

    fn parseSequence(self: *Parser) anyerror!types.Sequence {
        var pieces: std.ArrayList(types.Piece) = .empty;
        while (self.index < self.source.len and self.source[self.index] != ')' and self.source[self.index] != '|') {
            var piece = types.Piece{ .atom = try self.parseAtom() };
            try self.parseQuantifier(&piece);
            try pieces.append(self.allocator, piece);
        }
        return .{ .pieces = try pieces.toOwnedSlice(self.allocator) };
    }

    fn parseAtom(self: *Parser) anyerror!types.Atom {
        if (self.index >= self.source.len) return error.UnexpectedPatternEnd;
        const unit = self.source[self.index];
        self.index += 1;
        return switch (unit) {
            '.' => .dot,
            '^' => .start_anchor,
            '$' => .end_anchor,
            '[' => .{ .class = try self.parseClass() },
            '(' => try self.parseGroup(),
            '\\' => try self.parseEscape(false),
            '*', '+', '?' => error.QuantifierWithoutAtom,
            '{' => if (self.unicode) error.LoneQuantifierBrackets else .{ .literal = unit },
            else => if (self.unicode and unicode.isHighSurrogate(unit) and self.index < self.source.len and unicode.isLowSurrogate(self.source[self.index])) blk: {
                const code_point = unicode.surrogatePairCodePoint(unit, self.source[self.index]);
                self.index += 1;
                break :blk .{ .code_point = code_point };
            } else .{ .literal = unit },
        };
    }

    fn parseGroup(self: *Parser) anyerror!types.Atom {
        var capture = true;
        var name: ?[]const u16 = null;
        var assertion: ?struct { positive: bool, behind: bool } = null;
        if (self.index < self.source.len and self.source[self.index] == '?') {
            self.index += 1;
            if (consume(self, ':')) {
                capture = false;
            } else if (consume(self, '=')) {
                capture = false;
                assertion = .{ .positive = true, .behind = false };
            } else if (consume(self, '!')) {
                capture = false;
                assertion = .{ .positive = false, .behind = false };
            } else if (consume(self, '<')) {
                if (consume(self, '=')) {
                    capture = false;
                    assertion = .{ .positive = true, .behind = true };
                } else if (consume(self, '!')) {
                    capture = false;
                    assertion = .{ .positive = false, .behind = true };
                } else {
                    const start = self.index;
                    while (self.index < self.source.len and self.source[self.index] != '>') self.index += 1;
                    if (self.index == self.source.len or self.index == start) return error.InvalidNamedCapture;
                    name = self.source[start..self.index];
                    if (!captures.isValidNamedCapture(name.?)) return error.InvalidNamedCapture;
                    for (self.capture_names[0..self.capture_count]) |existing| {
                        if (existing) |candidate| if (std.mem.eql(u16, candidate, name.?)) return error.DuplicateNamedCapture;
                    }
                    self.index += 1;
                }
            } else return error.UnsupportedGroupAssertion;
        }
        const capture_start = self.capture_count;
        var capture_index: ?usize = null;
        if (capture) {
            if (self.capture_count >= types.max_captures) return error.TooManyCaptures;
            capture_index = self.capture_count;
            self.capture_names[self.capture_count] = name;
            self.capture_count += 1;
        }
        const expression = try self.parseExpression();
        if (!consume(self, ')')) return error.UnclosedGroup;
        const capture_end = self.capture_count;
        if (assertion) |details| return .{ .assertion = .{
            .expression = expression,
            .positive = details.positive,
            .behind = details.behind,
            .capture_start = capture_start,
            .capture_end = capture_end,
        } };
        return .{ .group = .{
            .expression = expression,
            .capture = capture_index,
            .name = name,
            .capture_start = capture_start,
            .capture_end = capture_end,
        } };
    }

    fn parseClass(self: *Parser) anyerror!*types.CharacterClass {
        const negated = consume(self, '^');
        var left = try self.parseClassOperand();
        while (self.consumeSetOperator()) |kind| {
            if (left.operation == null and left.items.len == 0) return error.InvalidCharacterClass;
            if (!character_class.isSetOperand(left)) return error.UnsupportedUnicodeSetOperation;
            if (self.index >= self.source.len or self.source[self.index] == ']' or self.atSetOperator()) return error.InvalidCharacterInClass;
            const right = try self.parseClassOperand();
            if (right.items.len == 0 and right.operation == null) return error.InvalidCharacterInClass;
            if (!character_class.isSetOperand(right)) return error.UnsupportedUnicodeSetOperation;
            const operation = try self.allocator.create(types.SetOperation);
            operation.* = .{ .kind = kind, .left = left, .right = right };
            const result = try self.allocator.create(types.CharacterClass);
            result.* = .{ .negated = false, .items = &.{}, .operation = operation };
            left = result;
        }
        if (!consume(self, ']')) return error.UnclosedCharacterClass;
        left.negated = negated;
        return left;
    }

    fn parseClassOperand(self: *Parser) !*types.CharacterClass {
        var items: std.ArrayList(types.ClassItem) = .empty;
        while (self.index < self.source.len and self.source[self.index] != ']') {
            if (self.atSetOperator()) break;
            const first = try self.parseClassItem();
            if (self.atSetOperator()) {
                try items.append(self.allocator, first);
                break;
            }
            if (character_class.classItemCodePoint(first)) |first_code_point| {
                if (self.index + 1 < self.source.len and self.source[self.index] == '-' and self.source[self.index + 1] != ']') {
                    self.index += 1;
                    const last = try self.parseClassItem();
                    const last_code_point = character_class.classItemCodePoint(last) orelse return if (self.unicode) error.InvalidCharacterClass else error.InvalidCharacterRange;
                    if (last_code_point < first_code_point) return error.InvalidCharacterRange;
                    try items.append(self.allocator, .{ .range = .{ .first = first_code_point, .last = last_code_point } });
                } else try items.append(self.allocator, first);
            } else if (self.unicode and self.index + 1 < self.source.len and self.source[self.index] == '-' and self.source[self.index + 1] != ']') {
                return error.InvalidCharacterClass;
            } else try items.append(self.allocator, first);
        }
        const class = try self.allocator.create(types.CharacterClass);
        class.* = .{ .negated = false, .items = try items.toOwnedSlice(self.allocator) };
        return class;
    }

    fn atSetOperator(self: *const Parser) bool {
        if (!self.unicode_sets or self.index >= self.source.len or self.source.len - self.index < 2) return false;
        return (self.source[self.index] == '&' and self.source[self.index + 1] == '&') or
            (self.source[self.index] == '-' and self.source[self.index + 1] == '-');
    }

    fn consumeSetOperator(self: *Parser) ?types.SetOperationKind {
        if (!self.atSetOperator()) return null;
        const kind: types.SetOperationKind = if (self.source[self.index] == '&') .intersection else .subtraction;
        self.index += 2;
        return kind;
    }

    fn parseClassItem(self: *Parser) !types.ClassItem {
        if (self.index >= self.source.len) return error.UnclosedCharacterClass;
        if (self.unicode_sets and self.source[self.index] == '[') {
            self.index += 1;
            return .{ .nested_class = try self.parseClass() };
        }
        const unit = self.source[self.index];
        self.index += 1;
        if (unit != '\\') {
            if (self.unicode and unicode.isHighSurrogate(unit) and self.index < self.source.len and unicode.isLowSurrogate(self.source[self.index])) {
                const code_point = unicode.surrogatePairCodePoint(unit, self.source[self.index]);
                self.index += 1;
                return .{ .code_point = code_point };
            }
            return .{ .literal = unit };
        }
        const escaped_unit = if (self.index < self.source.len) self.source[self.index] else 0;
        const atom = self.parseEscape(true) catch |failure| switch (failure) {
            error.InvalidUnicodeProperty => return error.InvalidUnicodePropertyInClass,
            // In a character class, V8 reports both a malformed named
            // backreference introducer (`\\k`) and a named backreference
            // (`\\k<name>`) as a generic invalid escape.  Keep the parser
            // error contextual so the shared message formatter can match
            // that distinction without changing the outside-class error.
            error.InvalidNamedReference => return error.InvalidClassEscape,
            else => return failure,
        };
        return switch (atom) {
            .literal => |literal| if (self.unicode and escaped_unit == 'u' and unicode.isHighSurrogate(literal)) if (consumeLowSurrogateEscape(self)) |low| .{ .code_point = unicode.surrogatePairCodePoint(literal, low) } else .{ .literal = literal } else .{ .literal = literal },
            .code_point => |code_point| .{ .code_point = code_point },
            .class => |class| if (class.operation == null and class.items.len == 1) class.items[0] else if (self.unicode_sets) .{ .nested_class = class } else error.InvalidClassEscape,
            .unicode_property => |property| .{ .unicode_property = property },
            else => error.InvalidClassEscape,
        };
    }

    fn parseEscape(self: *Parser, in_class: bool) !types.Atom {
        if (self.index >= self.source.len) return error.InvalidEscape;
        const escaped = self.source[self.index];
        self.index += 1;
        return switch (escaped) {
            'd' => self.singletonClass(.digit),
            'D' => self.singletonClass(.not_digit),
            'w' => self.singletonClass(.word),
            'W' => self.singletonClass(.not_word),
            's' => self.singletonClass(.space),
            'S' => self.singletonClass(.not_space),
            'b' => if (in_class) .{ .literal = 0x08 } else .{ .word_boundary = true },
            'B' => if (in_class) .{ .literal = 'B' } else .{ .word_boundary = false },
            'n' => .{ .literal = '\n' },
            'r' => .{ .literal = '\r' },
            't' => .{ .literal = '\t' },
            'f' => .{ .literal = 0x0c },
            'v' => .{ .literal = 0x0b },
            '0' => if (self.unicode and self.index < self.source.len and self.source[self.index] >= '0' and self.source[self.index] <= '9')
                error.InvalidDecimalEscape
            else if (self.unicode)
                .{ .literal = 0 }
            else
                .{ .literal = self.parseLegacyOctalEscape(escaped) },
            'c' => try self.parseControlEscape(),
            'k' => if (self.unicode) try self.parseNamedBackreference() else .{ .literal = 'k' },
            'x' => .{ .literal = try self.parseHex(2) },
            'u' => if (self.index < self.source.len and self.source[self.index] == '{')
                .{ .code_point = try self.parseCodePointEscape() }
            else
                .{ .literal = try self.parseHex(4) },
            '1'...'9' => blk: {
                // Annex B permits legacy octal escapes inside a non-Unicode
                // character class.  They are code units, not backreferences:
                // `[\\1]`, `[\\12]`, and `[\\123]` denote U+0001, LF, and
                // U+0053 respectively.  `\\8` and `\\9` remain identity
                // escapes in this legacy mode.
                if (in_class and !self.unicode) {
                    if (escaped <= '7') break :blk .{ .literal = self.parseLegacyOctalEscape(escaped) };
                    break :blk .{ .literal = escaped };
                }
                if (in_class and self.unicode) return error.InvalidDecimalEscape;
                if (in_class) break :blk .{ .literal = escaped };
                if (!self.unicode) break :blk .{ .legacy_decimal_escape = self.parseDecimalEscape() };
                break :blk .{ .unicode_decimal_escape = self.parseDecimalEscape() };
            },
            'p', 'P' => try self.parseUnicodeProperty(escaped == 'P'),
            else => if (self.unicode and !isUnicodeIdentityEscape(escaped, in_class))
                error.InvalidIdentityEscape
            else
                .{ .literal = escaped },
        };
    }

    fn parseHex(self: *Parser, count: usize) !u16 {
        if (self.index + count > self.source.len) return error.InvalidHexEscape;
        var result: u16 = 0;
        for (self.source[self.index .. self.index + count]) |unit| {
            if (unit > 0x7f) return error.InvalidHexEscape;
            result = result * 16 + (std.fmt.charToDigit(@intCast(unit), 16) catch return error.InvalidHexEscape);
        }
        self.index += count;
        return result;
    }

    fn parseLegacyOctalEscape(self: *Parser, first: u16) u16 {
        var value: u16 = first - '0';
        var digits: usize = 1;
        const maximum = if (first <= '3') @as(usize, 3) else @as(usize, 2);
        while (digits < maximum and self.index < self.source.len) {
            const unit = self.source[self.index];
            if (unit < '0' or unit > '7') break;
            value = value * 8 + (unit - '0');
            self.index += 1;
            digits += 1;
        }
        return value;
    }

    fn parseDecimalEscape(self: *Parser) []const u16 {
        const start = self.index - 1;
        var digits: usize = 1;
        while (digits < 3 and self.index < self.source.len and self.source[self.index] >= '0' and self.source[self.index] <= '9') : (digits += 1) {
            self.index += 1;
        }
        return self.source[start..self.index];
    }

    fn parseUnicodeProperty(self: *Parser, negated: bool) !types.Atom {
        if (!self.unicode) return .{ .literal = if (negated) 'P' else 'p' };
        if (!consume(self, '{')) return error.InvalidUnicodeProperty;
        const start = self.index;
        while (self.index < self.source.len and self.source[self.index] != '}') self.index += 1;
        if (self.index == start or self.index >= self.source.len) return error.InvalidUnicodeProperty;
        const property = unicode.lookupUnicodeProperty(self.source[start..self.index]) orelse return error.InvalidUnicodeProperty;
        self.index += 1;
        return .{ .unicode_property = .{ .property = property, .negated = negated } };
    }

    fn parseCodePointEscape(self: *Parser) !u21 {
        if (!self.unicode or self.index >= self.source.len or self.source[self.index] != '{') return error.InvalidUnicodeEscape;
        self.index += 1;
        const start = self.index;
        var value: u32 = 0;
        while (self.index < self.source.len and self.source[self.index] != '}') {
            const unit = self.source[self.index];
            if (unit > 0x7f) return error.InvalidUnicodeEscape;
            const digit = std.fmt.charToDigit(@intCast(unit), 16) catch return error.InvalidUnicodeEscape;
            value = std.math.mul(u32, value, 16) catch return error.InvalidUnicodeEscape;
            value = std.math.add(u32, value, digit) catch return error.InvalidUnicodeEscape;
            if (value > 0x10ffff) return error.InvalidUnicodeEscape;
            self.index += 1;
        }
        if (self.index == start or self.index >= self.source.len) return error.InvalidUnicodeEscape;
        self.index += 1;
        // ECMAScript permits Unicode escapes for surrogate code units.  A
        // lone surrogate remains observable in a UTF-16 string and is only
        // combined when the input contains a matching pair.
        return @intCast(value);
    }

    fn parseControlEscape(self: *Parser) !types.Atom {
        if (self.index >= self.source.len) return if (self.unicode) error.InvalidUnicodeEscape else .{ .literal = 'c' };
        const unit = self.source[self.index];
        const upper = if (unit >= 'a' and unit <= 'z') unit - ('a' - 'A') else unit;
        if (upper >= 'A' and upper <= 'Z') {
            self.index += 1;
            return .{ .literal = @intCast(upper - 'A' + 1) };
        }
        return if (self.unicode) error.InvalidUnicodeEscape else .{ .literal = 'c' };
    }

    fn parseNamedBackreference(self: *Parser) !types.Atom {
        if (!consume(self, '<')) return error.InvalidNamedReference;
        const start = self.index;
        while (self.index < self.source.len and self.source[self.index] != '>') self.index += 1;
        if (self.index == start or self.index >= self.source.len) return error.InvalidNamedCapture;
        const name = self.source[start..self.index];
        if (!captures.isValidNamedCapture(name)) return error.InvalidNamedCapture;
        self.index += 1;
        return .{ .named_backreference = name };
    }

    fn parseQuantifier(self: *Parser, piece: *types.Piece) !void {
        if (self.index >= self.source.len) return;
        switch (self.source[self.index]) {
            '*' => {
                piece.minimum = 0;
                piece.maximum = null;
                self.index += 1;
            },
            '+' => {
                piece.minimum = 1;
                piece.maximum = null;
                self.index += 1;
            },
            '?' => {
                piece.minimum = 0;
                piece.maximum = 1;
                self.index += 1;
            },
            '{' => {
                const saved = self.index;
                self.index += 1;
                const minimum = self.parseDecimal() orelse {
                    self.index = saved;
                    if (self.unicode) return error.IncompleteQuantifier;
                    return;
                };
                var maximum: ?usize = minimum;
                if (consume(self, ',')) maximum = self.parseDecimal();
                if (!consume(self, '}')) {
                    self.index = saved;
                    if (self.unicode) return error.IncompleteQuantifier;
                    return;
                }
                if (maximum) |limit| if (limit < minimum) return error.InvalidQuantifierRange;
                piece.minimum = minimum;
                piece.maximum = maximum;
            },
            else => return,
        }
        if (consume(self, '?')) piece.lazy = true;
    }

    fn parseDecimal(self: *Parser) ?usize {
        const start = self.index;
        var value: usize = 0;
        while (self.index < self.source.len and self.source[self.index] >= '0' and self.source[self.index] <= '9') {
            value = std.math.mul(usize, value, 10) catch return null;
            value = std.math.add(usize, value, self.source[self.index] - '0') catch return null;
            self.index += 1;
        }
        return if (self.index == start) null else value;
    }

    fn singletonClass(self: *Parser, item: types.ClassItem) !types.Atom {
        const items = try self.allocator.alloc(types.ClassItem, 1);
        items[0] = item;
        const class = try self.allocator.create(types.CharacterClass);
        class.* = .{ .negated = false, .items = items };
        return .{ .class = class };
    }

    pub fn consume(self: *Parser, unit: u16) bool {
        if (self.index >= self.source.len or self.source[self.index] != unit) return false;
        self.index += 1;
        return true;
    }
};

pub fn isUnicodeIdentityEscape(unit: u16, in_class: bool) bool {
    return switch (unit) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
        '-' => in_class,
        else => false,
    };
}

pub fn consumeLowSurrogateEscape(parser: *Parser) ?u16 {
    if (parser.index + 6 > parser.source.len or parser.source[parser.index] != '\\' or parser.source[parser.index + 1] != 'u') return null;
    var value: u16 = 0;
    for (parser.source[parser.index + 2 .. parser.index + 6]) |unit| {
        if (unit > 0x7f) return null;
        value = value * 16 + (std.fmt.charToDigit(@intCast(unit), 16) catch return null);
    }
    if (!unicode.isLowSurrogate(value)) return null;
    parser.index += 6;
    return value;
}
