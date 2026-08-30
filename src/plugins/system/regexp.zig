const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const common = @import("common.zig");
const unicode_case = @import("unicode_case");
const unicode_properties = @import("unicode_properties");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

const max_captures = 64;
pub const CallResult = struct { value: Value, captures: ?Value = null };

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
const Candidate = struct { position: usize, captures: [max_captures]Span };
pub const Match = struct { span: Span, captures: [max_captures]Span };
const UnicodeProperty = struct { property: unicode_properties.Property, negated: bool };

const ClassItem = union(enum) {
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
const SetOperationKind = enum { intersection, subtraction };
const SetOperation = struct {
    kind: SetOperationKind,
    left: *CharacterClass,
    right: *CharacterClass,
};
const CharacterClass = struct {
    negated: bool,
    items: []const ClassItem,
    operation: ?*SetOperation = null,
};
const Group = struct {
    expression: *Expression,
    capture: ?usize,
    name: ?[]const u16,
    capture_start: usize,
    capture_end: usize,
};
const Assertion = struct {
    expression: *Expression,
    positive: bool,
    behind: bool,
    capture_start: usize,
    capture_end: usize,
};
const Atom = union(enum) {
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
    unicode_property: UnicodeProperty,
};
const Piece = struct { atom: Atom, minimum: usize = 1, maximum: ?usize = 1, lazy: bool = false };
const Sequence = struct { pieces: []const Piece };
const Expression = struct { alternatives: []const Sequence };

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

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u16,
    unicode: bool = false,
    unicode_sets: bool = false,
    index: usize = 0,
    capture_count: usize = 0,
    max_backreference: ?usize = null,
    capture_names: [max_captures]?[]const u16 = [_]?[]const u16{null} ** max_captures,

    fn parseExpression(self: *Parser) anyerror!*Expression {
        var alternatives: std.ArrayList(Sequence) = .empty;
        while (true) {
            try alternatives.append(self.allocator, try self.parseSequence());
            if (self.index >= self.source.len or self.source[self.index] != '|') break;
            self.index += 1;
        }
        const expression = try self.allocator.create(Expression);
        expression.* = .{ .alternatives = try alternatives.toOwnedSlice(self.allocator) };
        return expression;
    }

    fn parseSequence(self: *Parser) anyerror!Sequence {
        var pieces: std.ArrayList(Piece) = .empty;
        while (self.index < self.source.len and self.source[self.index] != ')' and self.source[self.index] != '|') {
            var piece = Piece{ .atom = try self.parseAtom() };
            try self.parseQuantifier(&piece);
            try pieces.append(self.allocator, piece);
        }
        return .{ .pieces = try pieces.toOwnedSlice(self.allocator) };
    }

    fn parseAtom(self: *Parser) anyerror!Atom {
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
            else => if (self.unicode and isHighSurrogate(unit) and self.index < self.source.len and isLowSurrogate(self.source[self.index])) blk: {
                const code_point = surrogatePairCodePoint(unit, self.source[self.index]);
                self.index += 1;
                break :blk .{ .code_point = code_point };
            } else .{ .literal = unit },
        };
    }

    fn parseGroup(self: *Parser) anyerror!Atom {
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
                    if (!isValidNamedCapture(name.?)) return error.InvalidNamedCapture;
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
            if (self.capture_count >= max_captures) return error.TooManyCaptures;
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

    fn parseClass(self: *Parser) anyerror!*CharacterClass {
        const negated = consume(self, '^');
        var left = try self.parseClassOperand();
        while (self.consumeSetOperator()) |kind| {
            if (left.operation == null and left.items.len == 0) return error.InvalidCharacterClass;
            if (!isSetOperand(left)) return error.UnsupportedUnicodeSetOperation;
            if (self.index >= self.source.len or self.source[self.index] == ']' or self.atSetOperator()) return error.InvalidCharacterInClass;
            const right = try self.parseClassOperand();
            if (right.items.len == 0 and right.operation == null) return error.InvalidCharacterInClass;
            if (!isSetOperand(right)) return error.UnsupportedUnicodeSetOperation;
            const operation = try self.allocator.create(SetOperation);
            operation.* = .{ .kind = kind, .left = left, .right = right };
            const result = try self.allocator.create(CharacterClass);
            result.* = .{ .negated = false, .items = &.{}, .operation = operation };
            left = result;
        }
        if (!consume(self, ']')) return error.UnclosedCharacterClass;
        left.negated = negated;
        return left;
    }

    fn parseClassOperand(self: *Parser) !*CharacterClass {
        var items: std.ArrayList(ClassItem) = .empty;
        while (self.index < self.source.len and self.source[self.index] != ']') {
            if (self.atSetOperator()) break;
            const first = try self.parseClassItem();
            if (self.atSetOperator()) {
                try items.append(self.allocator, first);
                break;
            }
            if (classItemCodePoint(first)) |first_code_point| {
                if (self.index + 1 < self.source.len and self.source[self.index] == '-' and self.source[self.index + 1] != ']') {
                    self.index += 1;
                    const last = try self.parseClassItem();
                    const last_code_point = classItemCodePoint(last) orelse return if (self.unicode) error.InvalidCharacterClass else error.InvalidCharacterRange;
                    if (last_code_point < first_code_point) return error.InvalidCharacterRange;
                    try items.append(self.allocator, .{ .range = .{ .first = first_code_point, .last = last_code_point } });
                } else try items.append(self.allocator, first);
            } else if (self.unicode and self.index + 1 < self.source.len and self.source[self.index] == '-' and self.source[self.index + 1] != ']') {
                return error.InvalidCharacterClass;
            } else try items.append(self.allocator, first);
        }
        const class = try self.allocator.create(CharacterClass);
        class.* = .{ .negated = false, .items = try items.toOwnedSlice(self.allocator) };
        return class;
    }

    fn atSetOperator(self: *const Parser) bool {
        if (!self.unicode_sets or self.index >= self.source.len or self.source.len - self.index < 2) return false;
        return (self.source[self.index] == '&' and self.source[self.index + 1] == '&') or
            (self.source[self.index] == '-' and self.source[self.index + 1] == '-');
    }

    fn consumeSetOperator(self: *Parser) ?SetOperationKind {
        if (!self.atSetOperator()) return null;
        const kind: SetOperationKind = if (self.source[self.index] == '&') .intersection else .subtraction;
        self.index += 2;
        return kind;
    }

    fn parseClassItem(self: *Parser) !ClassItem {
        if (self.index >= self.source.len) return error.UnclosedCharacterClass;
        if (self.unicode_sets and self.source[self.index] == '[') {
            self.index += 1;
            return .{ .nested_class = try self.parseClass() };
        }
        const unit = self.source[self.index];
        self.index += 1;
        if (unit != '\\') {
            if (self.unicode and isHighSurrogate(unit) and self.index < self.source.len and isLowSurrogate(self.source[self.index])) {
                const code_point = surrogatePairCodePoint(unit, self.source[self.index]);
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
            .literal => |literal| if (self.unicode and escaped_unit == 'u' and isHighSurrogate(literal)) if (consumeLowSurrogateEscape(self)) |low| .{ .code_point = surrogatePairCodePoint(literal, low) } else .{ .literal = literal } else .{ .literal = literal },
            .code_point => |code_point| .{ .code_point = code_point },
            .class => |class| if (class.operation == null and class.items.len == 1) class.items[0] else if (self.unicode_sets) .{ .nested_class = class } else error.InvalidClassEscape,
            .unicode_property => |property| .{ .unicode_property = property },
            else => error.InvalidClassEscape,
        };
    }

    fn parseEscape(self: *Parser, in_class: bool) !Atom {
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
                const capture_index = escaped - '1';
                if (self.unicode) {
                    if (self.max_backreference) |current| {
                        if (capture_index > current) self.max_backreference = capture_index;
                    } else self.max_backreference = capture_index;
                }
                break :blk .{ .backreference = capture_index };
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
        while (digits < 3 and self.index < self.source.len) {
            const unit = self.source[self.index];
            if (unit < '0' or unit > '7') break;
            value = value * 8 + (unit - '0');
            self.index += 1;
            digits += 1;
        }
        return value;
    }

    fn parseUnicodeProperty(self: *Parser, negated: bool) !Atom {
        if (!self.unicode) return .{ .literal = if (negated) 'P' else 'p' };
        if (!consume(self, '{')) return error.InvalidUnicodeProperty;
        const start = self.index;
        while (self.index < self.source.len and self.source[self.index] != '}') self.index += 1;
        if (self.index == start or self.index >= self.source.len) return error.InvalidUnicodeProperty;
        const property = lookupUnicodeProperty(self.source[start..self.index]) orelse return error.InvalidUnicodeProperty;
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

    fn parseControlEscape(self: *Parser) !Atom {
        if (self.index >= self.source.len) return if (self.unicode) error.InvalidUnicodeEscape else .{ .literal = 'c' };
        const unit = self.source[self.index];
        const upper = if (unit >= 'a' and unit <= 'z') unit - ('a' - 'A') else unit;
        if (upper >= 'A' and upper <= 'Z') {
            self.index += 1;
            return .{ .literal = @intCast(upper - 'A' + 1) };
        }
        return if (self.unicode) error.InvalidUnicodeEscape else .{ .literal = 'c' };
    }

    fn parseNamedBackreference(self: *Parser) !Atom {
        if (!self.consume('<')) return error.InvalidNamedReference;
        const start = self.index;
        while (self.index < self.source.len and self.source[self.index] != '>') self.index += 1;
        if (self.index == start or self.index >= self.source.len) return error.InvalidNamedCapture;
        const name = self.source[start..self.index];
        if (!isValidNamedCapture(name)) return error.InvalidNamedCapture;
        self.index += 1;
        return .{ .named_backreference = name };
    }

    fn parseQuantifier(self: *Parser, piece: *Piece) !void {
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

    fn singletonClass(self: *Parser, item: ClassItem) !Atom {
        const items = try self.allocator.alloc(ClassItem, 1);
        items[0] = item;
        const class = try self.allocator.create(CharacterClass);
        class.* = .{ .negated = false, .items = items };
        return .{ .class = class };
    }

    fn consume(self: *Parser, unit: u16) bool {
        if (self.index >= self.source.len or self.source[self.index] != unit) return false;
        self.index += 1;
        return true;
    }
};

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    const result = (try callWithEffects(runtime, name, arguments)) orelse return null;
    return result.value;
}

pub fn callWithEffects(runtime: *Runtime, name: []const u8, arguments: []const Value) !?CallResult {
    if (!isRegexpCommand(name)) return null;
    var source_string = try ownedText(runtime, common.argument(arguments, 0));
    defer source_string.deinit();
    var pattern_string = try ownedText(runtime, common.argument(arguments, 1));
    defer pattern_string.deinit();
    var compiled = compile(runtime.allocator(), pattern_string.units, defaultGlobal(name)) catch |failure| {
        try setCompileFailureMessage(runtime, pattern_string.units, defaultGlobal(name), failure);
        return failure;
    };
    defer compiled.deinit();
    if (eql(name, "正規表現マッチ")) return try matchCommand(runtime, source_string.units, &compiled);
    if (eql(name, "正規表現抽出")) return try extractCommand(runtime, source_string.units, &compiled);
    if (eql(name, "正規表現置換")) {
        var replacement = try ownedText(runtime, common.argument(arguments, 2));
        defer replacement.deinit();
        return .{ .value = try replaceCommand(runtime, source_string.units, replacement.units, &compiled) };
    }
    return .{ .value = try splitCommand(runtime, source_string.units, &compiled) };
}

pub const RawPattern = struct {
    allocator: std.mem.Allocator,
    compiled: Compiled,

    pub fn init(allocator: std.mem.Allocator, pattern: []const u16, ignore_case: bool) !RawPattern {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned_pattern = try arena.allocator().dupe(u16, pattern);
        var parser = Parser{ .allocator = arena.allocator(), .source = owned_pattern, .unicode = false };
        const expression = try parser.parseExpression();
        if (parser.index != owned_pattern.len) return error.UnexpectedPatternToken;
        if (parser.max_backreference) |capture_index| if (capture_index >= parser.capture_count) return error.InvalidBackreference;
        return .{
            .allocator = allocator,
            .compiled = .{
                .arena = arena,
                .expression = expression,
                .flags = .{ .ignore_case = ignore_case },
                .capture_count = parser.capture_count,
                .capture_names = parser.capture_names,
            },
        };
    }

    pub fn deinit(self: *RawPattern) void {
        self.compiled.deinit();
        self.* = undefined;
    }

    pub fn matches(self: *const RawPattern, source: []const u16) !bool {
        return try findOne(self.allocator, source, &self.compiled, 0) != null;
    }
};

pub fn testRaw(allocator: std.mem.Allocator, pattern: []const u16, source: []const u16, ignore_case: bool) !bool {
    var compiled = try RawPattern.init(allocator, pattern, ignore_case);
    defer compiled.deinit();
    return compiled.matches(source);
}

const SpecificationParts = struct {
    pattern: []const u16,
    flags: []const u16,
    delimited: bool,
};

fn splitSpecification(specification: []const u16) SpecificationParts {
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
        const flags_utf8 = try (value_mod.String{ .allocator = allocator, .units = @constCast(parts.flags) }).toUtf8Lossy(allocator);
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
    const pattern_utf8 = try (value_mod.String{ .allocator = allocator, .units = @constCast(parts.pattern) }).toUtf8Lossy(allocator);
    defer allocator.free(pattern_utf8);
    if (parts.delimited) {
        const flags_utf8 = try (value_mod.String{ .allocator = allocator, .units = @constCast(parts.flags) }).toUtf8Lossy(allocator);
        defer allocator.free(flags_utf8);
        return try std.fmt.allocPrint(allocator, "Invalid regular expression: /{s}/{s}: {s}", .{ pattern_utf8, flags_utf8, reason });
    }
    return try std.fmt.allocPrint(allocator, "Invalid regular expression: /{s}/{s}: {s}", .{ pattern_utf8, if (default_global) "g" else "", reason });
}

pub fn setCompileFailureMessage(runtime: *Runtime, specification: []const u16, default_global: bool, failure: anyerror) !void {
    const message = try compileFailureMessageAlloc(runtime.allocator(), specification, default_global, failure) orelse return;
    defer runtime.allocator().free(message);
    try runtime.setFailureMessage(message);
}

fn compile(allocator: std.mem.Allocator, specification: []const u16, default_global: bool) !Compiled {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const parts = splitSpecification(specification);
    const pattern = parts.pattern;
    var flags = Flags{ .global = default_global };
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
    const owned_pattern = try arena.allocator().dupe(u16, pattern);
    var parser = Parser{
        .allocator = arena.allocator(),
        .source = owned_pattern,
        .unicode = flags.unicode,
        .unicode_sets = flags.unicode_sets,
    };
    const expression = try parser.parseExpression();
    if (parser.index != owned_pattern.len) return error.UnexpectedPatternToken;
    try resolveNamedBackreferences(expression, parser.capture_names[0..parser.capture_count]);
    if (parser.max_backreference) |capture_index| if (capture_index >= parser.capture_count) return error.InvalidBackreference;
    return .{ .arena = arena, .expression = expression, .flags = flags, .capture_count = parser.capture_count, .capture_names = parser.capture_names };
}

fn resolveNamedBackreferences(expression: *Expression, names: []const ?[]const u16) anyerror!void {
    for (@constCast(expression.alternatives)) |*alternative| {
        for (@constCast(alternative.pieces)) |*piece| try resolveNamedBackreferencesInAtom(&piece.atom, names);
    }
}

fn resolveNamedBackreferencesInAtom(atom: *Atom, names: []const ?[]const u16) anyerror!void {
    switch (atom.*) {
        .group => |group| try resolveNamedBackreferences(group.expression, names),
        .assertion => |assertion| try resolveNamedBackreferences(assertion.expression, names),
        .named_backreference => |name| {
            var resolved: ?usize = null;
            for (names, 0..) |candidate, index| if (candidate) |actual| {
                if (std.mem.eql(u16, actual, name)) {
                    resolved = index;
                    break;
                }
            };
            atom.* = .{ .backreference = resolved orelse return error.InvalidNamedBackreference };
        },
        else => {},
    }
}

/// Compile the public `/pattern/flags` specification for execution engines
/// other than the interpreter. The returned value owns all parser storage.
pub fn compilePattern(allocator: std.mem.Allocator, specification: []const u16, default_global: bool) !Compiled {
    return compile(allocator, specification, default_global);
}

fn findAll(allocator: std.mem.Allocator, source: []const u16, compiled: *const Compiled) ![]Match {
    var results: std.ArrayList(Match) = .empty;
    var position: usize = 0;
    while (position <= source.len) {
        const found = try findOne(allocator, source, compiled, position);
        if (found == null) break;
        try results.append(allocator, found.?);
        if (!compiled.flags.global) break;
        position = if (found.?.span.end > found.?.span.start)
            found.?.span.end
        else
            advanceStringIndex(source, found.?.span.end, compiled.flags.unicode);
    }
    return results.toOwnedSlice(allocator);
}

/// Return matches in the shared engine's evaluation order. The caller owns
/// the returned slice and must keep `compiled` alive while reading it.
pub fn findMatches(allocator: std.mem.Allocator, source: []const u16, compiled: *const Compiled) ![]Match {
    return findAll(allocator, source, compiled);
}

fn findOne(allocator: std.mem.Allocator, source: []const u16, compiled: *const Compiled, from: usize) !?Match {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var start = @min(from, source.len);
    const last_start = if (compiled.flags.sticky) start else source.len;
    while (start <= last_start) {
        const initial = Candidate{ .position = start, .captures = [_]Span{.{}} ** max_captures };
        const candidates = try matchExpression(arena.allocator(), source, compiled.expression, initial, compiled.flags);
        if (candidates.len > 0) return .{ .span = .{ .start = start, .end = candidates[0].position, .matched = true }, .captures = candidates[0].captures };
        if (start == last_start) break;
        // RegExp's non-sticky Unicode search advances by StringIndex, so a
        // paired surrogate is never revisited from its low-surrogate code
        // unit. Non-Unicode search remains code-unit based.
        start = advanceStringIndex(source, start, compiled.flags.unicode);
    }
    return null;
}

fn matchExpression(allocator: std.mem.Allocator, source: []const u16, expression: *const Expression, initial: Candidate, flags: Flags) anyerror![]Candidate {
    var output: std.ArrayList(Candidate) = .empty;
    for (expression.alternatives) |sequence| {
        const matches = try matchSequence(allocator, source, sequence, initial, flags);
        try output.appendSlice(allocator, matches);
    }
    return output.toOwnedSlice(allocator);
}

fn matchSequence(allocator: std.mem.Allocator, source: []const u16, sequence: Sequence, initial: Candidate, flags: Flags) anyerror![]Candidate {
    var current: std.ArrayList(Candidate) = .empty;
    try current.append(allocator, initial);
    for (sequence.pieces) |piece| {
        var next: std.ArrayList(Candidate) = .empty;
        for (current.items) |candidate| {
            const expanded = try expandPiece(allocator, source, piece, candidate, flags);
            try next.appendSlice(allocator, expanded);
        }
        current = next;
        if (current.items.len == 0) break;
    }
    return current.toOwnedSlice(allocator);
}

fn clearCaptureRange(candidate: *Candidate, start: usize, end: usize) void {
    const bounded_start = @min(start, max_captures);
    const bounded_end = @min(end, max_captures);
    if (bounded_start < bounded_end) @memset(candidate.captures[bounded_start..bounded_end], .{});
}

fn clearAtomCaptures(candidate: *Candidate, atom: Atom) void {
    switch (atom) {
        .group => |group| clearCaptureRange(candidate, group.capture_start, group.capture_end),
        .assertion => |assertion| clearCaptureRange(candidate, assertion.capture_start, assertion.capture_end),
        else => {},
    }
}

fn expandPiece(allocator: std.mem.Allocator, source: []const u16, piece: Piece, initial: Candidate, flags: Flags) anyerror![]Candidate {
    var output: std.ArrayList(Candidate) = .empty;
    // A zero-width atom still counts as a repetition.  The previous
    // source-length bound was enough to prevent consuming atoms from
    // running past the input, but it incorrectly made `(){100,}` unable to
    // satisfy its minimum on a short input.  For an unbounded quantifier,
    // keep enough levels for the minimum and at least one level per input
    // code unit for consuming paths.
    const limit = piece.maximum orelse @max(source.len + 1, piece.minimum);
    try expandPieceOrdered(allocator, source, piece, initial, flags, 0, limit, &output);
    return output.toOwnedSlice(allocator);
}

fn expandPieceOrdered(
    allocator: std.mem.Allocator,
    source: []const u16,
    piece: Piece,
    candidate: Candidate,
    flags: Flags,
    repetition: usize,
    limit: usize,
    output: *std.ArrayList(Candidate),
) anyerror!void {
    const can_repeat = repetition < limit;
    if (!piece.lazy and can_repeat) {
        const atom_matches = try matchAtom(allocator, source, piece.atom, candidate, flags);
        for (atom_matches) |atom_match| {
            // An unbounded zero-width quantifier needs only its minimum
            // number of zero-width repetitions.  Beyond that point the
            // same candidate would form an infinite branch.  Finite
            // quantifiers are already bounded, so their zero-width
            // repetitions must be retained through the declared limit.
            if (atom_match.position == candidate.position and
                piece.maximum == null and repetition + 1 > piece.minimum) continue;
            // A greedy quantifier explores the atom's own choices before
            // trying the current repetition as a result.  This preserves
            // the backtracking order of nested quantifiers such as
            // `/(a+)+b/`, where the inner greedy `a+` must win first.
            try expandPieceOrdered(allocator, source, piece, atom_match, flags, repetition + 1, limit, output);
        }
    }
    var stopped = candidate;
    // A zero-occurrence optional group does not participate in the match. If
    // the same candidate came from an earlier repetition of an enclosing
    // group, its old captures must not leak into this non-participating path.
    if (repetition == 0 and piece.minimum == 0) clearAtomCaptures(&stopped, piece.atom);
    if (repetition >= piece.minimum) try output.append(allocator, stopped);
    if (piece.lazy and can_repeat) {
        const atom_matches = try matchAtom(allocator, source, piece.atom, candidate, flags);
        for (atom_matches) |atom_match| {
            if (atom_match.position == candidate.position and
                piece.maximum == null and repetition + 1 > piece.minimum) continue;
            try expandPieceOrdered(allocator, source, piece, atom_match, flags, repetition + 1, limit, output);
        }
    }
}

fn matchAtom(allocator: std.mem.Allocator, source: []const u16, atom: Atom, initial: Candidate, flags: Flags) anyerror![]Candidate {
    var output: std.ArrayList(Candidate) = .empty;
    switch (atom) {
        .literal => |literal| {
            if (flags.unicode) {
                if (codePointAt(source, initial.position)) |actual| {
                    if (codePointsEqual(actual.value, literal, flags)) {
                        var candidate = initial;
                        candidate.position += actual.width;
                        try output.append(allocator, candidate);
                    }
                }
            } else if (initial.position < source.len and unitsEqual(source[initial.position], literal, flags.ignore_case)) {
                var candidate = initial;
                candidate.position += 1;
                try output.append(allocator, candidate);
            }
        },
        .code_point => |code_point| if (codePointAt(source, initial.position)) |actual| if (codePointsEqual(actual.value, code_point, flags)) {
            var candidate = initial;
            candidate.position += actual.width;
            try output.append(allocator, candidate);
        },
        .dot => if (initial.position < source.len and (flags.dot_all or !isLineTerminator(source[initial.position]))) {
            var candidate = initial;
            candidate.position += codePointWidth(source, initial.position, flags.unicode);
            try output.append(allocator, candidate);
        },
        .class => |class| if (initial.position < source.len and classMatches(class, source, initial.position, flags)) {
            var candidate = initial;
            candidate.position += codePointWidth(source, initial.position, flags.unicode);
            try output.append(allocator, candidate);
        },
        .unicode_property => |property| if (initial.position < source.len) {
            if (codePointAt(source, initial.position)) |actual| {
                if (propertyMatches(property, actual.value, flags)) {
                    var candidate = initial;
                    candidate.position += actual.width;
                    try output.append(allocator, candidate);
                }
            }
        },
        .start_anchor => if (initial.position == 0 or (flags.multiline and initial.position > 0 and isLineTerminator(source[initial.position - 1]))) try output.append(allocator, initial),
        .end_anchor => if (initial.position == source.len or (flags.multiline and initial.position < source.len and isLineTerminator(source[initial.position]))) try output.append(allocator, initial),
        .word_boundary => |expected| {
            const left_word = if (flags.unicode)
                if (codePointBefore(source, initial.position)) |point| isWordCodePoint(point.value, flags) else false
            else
                initial.position > 0 and isWord(source[initial.position - 1]);
            const right_word = if (flags.unicode)
                if (codePointAt(source, initial.position)) |point| isWordCodePoint(point.value, flags) else false
            else
                initial.position < source.len and isWord(source[initial.position]);
            if ((left_word != right_word) == expected) try output.append(allocator, initial);
        },
        .backreference => |capture_index| {
            if (capture_index >= max_captures) return output.toOwnedSlice(allocator);
            if (!initial.captures[capture_index].matched) {
                // ECMAScript backreferences to an unmatched capture consume
                // an empty string rather than failing the candidate.
                try output.append(allocator, initial);
                return output.toOwnedSlice(allocator);
            }
            const span = initial.captures[capture_index];
            const length = span.end - span.start;
            if (initial.position + length <= source.len and slicesEqual(source[span.start..span.end], source[initial.position .. initial.position + length], flags)) {
                var candidate = initial;
                candidate.position += length;
                try output.append(allocator, candidate);
            }
        },
        .named_backreference => return output.toOwnedSlice(allocator),
        .group => |group| {
            var group_initial = initial;
            clearCaptureRange(&group_initial, group.capture_start, group.capture_end);
            const matches = try matchExpression(allocator, source, group.expression, group_initial, flags);
            for (matches) |match| {
                var candidate = match;
                if (group.capture) |capture_index| candidate.captures[capture_index] = .{ .start = initial.position, .end = match.position, .matched = true };
                try output.append(allocator, candidate);
            }
        },
        .assertion => |assertion| {
            var assertion_initial = initial;
            clearCaptureRange(&assertion_initial, assertion.capture_start, assertion.capture_end);
            if (!assertion.behind) {
                const assertion_matches = try matchExpression(allocator, source, assertion.expression, assertion_initial, flags);
                if (assertion.positive) {
                    for (assertion_matches) |match| {
                        var accepted = match;
                        accepted.position = initial.position;
                        try output.append(allocator, accepted);
                    }
                } else if (assertion_matches.len == 0) try output.append(allocator, assertion_initial);
            } else {
                var matched = false;
                var start: usize = 0;
                while (start <= initial.position) {
                    const behind_initial = Candidate{ .position = start, .captures = assertion_initial.captures };
                    const candidates = try matchExpression(allocator, source, assertion.expression, behind_initial, flags);
                    for (candidates) |candidate| if (candidate.position == initial.position) {
                        matched = true;
                        if (assertion.positive) {
                            var accepted = candidate;
                            accepted.position = initial.position;
                            try output.append(allocator, accepted);
                        }
                    };
                    if (start == initial.position) break;
                    start = advanceStringIndex(source, start, flags.unicode);
                }
                if (!assertion.positive and !matched) try output.append(allocator, assertion_initial);
            }
        },
    }
    return output.toOwnedSlice(allocator);
}

fn matchCommand(runtime: *Runtime, source: []const u16, compiled: *const Compiled) !CallResult {
    const matches = try findAll(runtime.allocator(), source, compiled);
    defer runtime.allocator().free(matches);
    var captures = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&captures);
    if (matches.len == 0) return .{ .value = .null_value, .captures = captures };
    if (!compiled.flags.global) {
        for (matches[0].captures[0..compiled.capture_count]) |span| {
            _ = try captures.array.push(if (span.matched) try runtime.stringCodeUnits(source[span.start..span.end]) else .undefined);
        }
        return .{ .value = try runtime.stringCodeUnits(source[matches[0].span.start..matches[0].span.end]), .captures = captures };
    }
    var result = try runtime.createArray();
    try roots.protect(&result);
    for (matches) |match| _ = try result.array.push(try runtime.stringCodeUnits(source[match.span.start..match.span.end]));
    return .{ .value = result, .captures = captures };
}

fn extractCommand(runtime: *Runtime, source: []const u16, compiled: *Compiled) !CallResult {
    compiled.flags.global = true;
    const matches = try findAll(runtime.allocator(), source, compiled);
    defer runtime.allocator().free(matches);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var result = try runtime.createArray();
    try roots.protect(&result);
    var rows = try runtime.createArray();
    try roots.protect(&rows);
    for (matches) |match| {
        var has_named = false;
        for (compiled.capture_names[0..compiled.capture_count]) |name| if (name != null) {
            has_named = true;
            break;
        };
        if (has_named) {
            var row = try runtime.createDictionary();
            var row_roots = runtime.rootFrame();
            defer row_roots.deinit();
            try row_roots.protect(&row);
            for (compiled.capture_names[0..compiled.capture_count], 0..) |name, index| if (name) |key_units| {
                const span = match.captures[index];
                var item = if (span.matched) try runtime.stringCodeUnits(source[span.start..span.end]) else .undefined;
                var item_roots = runtime.rootFrame();
                defer item_roots.deinit();
                try item_roots.protect(&item);
                var key = try runtime.stringCodeUnits(key_units);
                try item_roots.protect(&key);
                try row.dictionary.set(key.string, item);
                _ = try result.array.push(item);
            };
            _ = try rows.array.push(row);
        } else {
            var row = try runtime.createArray();
            var row_roots = runtime.rootFrame();
            defer row_roots.deinit();
            try row_roots.protect(&row);
            if (compiled.capture_count == 0) {
                const item = try runtime.stringCodeUnits(source[match.span.start..match.span.end]);
                _ = try row.array.push(item);
                _ = try result.array.push(item);
            } else for (match.captures[0..compiled.capture_count]) |span| {
                const item = if (span.matched) try runtime.stringCodeUnits(source[span.start..span.end]) else .undefined;
                _ = try row.array.push(item);
                _ = try result.array.push(item);
            }
            _ = try rows.array.push(row);
        }
    }
    return .{ .value = result, .captures = rows };
}

fn replaceCommand(runtime: *Runtime, source: []const u16, replacement: []const u16, compiled: *const Compiled) !Value {
    const output = try replaceUnits(runtime.allocator(), source, replacement, compiled);
    defer runtime.allocator().free(output);
    return runtime.stringCodeUnits(output);
}

/// Apply the regexp replacement expansion and return owned UTF-16 units.
/// This is shared by the interpreter and AOT runtimes.
pub fn replaceUnits(allocator: std.mem.Allocator, source: []const u16, replacement: []const u16, compiled: *const Compiled) ![]u16 {
    const matches = try findAll(allocator, source, compiled);
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

fn appendReplacement(allocator: std.mem.Allocator, output: *std.ArrayList(u16), source: []const u16, replacement: []const u16, match: Match, compiled: *const Compiled) !void {
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
            const capture_index = if (end < replacement.len) namedCaptureIndex(compiled, replacement[index + 2 .. end]) else null;
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

fn splitCommand(runtime: *Runtime, source: []const u16, compiled: *const Compiled) !Value {
    var split_compiled = compiled.*;
    split_compiled.flags.global = true;
    const matches = try findAll(runtime.allocator(), source, &split_compiled);
    defer runtime.allocator().free(matches);
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    var cursor: usize = 0;
    for (matches) |match| {
        if (match.span.start == match.span.end and (match.span.start == 0 or match.span.start == source.len or match.span.start == cursor)) continue;
        _ = try result.array.push(try runtime.stringCodeUnits(source[cursor..match.span.start]));
        for (match.captures[0..compiled.capture_count]) |span| {
            _ = try result.array.push(if (span.matched) try runtime.stringCodeUnits(source[span.start..span.end]) else .undefined);
        }
        cursor = match.span.end;
    }
    _ = try result.array.push(try runtime.stringCodeUnits(source[cursor..]));
    if (source.len == 0 and matches.len > 0) result.array.items.clearRetainingCapacity();
    return result;
}

fn ownedText(runtime: *Runtime, value: Value) !value_mod.String {
    const converted = try runtime.valueToString(value);
    return value_mod.String.fromCodeUnits(runtime.allocator(), converted.string.units);
}

const CodePoint = struct { value: u21, width: usize };

fn classMatches(class: *const CharacterClass, source: []const u16, position: usize, flags: Flags) bool {
    const unit = source[position];
    const code_point = codePointAt(source, position).?;
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
                    codePointsEqual(code_point.value, literal, flags)
                else
                    unitsEqual(unit, literal, flags.ignore_case),
                .code_point => |literal| if (flags.unicode) codePointsEqual(code_point.value, literal, flags) else literal <= std.math.maxInt(u16) and unit == literal,
                .range => |range| blk_range: {
                    const value = if (flags.unicode) code_point.value else unit;
                    const folded = foldCodePoint(value, flags);
                    break :blk_range folded >= foldCodePoint(range.first, flags) and folded <= foldCodePoint(range.last, flags);
                },
                .digit => isDigit(unit),
                .not_digit => !isDigit(unit),
                .word => if (flags.unicode) isWordCodePoint(code_point.value, flags) else isWord(unit),
                .not_word => if (flags.unicode) !isWordCodePoint(code_point.value, flags) else !isWord(unit),
                .space => isWhitespace(unit),
                .not_space => !isWhitespace(unit),
                .unicode_property => |property| propertyMatches(property, code_point.value, flags),
                .nested_class => |nested| classMatches(nested, source, position, flags),
            };
            if (items_match) break;
        }
        break :blk items_match;
    };
    return matched != class.negated;
}

fn codePointAt(source: []const u16, position: usize) ?CodePoint {
    if (position >= source.len) return null;
    const first = source[position];
    if (isHighSurrogate(first) and position + 1 < source.len and isLowSurrogate(source[position + 1])) {
        return .{ .value = surrogatePairCodePoint(first, source[position + 1]), .width = 2 };
    }
    return .{ .value = first, .width = 1 };
}

fn codePointBefore(source: []const u16, position: usize) ?CodePoint {
    const end = @min(position, source.len);
    if (end == 0) return null;
    if (end >= 2 and isHighSurrogate(source[end - 2]) and isLowSurrogate(source[end - 1])) {
        return .{ .value = surrogatePairCodePoint(source[end - 2], source[end - 1]), .width = 2 };
    }
    return .{ .value = source[end - 1], .width = 1 };
}

fn codePointWidth(source: []const u16, position: usize, unicode: bool) usize {
    if (!unicode) return 1;
    return (codePointAt(source, position) orelse return 1).width;
}

fn advanceStringIndex(source: []const u16, position: usize, unicode: bool) usize {
    if (position >= source.len) return source.len + 1;
    return position + codePointWidth(source, position, unicode);
}

fn isHighSurrogate(unit: u16) bool {
    return unit >= 0xd800 and unit <= 0xdbff;
}

fn isLowSurrogate(unit: u16) bool {
    return unit >= 0xdc00 and unit <= 0xdfff;
}

fn surrogatePairCodePoint(high: u16, low: u16) u21 {
    return @intCast(0x10000 + (@as(u32, high) - 0xd800) * 0x400 + (@as(u32, low) - 0xdc00));
}

fn unitsEqual(left: u16, right: u16, ignore_case: bool) bool {
    return foldAscii(left, ignore_case) == foldAscii(right, ignore_case);
}

fn codePointsEqual(left: u21, right: u21, flags: Flags) bool {
    return foldCodePoint(left, flags) == foldCodePoint(right, flags);
}

fn propertyMatches(property: UnicodeProperty, codepoint: u21, flags: Flags) bool {
    if (flags.ignore_case and flags.unicode) {
        if (unicode_case.simpleFoldVariants(codepoint)) |variants| {
            for (variants) |variant| if (unicode_properties.contains(property.property, variant) != property.negated) return true;
            return false;
        }
    }
    return unicode_properties.contains(property.property, codepoint) != property.negated;
}

fn slicesEqual(left: []const u16, right: []const u16, flags: Flags) bool {
    if (!flags.unicode) {
        if (left.len != right.len) return false;
        for (left, right) |a, b| if (!unitsEqual(a, b, flags.ignore_case)) return false;
        return true;
    }
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left.len and right_index < right.len) {
        const left_point = codePointAt(left, left_index) orelse return false;
        const right_point = codePointAt(right, right_index) orelse return false;
        if (!codePointsEqual(left_point.value, right_point.value, flags)) return false;
        left_index += left_point.width;
        right_index += right_point.width;
    }
    return left_index == left.len and right_index == right.len;
}

fn foldCodePoint(codepoint: u21, flags: Flags) u21 {
    if (flags.ignore_case and flags.unicode) return unicode_case.simpleFold(codepoint);
    if (codepoint <= std.math.maxInt(u16)) return foldAscii(@intCast(codepoint), flags.ignore_case);
    return codepoint;
}

fn foldAscii(unit: u16, enabled: bool) u16 {
    if (!enabled) return unit;
    const mapped = unicode_case.lower(@intCast(unit)) orelse return unit;
    return if (mapped.len == 1 and mapped[0] <= std.math.maxInt(u16)) @intCast(mapped[0]) else unit;
}

fn isDigit(unit: u16) bool {
    return unit >= '0' and unit <= '9';
}

fn isWord(unit: u16) bool {
    return isAsciiWord(unit);
}

fn isWordCodePoint(codepoint: u21, flags: Flags) bool {
    if (codepoint <= 0x7f and isAsciiWord(codepoint)) return true;
    if (!(flags.unicode and flags.ignore_case)) return false;
    if (unicode_case.simpleFoldVariants(codepoint)) |variants| {
        for (variants) |variant| if (variant <= 0x7f and isAsciiWord(variant)) return true;
    }
    return false;
}

fn isAsciiWord(codepoint: u21) bool {
    return (codepoint >= '0' and codepoint <= '9') or
        (codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= 'a' and codepoint <= 'z') or
        codepoint == '_';
}

fn isWhitespace(unit: u16) bool {
    return switch (unit) {
        0x0009...0x000d, 0x0020, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}

fn classItemCodePoint(item: ClassItem) ?u21 {
    return switch (item) {
        .literal => |literal| literal,
        .code_point => |code_point| code_point,
        else => null,
    };
}

fn isSetOperand(class: *const CharacterClass) bool {
    if (class.operation != null) return true;
    if (class.items.len != 1) return false;
    return switch (class.items[0]) {
        .range => false,
        else => true,
    };
}

fn consumeLowSurrogateEscape(parser: *Parser) ?u16 {
    if (parser.index + 6 > parser.source.len or parser.source[parser.index] != '\\' or parser.source[parser.index + 1] != 'u') return null;
    var value: u16 = 0;
    for (parser.source[parser.index + 2 .. parser.index + 6]) |unit| {
        if (unit > 0x7f) return null;
        value = value * 16 + (std.fmt.charToDigit(@intCast(unit), 16) catch return null);
    }
    if (!isLowSurrogate(value)) return null;
    parser.index += 6;
    return value;
}

fn isLineTerminator(unit: u16) bool {
    return unit == '\n' or unit == '\r' or unit == 0x2028 or unit == 0x2029;
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

fn isUnicodeIdentityEscape(unit: u16, in_class: bool) bool {
    return switch (unit) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
        '-' => in_class,
        else => false,
    };
}

fn lookupUnicodeProperty(name: []const u16) ?unicode_properties.Property {
    if (asciiEquals(name, "ASCII")) return .ascii;
    if (asciiEquals(name, "Any")) return .any;
    if (asciiEquals(name, "ASCII_Hex_Digit")) return .ascii_hex_digit;
    if (asciiEquals(name, "AHex")) return .ascii_hex_digit;
    if (asciiEquals(name, "Assigned")) return .assigned;
    if (asciiEquals(name, "Alphabetic")) return .alphabetic;
    if (asciiEquals(name, "Alpha")) return .alphabetic;
    if (oneOf(name, &.{ "Bidi_Control", "Bidi_C" })) return .bidi_control;
    if (oneOf(name, &.{ "Bidi_Mirrored", "Bidi_M" })) return .bidi_mirrored;
    if (oneOf(name, &.{ "Case_Ignorable", "CI" })) return .case_ignorable;
    if (asciiEquals(name, "Cased")) return .cased;
    if (oneOf(name, &.{ "Changes_When_Casefolded", "CWCF" })) return .changes_when_casefolded;
    if (oneOf(name, &.{ "Changes_When_Casemapped", "CWCM" })) return .changes_when_casemapped;
    if (oneOf(name, &.{ "Changes_When_Lowercased", "CWL" })) return .changes_when_lowercased;
    if (oneOf(name, &.{ "Changes_When_NFKC_Casefolded", "CWKCF" })) return .changes_when_nfkc_casefolded;
    if (oneOf(name, &.{ "Changes_When_Titlecased", "CWT" })) return .changes_when_titlecased;
    if (oneOf(name, &.{ "Changes_When_Uppercased", "CWU" })) return .changes_when_uppercased;
    if (asciiEquals(name, "Dash")) return .dash;
    if (oneOf(name, &.{ "Default_Ignorable_Code_Point", "DI" })) return .default_ignorable_code_point;
    if (oneOf(name, &.{ "Deprecated", "Dep" })) return .deprecated;
    if (oneOf(name, &.{ "Diacritic", "Dia" })) return .diacritic;
    if (oneOf(name, &.{ "Emoji_Component", "EComp" })) return .emoji_component;
    if (oneOf(name, &.{ "Emoji_Modifier", "EMod" })) return .emoji_modifier;
    if (oneOf(name, &.{ "Emoji_Modifier_Base", "EBase" })) return .emoji_modifier_base;
    if (oneOf(name, &.{ "Extender", "Ext" })) return .extender;
    if (oneOf(name, &.{ "Grapheme_Base", "Gr_Base" })) return .grapheme_base;
    if (oneOf(name, &.{ "Grapheme_Extend", "Gr_Ext" })) return .grapheme_extend;
    if (oneOf(name, &.{ "Hex_Digit", "Hex" })) return .hex_digit;
    if (asciiEquals(name, "Ideographic") or asciiEquals(name, "Ideo")) return .ideographic;
    if (oneOf(name, &.{ "IDS_Binary_Operator", "IDSB" })) return .ids_binary_operator;
    if (oneOf(name, &.{ "IDS_Trinary_Operator", "IDST" })) return .ids_trinary_operator;
    if (oneOf(name, &.{ "Join_Control", "Join_C" })) return .join_control;
    if (oneOf(name, &.{ "Logical_Order_Exception", "LOE" })) return .logical_order_exception;
    if (oneOf(name, &.{ "Lowercase", "Lower" })) return .lowercase;
    if (asciiEquals(name, "Math")) return .math;
    if (oneOf(name, &.{ "Noncharacter_Code_Point", "NChar" })) return .noncharacter_code_point;
    if (oneOf(name, &.{ "Pattern_Syntax", "Pat_Syn" })) return .pattern_syntax;
    if (oneOf(name, &.{ "Pattern_White_Space", "Pat_WS" })) return .pattern_white_space;
    if (oneOf(name, &.{ "Quotation_Mark", "QMark" })) return .quotation_mark;
    if (asciiEquals(name, "Radical")) return .radical;
    if (oneOf(name, &.{ "Regional_Indicator", "RI" })) return .regional_indicator;
    if (oneOf(name, &.{ "Sentence_Terminal", "STerm" })) return .sentence_terminal;
    if (oneOf(name, &.{ "Soft_Dotted", "SD" })) return .soft_dotted;
    if (oneOf(name, &.{ "Terminal_Punctuation", "Term" })) return .terminal_punctuation;
    if (oneOf(name, &.{ "Unified_Ideograph", "UIdeo" })) return .unified_ideograph;
    if (oneOf(name, &.{ "Uppercase", "Upper" })) return .uppercase;
    if (oneOf(name, &.{ "Variation_Selector", "VS" })) return .variation_selector;
    if (asciiEquals(name, "White_Space")) return .white_space;
    if (asciiEquals(name, "WSpace")) return .white_space;
    if (asciiEquals(name, "Emoji")) return .emoji;
    if (asciiEquals(name, "Emoji_Presentation")) return .emoji_presentation;
    if (asciiEquals(name, "Extended_Pictographic")) return .extended_pictographic;
    if (asciiEquals(name, "ID_Start")) return .id_start;
    if (asciiEquals(name, "IDS")) return .id_start;
    if (asciiEquals(name, "ID_Continue")) return .id_continue;
    if (asciiEquals(name, "IDC")) return .id_continue;
    if (oneOf(name, &.{ "XID_Continue", "XIDC" })) return .xid_continue;
    if (oneOf(name, &.{ "XID_Start", "XIDS" })) return .xid_start;

    if (oneOf(name, &.{ "Cased_Letter", "LC", "General_Category=Cased_Letter", "General_Category=LC", "gc=Cased_Letter", "gc=LC" })) return .cased_letter;
    if (oneOf(name, &.{ "Close_Punctuation", "Pe", "General_Category=Close_Punctuation", "General_Category=Pe", "gc=Close_Punctuation", "gc=Pe" })) return .close_punctuation;
    if (oneOf(name, &.{ "Connector_Punctuation", "Pc", "General_Category=Connector_Punctuation", "General_Category=Pc", "gc=Connector_Punctuation", "gc=Pc" })) return .connector_punctuation;
    if (oneOf(name, &.{ "Control", "Cc", "General_Category=Control", "General_Category=Cc", "gc=Control", "gc=Cc" })) return .control;
    if (oneOf(name, &.{ "Currency_Symbol", "Sc", "General_Category=Currency_Symbol", "General_Category=Sc", "gc=Currency_Symbol", "gc=Sc" })) return .currency_symbol;
    if (oneOf(name, &.{ "Dash_Punctuation", "Pd", "General_Category=Dash_Punctuation", "General_Category=Pd", "gc=Dash_Punctuation", "gc=Pd" })) return .dash_punctuation;
    if (oneOf(name, &.{ "Enclosing_Mark", "Me", "General_Category=Enclosing_Mark", "General_Category=Me", "gc=Enclosing_Mark", "gc=Me" })) return .enclosing_mark;
    if (oneOf(name, &.{ "Final_Punctuation", "Pf", "General_Category=Final_Punctuation", "General_Category=Pf", "gc=Final_Punctuation", "gc=Pf" })) return .final_punctuation;
    if (oneOf(name, &.{ "Format", "Cf", "General_Category=Format", "General_Category=Cf", "gc=Format", "gc=Cf" })) return .format;
    if (oneOf(name, &.{ "Initial_Punctuation", "Pi", "General_Category=Initial_Punctuation", "General_Category=Pi", "gc=Initial_Punctuation", "gc=Pi" })) return .initial_punctuation;
    if (oneOf(name, &.{ "Letter_Number", "Nl", "General_Category=Letter_Number", "General_Category=Nl", "gc=Letter_Number", "gc=Nl" })) return .letter_number;
    if (oneOf(name, &.{ "Line_Separator", "Zl", "General_Category=Line_Separator", "General_Category=Zl", "gc=Line_Separator", "gc=Zl" })) return .line_separator;
    if (oneOf(name, &.{ "Math_Symbol", "Sm", "General_Category=Math_Symbol", "General_Category=Sm", "gc=Math_Symbol", "gc=Sm" })) return .math_symbol;
    if (oneOf(name, &.{ "Modifier_Letter", "Lm", "General_Category=Modifier_Letter", "General_Category=Lm", "gc=Modifier_Letter", "gc=Lm" })) return .modifier_letter;
    if (oneOf(name, &.{ "Modifier_Symbol", "Sk", "General_Category=Modifier_Symbol", "General_Category=Sk", "gc=Modifier_Symbol", "gc=Sk" })) return .modifier_symbol;
    if (oneOf(name, &.{ "Nonspacing_Mark", "Mn", "General_Category=Nonspacing_Mark", "General_Category=Mn", "gc=Nonspacing_Mark", "gc=Mn" })) return .nonspacing_mark;
    if (oneOf(name, &.{ "Open_Punctuation", "Ps", "General_Category=Open_Punctuation", "General_Category=Ps", "gc=Open_Punctuation", "gc=Ps" })) return .open_punctuation;
    if (oneOf(name, &.{ "Other", "C", "General_Category=Other", "General_Category=C", "gc=Other", "gc=C" })) return .other;
    if (oneOf(name, &.{ "Other_Letter", "Lo", "General_Category=Other_Letter", "General_Category=Lo", "gc=Other_Letter", "gc=Lo" })) return .other_letter;
    if (oneOf(name, &.{ "Other_Number", "No", "General_Category=Other_Number", "General_Category=No", "gc=Other_Number", "gc=No" })) return .other_number;
    if (oneOf(name, &.{ "Other_Punctuation", "Po", "General_Category=Other_Punctuation", "General_Category=Po", "gc=Other_Punctuation", "gc=Po" })) return .other_punctuation;
    if (oneOf(name, &.{ "Other_Symbol", "So", "General_Category=Other_Symbol", "General_Category=So", "gc=Other_Symbol", "gc=So" })) return .other_symbol;
    if (oneOf(name, &.{ "Paragraph_Separator", "Zp", "General_Category=Paragraph_Separator", "General_Category=Zp", "gc=Paragraph_Separator", "gc=Zp" })) return .paragraph_separator;
    if (oneOf(name, &.{ "Private_Use", "Co", "General_Category=Private_Use", "General_Category=Co", "gc=Private_Use", "gc=Co" })) return .private_use;
    if (oneOf(name, &.{ "Space_Separator", "Zs", "General_Category=Space_Separator", "General_Category=Zs", "gc=Space_Separator", "gc=Zs" })) return .space_separator;
    if (oneOf(name, &.{ "Spacing_Mark", "Mc", "General_Category=Spacing_Mark", "General_Category=Mc", "gc=Spacing_Mark", "gc=Mc" })) return .spacing_mark;
    if (oneOf(name, &.{ "Surrogate", "Cs", "General_Category=Surrogate", "General_Category=Cs", "gc=Surrogate", "gc=Cs" })) return .surrogate;
    if (oneOf(name, &.{ "Titlecase_Letter", "Lt", "General_Category=Titlecase_Letter", "General_Category=Lt", "gc=Titlecase_Letter", "gc=Lt" })) return .titlecase_letter;
    if (oneOf(name, &.{ "Unassigned", "Cn", "General_Category=Unassigned", "General_Category=Cn", "gc=Unassigned", "gc=Cn" })) return .unassigned;
    if (oneOf(name, &.{ "Letter", "L", "General_Category=Letter", "General_Category=L", "gc=Letter", "gc=L" })) return .letter;
    if (oneOf(name, &.{ "Lowercase_Letter", "Ll", "General_Category=Lowercase_Letter", "General_Category=Ll", "gc=Lowercase_Letter", "gc=Ll" })) return .lowercase_letter;
    if (oneOf(name, &.{ "Uppercase_Letter", "Lu", "General_Category=Uppercase_Letter", "General_Category=Lu", "gc=Uppercase_Letter", "gc=Lu" })) return .uppercase_letter;
    if (oneOf(name, &.{ "Mark", "M", "General_Category=Mark", "General_Category=M", "gc=Mark", "gc=M" })) return .mark;
    if (oneOf(name, &.{ "Number", "N", "General_Category=Number", "General_Category=N", "gc=Number", "gc=N" })) return .number;
    if (oneOf(name, &.{ "Decimal_Number", "Nd", "General_Category=Decimal_Number", "General_Category=Nd", "gc=Decimal_Number", "gc=Nd" })) return .decimal_number;
    if (oneOf(name, &.{ "Punctuation", "P", "General_Category=Punctuation", "General_Category=P", "gc=Punctuation", "gc=P" })) return .punctuation;
    if (oneOf(name, &.{ "Symbol", "S", "General_Category=Symbol", "General_Category=S", "gc=Symbol", "gc=S" })) return .symbol;
    if (oneOf(name, &.{ "Separator", "Z", "General_Category=Separator", "General_Category=Z", "gc=Separator", "gc=Z" })) return .separator;

    if (unicode_properties.lookupScript(name)) |property| return property;
    return null;
}

fn oneOf(name: []const u16, values: []const []const u8) bool {
    for (values) |value| if (asciiEquals(name, value)) return true;
    return false;
}

fn asciiEquals(units: []const u16, text: []const u8) bool {
    if (units.len != text.len) return false;
    for (text, 0..) |unit, index| if (units[index] != unit) return false;
    return true;
}

fn isValidNamedCapture(name: []const u16) bool {
    if (name.len == 0) return false;
    var ascii = true;
    for (name) |unit| if (unit > 0x7f) {
        ascii = false;
        break;
    };
    if (!ascii) return true;
    const first = name[0];
    if (!((first >= 'A' and first <= 'Z') or (first >= 'a' and first <= 'z') or first == '_' or first == '$')) return false;
    for (name[1..]) |unit| {
        if (!((unit >= 'A' and unit <= 'Z') or (unit >= 'a' and unit <= 'z') or (unit >= '0' and unit <= '9') or unit == '_' or unit == '$')) return false;
    }
    return true;
}

fn namedCaptureIndex(compiled: *const Compiled, name: []const u16) ?usize {
    for (compiled.capture_names[0..compiled.capture_count], 0..) |candidate, index| if (candidate) |actual| {
        if (std.mem.eql(u16, actual, name)) return index;
    };
    return null;
}

fn defaultGlobal(name: []const u8) bool {
    return eql(name, "正規表現マッチ") or eql(name, "正規表現抽出") or eql(name, "正規表現置換") or eql(name, "正規表現区切");
}

fn isRegexpCommand(name: []const u8) bool {
    return eql(name, "正規表現マッチ") or eql(name, "正規表現抽出") or eql(name, "正規表現置換") or eql(name, "正規表現区切");
}

fn eql(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}

test "正規表現の量指定・キャプチャ・置換・区切を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var source = try runtime.stringUtf8("AA,bb,CCC");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source);
    var pattern = try runtime.stringUtf8("/([a-z]+),?/gi");
    try roots.protect(&pattern);
    const extracted = (try callWithEffects(&runtime, "正規表現抽出", &.{ source, pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), extracted.value.array.len());
    var replacement_pattern = try runtime.stringUtf8("/([a-z]+)/gi");
    try roots.protect(&replacement_pattern);
    var replacement_text = try runtime.stringUtf8("<$1>");
    try roots.protect(&replacement_text);
    const replacement = (try call(&runtime, "正規表現置換", &.{ source, replacement_pattern, replacement_text })).?;
    const utf8 = try replacement.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("<AA>,<bb>,<CCC>", utf8);
    var split_pattern = try runtime.stringUtf8("/,/");
    try roots.protect(&split_pattern);
    const split = (try call(&runtime, "正規表現区切", &.{ source, split_pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), split.array.len());
}

test "正規表現のlegacy octal escapeは非Unicode classのcode unitになる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var unit_one = try runtime.stringUtf8("[\\1]");
    try roots.protect(&unit_one);
    var line_feed = try runtime.stringUtf8("[\\12]");
    try roots.protect(&line_feed);
    var letter_s = try runtime.stringUtf8("[\\123]");
    try roots.protect(&letter_s);
    var bell = try runtime.stringUtf8("\\07");
    try roots.protect(&bell);

    try std.testing.expect(try testRaw(std.testing.allocator, unit_one.string.units, &.{1}, false));
    try std.testing.expect(!try testRaw(std.testing.allocator, unit_one.string.units, &.{'1'}, false));
    try std.testing.expect(try testRaw(std.testing.allocator, line_feed.string.units, &.{10}, false));
    try std.testing.expect(try testRaw(std.testing.allocator, letter_s.string.units, &.{'S'}, false));
    try std.testing.expect(try testRaw(std.testing.allocator, bell.string.units, &.{7}, false));
}

test "正規表現構文エラーはV8互換の文言を設定する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const source = try runtime.stringUtf8("x");

    const raw_invalid = try runtime.stringUtf8("[");
    try std.testing.expectError(error.UnclosedCharacterClass, call(&runtime, "正規表現マッチ", &.{ source, raw_invalid }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[/g: Unterminated character class", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const delimited_invalid = try runtime.stringUtf8("/[/u");
    try std.testing.expectError(error.UnclosedCharacterClass, call(&runtime, "正規表現マッチ", &.{ source, delimited_invalid }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[/u: Unterminated character class", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_flags = try runtime.stringUtf8("/a/gg");
    try std.testing.expectError(error.DuplicateRegularExpressionFlag, call(&runtime, "正規表現マッチ", &.{ source, invalid_flags }));
    try std.testing.expectEqualStrings("Invalid flags supplied to RegExp constructor 'gg'", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const trailing_escape = try runtime.stringUtf8("\\");
    try std.testing.expectError(error.InvalidEscape, call(&runtime, "正規表現マッチ", &.{ source, trailing_escape }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\/g: \\ at end of pattern", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const unmatched_close = try runtime.stringUtf8(")");
    try std.testing.expectError(error.UnexpectedPatternToken, call(&runtime, "正規表現マッチ", &.{ source, unmatched_close }));
    try std.testing.expectEqualStrings("Invalid regular expression: /)/g: Unmatched ')'", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_unicode = try runtime.stringUtf8("/\\u{/u");
    try std.testing.expectError(error.InvalidUnicodeEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_unicode }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\u{/u: Invalid Unicode escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_control = try runtime.stringUtf8("/\\c1/u");
    try std.testing.expectError(error.InvalidUnicodeEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_control }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\c1/u: Invalid Unicode escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_backreference = try runtime.stringUtf8("/\\1/u");
    try std.testing.expectError(error.InvalidBackreference, call(&runtime, "正規表現マッチ", &.{ source, invalid_backreference }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\1/u: Invalid escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_named_reference = try runtime.stringUtf8("/(?<a>a)\\k<b>/u");
    try std.testing.expectError(error.InvalidNamedBackreference, call(&runtime, "正規表現マッチ", &.{ source, invalid_named_reference }));
    try std.testing.expectEqualStrings("Invalid regular expression: /(?<a>a)\\k<b>/u: Invalid named capture referenced", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const malformed_named_reference = try runtime.stringUtf8("/\\k/u");
    try std.testing.expectError(error.InvalidNamedReference, call(&runtime, "正規表現マッチ", &.{ source, malformed_named_reference }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\k/u: Invalid named reference", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_decimal_escape = try runtime.stringUtf8("/[\\1]/u");
    try std.testing.expectError(error.InvalidDecimalEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_decimal_escape }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\1]/u: Invalid decimal escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_zero_escape = try runtime.stringUtf8("/\\00/u");
    try std.testing.expectError(error.InvalidDecimalEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_zero_escape }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\00/u: Invalid decimal escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_class = try runtime.stringUtf8("/[\\d-a]/u");
    try std.testing.expectError(error.InvalidCharacterClass, call(&runtime, "正規表現マッチ", &.{ source, invalid_class }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\d-a]/u: Invalid character class", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_identity_escape = try runtime.stringUtf8("/\\q/u");
    try std.testing.expectError(error.InvalidIdentityEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_identity_escape }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\q/u: Invalid escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_capture_name = try runtime.stringUtf8("/(?<1>a)/");
    try std.testing.expectError(error.InvalidNamedCapture, call(&runtime, "正規表現マッチ", &.{ source, invalid_capture_name }));
    try std.testing.expectEqualStrings("Invalid regular expression: /(?<1>a)/: Invalid capture group name", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const duplicate_capture_name = try runtime.stringUtf8("/(?<a>a)(?<a>b)/");
    try std.testing.expectError(error.DuplicateNamedCapture, call(&runtime, "正規表現マッチ", &.{ source, duplicate_capture_name }));
    try std.testing.expectEqualStrings("Invalid regular expression: /(?<a>a)(?<a>b)/: Duplicate capture group name", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_hex_escape = try runtime.stringUtf8("/\\xZZ/u");
    try std.testing.expectError(error.InvalidHexEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_hex_escape }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\xZZ/u: Invalid escape", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const incomplete_quantifier = try runtime.stringUtf8("/a{,/u");
    try std.testing.expectError(error.IncompleteQuantifier, call(&runtime, "正規表現マッチ", &.{ source, incomplete_quantifier }));
    try std.testing.expectEqualStrings("Invalid regular expression: /a{,/u: Incomplete quantifier", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const lone_quantifier_brackets = try runtime.stringUtf8("/{/u");
    try std.testing.expectError(error.LoneQuantifierBrackets, call(&runtime, "正規表現マッチ", &.{ source, lone_quantifier_brackets }));
    try std.testing.expectEqualStrings("Invalid regular expression: /{/u: Lone quantifier brackets", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_set_character = try runtime.stringUtf8("/[a&&]/v");
    try std.testing.expectError(error.InvalidCharacterInClass, call(&runtime, "正規表現マッチ", &.{ source, invalid_set_character }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[a&&]/v: Invalid character in character class", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_set_operator = try runtime.stringUtf8("/[a&&&&b]/v");
    try std.testing.expectError(error.InvalidCharacterInClass, call(&runtime, "正規表現マッチ", &.{ source, invalid_set_operator }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[a&&&&b]/v: Invalid character in character class", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_class_property = try runtime.stringUtf8("/[\\p{Nope}]/u");
    try std.testing.expectError(error.InvalidUnicodePropertyInClass, call(&runtime, "正規表現マッチ", &.{ source, invalid_class_property }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\p{Nope}]/u: Invalid property name in character class", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_class_named_reference = try runtime.stringUtf8("/[\\k]/u");
    try std.testing.expectError(error.InvalidClassEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_class_named_reference }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\k]/u: Invalid escape", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_class_named_backreference = try runtime.stringUtf8("/[\\k<a>]/u");
    try std.testing.expectError(error.InvalidClassEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_class_named_backreference }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\k<a>]/u: Invalid escape", runtime.failureMessage().?);
}

test "名前付きキャプチャと非貪欲量指定を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const source = try runtime.stringUtf8("<a>1</a><a>2</a>");
    const result = (try callWithEffects(&runtime, "正規表現抽出", &.{ source, try runtime.stringUtf8("/<a>(?<body>.+?)<\\/a>/g") })).?;
    try std.testing.expectEqual(@as(usize, 2), result.value.array.len());
    try std.testing.expect(result.captures.? == .array);
    try std.testing.expectEqual(@as(usize, 2), result.captures.?.array.len());
}

test "Unicode名前付き後方参照と未マッチ群の空一致を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("foo-foo");
    try roots.protect(&source);
    var pattern = try runtime.stringUtf8("/(?<word>[a-z]+)-\\k<word>/u");
    try roots.protect(&pattern);
    const matched = (try call(&runtime, "正規表現マッチ", &.{ source, pattern })).?;
    try std.testing.expectEqualSlices(u16, source.string.units, matched.string.units);

    var optional_source = try runtime.stringUtf8("y");
    try roots.protect(&optional_source);
    var optional_pattern = try runtime.stringUtf8("/(?<optional>x)?\\k<optional>/u");
    try roots.protect(&optional_pattern);
    const empty = (try call(&runtime, "正規表現マッチ", &.{ optional_source, optional_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{}, empty.string.units);
}

test "Unicode文字クラスの補助平面コードポイント範囲を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source = try runtime.stringUtf8("😀A");
    try roots.protect(&source);
    var pattern = try runtime.stringUtf8("/[\\u{1F600}-\\u{1F64F}]/gu");
    try roots.protect(&pattern);
    const result = (try call(&runtime, "正規表現マッチ", &.{ source, pattern })).?;
    try std.testing.expectEqual(@as(usize, 1), result.array.len());
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, result.array.items.items[0].string.units);

    var raw_pattern = try runtime.stringUtf8("/[😀]/u");
    try roots.protect(&raw_pattern);
    const raw_result = (try call(&runtime, "正規表現マッチ", &.{ source, raw_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, raw_result.string.units);

    var escaped_pair_pattern = try runtime.stringUtf8("/[\\uD83D\\uDE00]/u");
    try roots.protect(&escaped_pair_pattern);
    const escaped_pair_result = (try call(&runtime, "正規表現マッチ", &.{ source, escaped_pair_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, escaped_pair_result.string.units);
}

test "正規表現の空幅量指定は下限と上限内の反復を保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const source = try runtime.stringUtf8("xa");

    const bounded = try runtime.stringUtf8("/(?:){2}a/");
    const bounded_result = (try call(&runtime, "正規表現マッチ", &.{ source, bounded })).?;
    try std.testing.expectEqualSlices(u16, &.{'a'}, bounded_result.string.units);

    const unbounded = try runtime.stringUtf8("/(){100,}/");
    const unbounded_result = (try callWithEffects(&runtime, "正規表現マッチ", &.{ source, unbounded })).?;
    try std.testing.expectEqualSlices(u16, &.{}, unbounded_result.value.string.units);
    const captures = unbounded_result.captures.?;
    try std.testing.expect(captures == .array);
    try std.testing.expectEqualSlices(u16, &.{}, captures.array.items.items[0].string.units);
}

test "正規表現の入れ子貪欲量指定は内側の選択を先に試す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const source = try runtime.stringUtf8("aaab");
    const pattern = try runtime.stringUtf8("/(a+)+b/");
    const result = (try callWithEffects(&runtime, "正規表現マッチ", &.{ source, pattern })).?;
    try std.testing.expectEqualSlices(u16, source.string.units, result.value.string.units);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'a', 'a' }, result.captures.?.array.items.items[0].string.units);
}

test "正規表現の反復captureは不参加branchを未定義へ戻す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("aba");
    try roots.protect(&source);
    var pattern = try runtime.stringUtf8("/(a(b)?)+/");
    try roots.protect(&pattern);
    const result = (try callWithEffects(&runtime, "正規表現抽出", &.{ source, pattern })).?;
    const rows = result.captures.?;
    try std.testing.expect(rows == .array);
    try std.testing.expectEqual(@as(usize, 1), rows.array.len());
    const captures = rows.array.items.items[0];
    try std.testing.expect(captures == .array);
    try std.testing.expectEqualSlices(u16, &.{'a'}, captures.array.items.items[0].string.units);
    try std.testing.expect(captures.array.items.items[1] == .undefined);

    var second_source = try runtime.stringUtf8("abac");
    try roots.protect(&second_source);
    var second_pattern = try runtime.stringUtf8("/(a(b)?)+c/");
    try roots.protect(&second_pattern);
    const second_result = (try callWithEffects(&runtime, "正規表現抽出", &.{ second_source, second_pattern })).?;
    const second_captures = second_result.captures.?.array.items.items[0].array;
    try std.testing.expectEqualSlices(u16, &.{'a'}, second_captures.items.items[0].string.units);
    try std.testing.expect(second_captures.items.items[1] == .undefined);
}

test "Unicode正規表現の探索はサロゲート対内部へ進まない" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringCodeUnits(&.{ 0xd83d, 0xde00 });
    try roots.protect(&source);
    var low_unicode_pattern = try runtime.stringUtf8("/\\uDE00/u");
    try roots.protect(&low_unicode_pattern);
    const low_unicode = (try call(&runtime, "正規表現マッチ", &.{ source, low_unicode_pattern })).?;
    try std.testing.expect(low_unicode == .null_value);

    var high_unicode_pattern = try runtime.stringUtf8("/\\uD83D/u");
    try roots.protect(&high_unicode_pattern);
    const high_unicode = (try call(&runtime, "正規表現マッチ", &.{ source, high_unicode_pattern })).?;
    try std.testing.expect(high_unicode == .null_value);

    var class_pattern = try runtime.stringUtf8("/[\\uDE00]/u");
    try roots.protect(&class_pattern);
    const class_unicode = (try call(&runtime, "正規表現マッチ", &.{ source, class_pattern })).?;
    try std.testing.expect(class_unicode == .null_value);

    var non_unicode_pattern = try runtime.stringUtf8("/\\uDE00/");
    try roots.protect(&non_unicode_pattern);
    const non_unicode = (try call(&runtime, "正規表現マッチ", &.{ source, non_unicode_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{0xde00}, non_unicode.string.units);
}

test "Unicode lookbehindはサロゲート対内部を開始位置にしない" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("😀x");
    try roots.protect(&source);
    var low_unicode_pattern = try runtime.stringUtf8("/(?<=\\uDE00)x/u");
    try roots.protect(&low_unicode_pattern);
    try std.testing.expect((try call(&runtime, "正規表現マッチ", &.{ source, low_unicode_pattern })).? == .null_value);

    var high_unicode_pattern = try runtime.stringUtf8("/(?<=\\uD83D)x/u");
    try roots.protect(&high_unicode_pattern);
    try std.testing.expect((try call(&runtime, "正規表現マッチ", &.{ source, high_unicode_pattern })).? == .null_value);

    var pair_pattern = try runtime.stringUtf8("/(?<=😀)x/u");
    try roots.protect(&pair_pattern);
    const pair = (try call(&runtime, "正規表現マッチ", &.{ source, pair_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'x'}, pair.string.units);

    var non_unicode_pattern = try runtime.stringUtf8("/(?<=\\uDE00)x/");
    try roots.protect(&non_unicode_pattern);
    const non_unicode = (try call(&runtime, "正規表現マッチ", &.{ source, non_unicode_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'x'}, non_unicode.string.units);
}

test "Unicode大小文字無視のword判定を拡張する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var kelvin = try runtime.stringUtf8("K");
    try roots.protect(&kelvin);
    var word_pattern = try runtime.stringUtf8("/^\\w$/iu");
    try roots.protect(&word_pattern);
    const word = (try call(&runtime, "正規表現マッチ", &.{ kelvin, word_pattern })).?;
    try std.testing.expectEqualSlices(u16, kelvin.string.units, word.string.units);

    var boundary_pattern = try runtime.stringUtf8("/^\\b.\\b$/iu");
    try roots.protect(&boundary_pattern);
    const boundary = (try call(&runtime, "正規表現マッチ", &.{ kelvin, boundary_pattern })).?;
    try std.testing.expectEqualSlices(u16, kelvin.string.units, boundary.string.units);

    var ascii_only_pattern = try runtime.stringUtf8("/^\\w$/u");
    try roots.protect(&ascii_only_pattern);
    try std.testing.expect((try call(&runtime, "正規表現マッチ", &.{ kelvin, ascii_only_pattern })).? == .null_value);

    var mixed = try runtime.stringUtf8("xKx");
    try roots.protect(&mixed);
    var non_boundary_pattern = try runtime.stringUtf8("/^x\\BK\\Bx$/iu");
    try roots.protect(&non_boundary_pattern);
    const non_boundary = (try call(&runtime, "正規表現マッチ", &.{ mixed, non_boundary_pattern })).?;
    try std.testing.expectEqualSlices(u16, mixed.string.units, non_boundary.string.units);

    var long_s = try runtime.stringUtf8("ſ");
    try roots.protect(&long_s);
    var unicode_sets_pattern = try runtime.stringUtf8("/^\\w$/iv");
    try roots.protect(&unicode_sets_pattern);
    const unicode_sets = (try call(&runtime, "正規表現マッチ", &.{ long_s, unicode_sets_pattern })).?;
    try std.testing.expectEqualSlices(u16, long_s.string.units, unicode_sets.string.units);
}

test "vフラグの文字集合intersectionとsubtractionを処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var ascii_word_source = try runtime.stringUtf8("aé1_");
    try roots.protect(&ascii_word_source);
    var ascii_word_pattern = try runtime.stringUtf8("/[\\w&&\\p{ASCII}]/gv");
    try roots.protect(&ascii_word_pattern);
    const ascii_word = (try call(&runtime, "正規表現マッチ", &.{ ascii_word_source, ascii_word_pattern })).?;
    try std.testing.expect(ascii_word == .array);
    try std.testing.expectEqual(@as(usize, 3), ascii_word.array.len());
    try std.testing.expectEqualSlices(u16, &.{'a'}, ascii_word.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'1'}, ascii_word.array.items.items[1].string.units);
    try std.testing.expectEqualSlices(u16, &.{'_'}, ascii_word.array.items.items[2].string.units);

    var consonant_source = try runtime.stringUtf8("AbEc");
    try roots.protect(&consonant_source);
    var consonant_pattern = try runtime.stringUtf8("/[[a-z]--[aeiou]]/giv");
    try roots.protect(&consonant_pattern);
    const consonants = (try call(&runtime, "正規表現マッチ", &.{ consonant_source, consonant_pattern })).?;
    try std.testing.expect(consonants == .array);
    try std.testing.expectEqual(@as(usize, 2), consonants.array.len());
    try std.testing.expectEqualSlices(u16, &.{'b'}, consonants.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'c'}, consonants.array.items.items[1].string.units);

    var non_ascii_source = try runtime.stringUtf8("Aé😀");
    try roots.protect(&non_ascii_source);
    var non_ascii_pattern = try runtime.stringUtf8("/[\\p{Any}--\\p{ASCII}]/gv");
    try roots.protect(&non_ascii_pattern);
    const non_ascii = (try call(&runtime, "正規表現マッチ", &.{ non_ascii_source, non_ascii_pattern })).?;
    try std.testing.expect(non_ascii == .array);
    try std.testing.expectEqual(@as(usize, 2), non_ascii.array.len());
    try std.testing.expectEqualSlices(u16, &.{0x00e9}, non_ascii.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, non_ascii.array.items.items[1].string.units);

    var letter_source = try runtime.stringUtf8("A1é");
    try roots.protect(&letter_source);
    var letter_pattern = try runtime.stringUtf8("/[\\p{ASCII}&&\\p{Letter}]/gv");
    try roots.protect(&letter_pattern);
    const letter = (try call(&runtime, "正規表現マッチ", &.{ letter_source, letter_pattern })).?;
    try std.testing.expect(letter == .array);
    try std.testing.expectEqual(@as(usize, 1), letter.array.len());
    try std.testing.expectEqualSlices(u16, &.{'A'}, letter.array.items.items[0].string.units);
}

test "アンカー・空クラス・先読み・後読みを処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var lines = try runtime.stringUtf8("x\ny");
    try roots.protect(&lines);
    var multiline = try runtime.stringUtf8("/^y/m");
    try roots.protect(&multiline);
    const anchored = (try call(&runtime, "正規表現マッチ", &.{ lines, multiline })).?;
    try std.testing.expect(anchored == .string);
    try std.testing.expectEqualSlices(u16, &.{'y'}, anchored.string.units);

    var all_units = try runtime.stringUtf8("/[^]/g");
    try roots.protect(&all_units);
    const any = (try call(&runtime, "正規表現マッチ", &.{ lines, all_units })).?;
    try std.testing.expectEqual(@as(usize, 3), any.array.len());
    var empty_class = try runtime.stringUtf8("/[]/");
    try roots.protect(&empty_class);
    try std.testing.expect((try call(&runtime, "正規表現マッチ", &.{ lines, empty_class })).? == .null_value);

    var source = try runtime.stringUtf8("abac abcb");
    try roots.protect(&source);
    const patterns = [_][]const u8{ "/a(?=b)/g", "/a(?!b)/g", "/(?<=a)b/g", "/(?<!a)b/g" };
    const expected_counts = [_]usize{ 2, 1, 2, 1 };
    for (patterns, expected_counts) |text, expected_count| {
        var pattern = try runtime.stringUtf8(text);
        try roots.protect(&pattern);
        const result = (try call(&runtime, "正規表現マッチ", &.{ source, pattern })).?;
        try std.testing.expectEqual(expected_count, result.array.len());
    }
}

test "二桁の量指定とゼロ幅区切をJavaScript互換で処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source = try runtime.stringUtf8("aaaaaaaaaa");
    try roots.protect(&source);
    var quantified = try runtime.stringUtf8("/a{10}/");
    try roots.protect(&quantified);
    const matched = (try call(&runtime, "正規表現マッチ", &.{ source, quantified })).?;
    try std.testing.expectEqual(@as(usize, 10), matched.string.units.len);

    var split_source = try runtime.stringUtf8("ab");
    try roots.protect(&split_source);
    var empty_pattern = try runtime.stringUtf8("(?:)");
    try roots.protect(&empty_pattern);
    const split = (try call(&runtime, "正規表現区切", &.{ split_source, empty_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), split.array.len());
    try std.testing.expectEqualSlices(u16, &.{'a'}, split.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'b'}, split.array.items.items[1].string.units);

    var consuming_pattern = try runtime.stringUtf8("/a*/");
    try roots.protect(&consuming_pattern);
    const consuming_split = (try call(&runtime, "正規表現区切", &.{ split_source, consuming_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), consuming_split.array.len());
    try std.testing.expectEqual(@as(usize, 0), consuming_split.array.items.items[0].string.units.len);
    try std.testing.expectEqualSlices(u16, &.{'b'}, consuming_split.array.items.items[1].string.units);
}

test "大文字小文字を区別しない照合は非ASCII文字にも適用する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source = try runtime.stringUtf8("ÉCOLE");
    try roots.protect(&source);
    var pattern = try runtime.stringUtf8("/école/i");
    try roots.protect(&pattern);
    const matched = (try call(&runtime, "正規表現マッチ", &.{ source, pattern })).?;
    try std.testing.expect(matched == .string);
}

test "Unicode・sticky・indicesフラグはUTF-16共有エンジンで処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringCodeUnits(&.{ 0xd83d, 0xde00, 'x' });
    try roots.protect(&source);
    var unicode_pattern = try runtime.stringUtf8("/./gu");
    try roots.protect(&unicode_pattern);
    const unicode_matches = (try call(&runtime, "正規表現マッチ", &.{ source, unicode_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), unicode_matches.array.len());
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, unicode_matches.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'x'}, unicode_matches.array.items.items[1].string.units);

    var split_pattern = try runtime.stringUtf8("/./u");
    try roots.protect(&split_pattern);
    const split = (try call(&runtime, "正規表現区切", &.{ source, split_pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), split.array.len());
    for (split.array.items.items) |item| try std.testing.expectEqual(@as(usize, 0), item.string.units.len);

    var sticky_source = try runtime.stringUtf8("ba");
    try roots.protect(&sticky_source);
    var sticky_pattern = try runtime.stringUtf8("/a/y");
    try roots.protect(&sticky_pattern);
    try std.testing.expect((try call(&runtime, "正規表現マッチ", &.{ sticky_source, sticky_pattern })).? == .null_value);

    var sticky_global_source = try runtime.stringUtf8("aaab");
    try roots.protect(&sticky_global_source);
    var sticky_global_pattern = try runtime.stringUtf8("/a/gy");
    try roots.protect(&sticky_global_pattern);
    const sticky_global = (try call(&runtime, "正規表現マッチ", &.{ sticky_global_source, sticky_global_pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), sticky_global.array.len());

    var escaped_pattern = try runtime.stringUtf8("/\\u{1F600}/u");
    try roots.protect(&escaped_pattern);
    const escaped = (try call(&runtime, "正規表現マッチ", &.{ source, escaped_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, escaped.string.units);

    var fold_source = try runtime.stringUtf8("𐐨ſK");
    try roots.protect(&fold_source);
    var fold_pattern = try runtime.stringUtf8("/\\u{10400}sk/iu");
    try roots.protect(&fold_pattern);
    const folded = (try call(&runtime, "正規表現マッチ", &.{ fold_source, fold_pattern })).?;
    try std.testing.expectEqualSlices(u16, fold_source.string.units, folded.string.units);

    var fold_property_source = try runtime.stringUtf8("AK");
    try roots.protect(&fold_property_source);
    var fold_property_pattern = try runtime.stringUtf8("/\\p{Lowercase_Letter}/giu");
    try roots.protect(&fold_property_pattern);
    const folded_properties = (try call(&runtime, "正規表現マッチ", &.{ fold_property_source, fold_property_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), folded_properties.array.len());
    try std.testing.expectEqualSlices(u16, &.{'A'}, folded_properties.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{0x212a}, folded_properties.array.items.items[1].string.units);

    var indices_pattern = try runtime.stringUtf8("/(x)/d");
    try roots.protect(&indices_pattern);
    const indices = (try call(&runtime, "正規表現マッチ", &.{ source, indices_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'x'}, indices.string.units);

    var control_source = try runtime.stringCodeUnits(&.{1});
    try roots.protect(&control_source);
    var control_pattern = try runtime.stringUtf8("/\\cA/u");
    try roots.protect(&control_pattern);
    const control = (try call(&runtime, "正規表現マッチ", &.{ control_source, control_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{1}, control.string.units);

    var lone_surrogate_source = try runtime.stringCodeUnits(&.{0xd800});
    try roots.protect(&lone_surrogate_source);
    var lone_surrogate_pattern = try runtime.stringUtf8("/\\u{D800}/u");
    try roots.protect(&lone_surrogate_pattern);
    const lone_surrogate = (try call(&runtime, "正規表現マッチ", &.{ lone_surrogate_source, lone_surrogate_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{0xd800}, lone_surrogate.string.units);
}

test "Unicode setsのvフラグは基本照合と未対応構文を扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("😀A1あ");
    try roots.protect(&source);
    var any_pattern = try runtime.stringUtf8("/./vg");
    try roots.protect(&any_pattern);
    const any = (try call(&runtime, "正規表現マッチ", &.{ source, any_pattern })).?;
    try std.testing.expectEqual(@as(usize, 4), any.array.len());
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, any.array.items.items[0].string.units);

    var property_pattern = try runtime.stringUtf8("/\\p{Letter}/vg");
    try roots.protect(&property_pattern);
    const letters = (try call(&runtime, "正規表現マッチ", &.{ source, property_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), letters.array.len());
    try std.testing.expectEqualSlices(u16, &.{'A'}, letters.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'あ'}, letters.array.items.items[1].string.units);

    var invalid_flags = try runtime.stringUtf8("/a/uv");
    try roots.protect(&invalid_flags);
    try std.testing.expectError(error.UnsupportedRegularExpressionFlag, call(&runtime, "正規表現マッチ", &.{ source, invalid_flags }));
    try std.testing.expectEqualStrings("Invalid flags supplied to RegExp constructor 'uv'", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    var unsupported_set = try runtime.stringUtf8("/[a-z--[aeiou]]/v");
    try roots.protect(&unsupported_set);
    try std.testing.expectError(error.UnsupportedUnicodeSetOperation, call(&runtime, "正規表現マッチ", &.{ source, unsupported_set }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[a-z--[aeiou]]/v: Invalid set operation in character class", runtime.failureMessage().?);
}

test "Unicode property escapeは生成済み静的範囲を使う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("A1あ😀 ");
    try roots.protect(&source);
    var letter_pattern = try runtime.stringUtf8("/\\p{Letter}/gu");
    try roots.protect(&letter_pattern);
    const letters = (try call(&runtime, "正規表現マッチ", &.{ source, letter_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), letters.array.len());
    try std.testing.expectEqualSlices(u16, &.{'A'}, letters.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'あ'}, letters.array.items.items[1].string.units);

    var non_ascii_pattern = try runtime.stringUtf8("/\\P{ASCII}/gu");
    try roots.protect(&non_ascii_pattern);
    const non_ascii = (try call(&runtime, "正規表現マッチ", &.{ source, non_ascii_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), non_ascii.array.len());
    try std.testing.expectEqualSlices(u16, &.{'あ'}, non_ascii.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, non_ascii.array.items.items[1].string.units);

    var number_source = try runtime.stringUtf8("1");
    try roots.protect(&number_source);
    var number_pattern = try runtime.stringUtf8("/\\p{Decimal_Number}/u");
    try roots.protect(&number_pattern);
    const number = (try call(&runtime, "正規表現マッチ", &.{ number_source, number_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'1'}, number.string.units);

    var hiragana_source = try runtime.stringUtf8("あ");
    try roots.protect(&hiragana_source);
    var hiragana_pattern = try runtime.stringUtf8("/\\p{Script=Hiragana}/u");
    try roots.protect(&hiragana_pattern);
    const hiragana = (try call(&runtime, "正規表現マッチ", &.{ hiragana_source, hiragana_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'あ'}, hiragana.string.units);

    var class_source = try runtime.stringUtf8("A1");
    try roots.protect(&class_source);
    var class_pattern = try runtime.stringUtf8("/[\\p{Letter}\\p{Decimal_Number}]/gu");
    try roots.protect(&class_pattern);
    const class_matches = (try call(&runtime, "正規表現マッチ", &.{ class_source, class_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), class_matches.array.len());

    var alias_source = try runtime.stringUtf8("F🏻$");
    try roots.protect(&alias_source);
    var alias_pattern = try runtime.stringUtf8("/[\\p{AHex}\\p{Emoji_Modifier}\\p{gc=Sc}]/gu");
    try roots.protect(&alias_pattern);
    const aliases = (try call(&runtime, "正規表現マッチ", &.{ alias_source, alias_pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), aliases.array.len());

    var xid_pattern = try runtime.stringUtf8("/\\p{XID_Start}/u");
    try roots.protect(&xid_pattern);
    const xid = (try call(&runtime, "正規表現マッチ", &.{ hiragana_source, xid_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'あ'}, xid.string.units);

    var script_extensions_source = try runtime.stringUtf8("ー゠・々あア漢");
    try roots.protect(&script_extensions_source);
    var script_extensions_pattern = try runtime.stringUtf8("/\\p{scx=Hira}/gu");
    try roots.protect(&script_extensions_pattern);
    const hiragana_extensions = (try call(&runtime, "正規表現マッチ", &.{ script_extensions_source, script_extensions_pattern })).?;
    try std.testing.expectEqual(@as(usize, 4), hiragana_extensions.array.len());
    try std.testing.expectEqualSlices(u16, &.{'ー'}, hiragana_extensions.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'゠'}, hiragana_extensions.array.items.items[1].string.units);
    try std.testing.expectEqualSlices(u16, &.{'・'}, hiragana_extensions.array.items.items[2].string.units);
    try std.testing.expectEqualSlices(u16, &.{'あ'}, hiragana_extensions.array.items.items[3].string.units);

    var han_extensions_pattern = try runtime.stringUtf8("/\\p{Script_Extensions=Han}/gu");
    try roots.protect(&han_extensions_pattern);
    const han_extensions = (try call(&runtime, "正規表現マッチ", &.{ script_extensions_source, han_extensions_pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), han_extensions.array.len());
    try std.testing.expectEqualSlices(u16, &.{'・'}, han_extensions.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'々'}, han_extensions.array.items.items[1].string.units);
    try std.testing.expectEqualSlices(u16, &.{'漢'}, han_extensions.array.items.items[2].string.units);

    var adlam_source = try runtime.stringUtf8("𞤀A");
    try roots.protect(&adlam_source);
    var adlam_pattern = try runtime.stringUtf8("/\\p{sc=Adlm}/gu");
    try roots.protect(&adlam_pattern);
    const adlam = (try call(&runtime, "正規表現マッチ", &.{ adlam_source, adlam_pattern })).?;
    try std.testing.expectEqual(@as(usize, 1), adlam.array.len());
    try std.testing.expectEqualSlices(u16, &.{ 0xd83a, 0xdd00 }, adlam.array.items.items[0].string.units);

    var invalid_pattern = try runtime.stringUtf8("/\\p{Nope}/u");
    try roots.protect(&invalid_pattern);
    try std.testing.expectError(error.InvalidUnicodeProperty, call(&runtime, "正規表現マッチ", &.{ source, invalid_pattern }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\p{Nope}/u: Invalid property name", runtime.failureMessage().?);
}
