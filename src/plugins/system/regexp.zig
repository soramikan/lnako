const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const common = @import("common.zig");
const unicode_case = @import("unicode_case");

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
    sticky: bool = false,
    indices: bool = false,
};
pub const Span = struct { start: usize = 0, end: usize = 0, matched: bool = false };
const Candidate = struct { position: usize, captures: [max_captures]Span };
pub const Match = struct { span: Span, captures: [max_captures]Span };

const ClassItem = union(enum) {
    literal: u16,
    code_point: u21,
    range: struct { first: u16, last: u16 },
    digit,
    not_digit,
    word,
    not_word,
    space,
    not_space,
};
const CharacterClass = struct { negated: bool, items: []const ClassItem };
const Group = struct { expression: *Expression, capture: ?usize, name: ?[]const u16 };
const Assertion = struct { expression: *Expression, positive: bool, behind: bool };
const Atom = union(enum) {
    literal: u16,
    code_point: u21,
    dot,
    class: CharacterClass,
    group: Group,
    assertion: Assertion,
    start_anchor,
    end_anchor,
    word_boundary: bool,
    backreference: usize,
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
    index: usize = 0,
    capture_count: usize = 0,
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
            '*', '+', '?', '{' => error.QuantifierWithoutAtom,
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
        var capture_index: ?usize = null;
        if (capture) {
            if (self.capture_count >= max_captures) return error.TooManyCaptures;
            capture_index = self.capture_count;
            self.capture_names[self.capture_count] = name;
            self.capture_count += 1;
        }
        const expression = try self.parseExpression();
        if (!consume(self, ')')) return error.UnclosedGroup;
        if (assertion) |details| return .{ .assertion = .{ .expression = expression, .positive = details.positive, .behind = details.behind } };
        return .{ .group = .{ .expression = expression, .capture = capture_index, .name = name } };
    }

    fn parseClass(self: *Parser) !CharacterClass {
        const negated = consume(self, '^');
        var items: std.ArrayList(ClassItem) = .empty;
        while (self.index < self.source.len) {
            if (self.source[self.index] == ']') {
                self.index += 1;
                return .{ .negated = negated, .items = try items.toOwnedSlice(self.allocator) };
            }
            const first = try self.parseClassItem();
            if (first == .literal and self.index + 1 < self.source.len and self.source[self.index] == '-' and self.source[self.index + 1] != ']') {
                self.index += 1;
                const last = try self.parseClassItem();
                if (last != .literal or last.literal < first.literal) return error.InvalidCharacterRange;
                try items.append(self.allocator, .{ .range = .{ .first = first.literal, .last = last.literal } });
            } else try items.append(self.allocator, first);
        }
        return error.UnclosedCharacterClass;
    }

    fn parseClassItem(self: *Parser) !ClassItem {
        if (self.index >= self.source.len) return error.UnclosedCharacterClass;
        const unit = self.source[self.index];
        self.index += 1;
        if (unit != '\\') return .{ .literal = unit };
        const atom = try self.parseEscape(true);
        return switch (atom) {
            .literal => |literal| .{ .literal = literal },
            .code_point => |code_point| .{ .code_point = code_point },
            .class => |class| if (class.items.len == 1) class.items[0] else error.InvalidClassEscape,
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
            '0' => .{ .literal = 0 },
            'x' => .{ .literal = try self.parseHex(2) },
            'u' => if (self.index < self.source.len and self.source[self.index] == '{')
                .{ .code_point = try self.parseCodePointEscape() }
            else
                .{ .literal = try self.parseHex(4) },
            '1'...'9' => if (in_class) .{ .literal = escaped } else .{ .backreference = escaped - '1' },
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
        if (value >= 0xd800 and value <= 0xdfff) return error.InvalidUnicodeEscape;
        return @intCast(value);
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
                    return;
                };
                var maximum: ?usize = minimum;
                if (consume(self, ',')) maximum = self.parseDecimal();
                if (!consume(self, '}')) {
                    self.index = saved;
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
        return .{ .class = .{ .negated = false, .items = items } };
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
        error.InvalidCharacterRange => "Range out of order in character class",
        error.InvalidQuantifierRange => "numbers out of order in {} quantifier",
        error.InvalidNamedCapture => "Invalid capture group name",
        error.DuplicateNamedCapture => "Duplicate capture group name",
        error.UnsupportedGroupAssertion => "Invalid group",
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
                else => unreachable,
            }
        }
    }
    const owned_pattern = try arena.allocator().dupe(u16, pattern);
    var parser = Parser{ .allocator = arena.allocator(), .source = owned_pattern, .unicode = flags.unicode };
    const expression = try parser.parseExpression();
    if (parser.index != owned_pattern.len) return error.UnexpectedPatternToken;
    return .{ .arena = arena, .expression = expression, .flags = flags, .capture_count = parser.capture_count, .capture_names = parser.capture_names };
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
    while (start <= last_start) : (start += 1) {
        const initial = Candidate{ .position = start, .captures = [_]Span{.{}} ** max_captures };
        const candidates = try matchExpression(arena.allocator(), source, compiled.expression, initial, compiled.flags);
        if (candidates.len > 0) return .{ .span = .{ .start = start, .end = candidates[0].position, .matched = true }, .captures = candidates[0].captures };
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

fn expandPiece(allocator: std.mem.Allocator, source: []const u16, piece: Piece, initial: Candidate, flags: Flags) anyerror![]Candidate {
    var levels: std.ArrayList([]Candidate) = .empty;
    const zero = try allocator.alloc(Candidate, 1);
    zero[0] = initial;
    try levels.append(allocator, zero);
    const limit = piece.maximum orelse source.len + 1;
    var repetition: usize = 0;
    while (repetition < limit) : (repetition += 1) {
        const frontier = levels.items[levels.items.len - 1];
        var next: std.ArrayList(Candidate) = .empty;
        for (frontier) |candidate| {
            const atom_matches = try matchAtom(allocator, source, piece.atom, candidate, flags);
            for (atom_matches) |atom_match| {
                if (atom_match.position == candidate.position and !(piece.minimum == 1 and piece.maximum == 1)) continue;
                try next.append(allocator, atom_match);
            }
        }
        if (next.items.len == 0) break;
        try levels.append(allocator, try next.toOwnedSlice(allocator));
    }
    var output: std.ArrayList(Candidate) = .empty;
    if (piece.lazy) {
        var level = piece.minimum;
        while (level < levels.items.len) : (level += 1) try output.appendSlice(allocator, levels.items[level]);
    } else {
        var level = levels.items.len;
        while (level > piece.minimum) {
            level -= 1;
            try output.appendSlice(allocator, levels.items[level]);
        }
    }
    return output.toOwnedSlice(allocator);
}

fn matchAtom(allocator: std.mem.Allocator, source: []const u16, atom: Atom, initial: Candidate, flags: Flags) anyerror![]Candidate {
    var output: std.ArrayList(Candidate) = .empty;
    switch (atom) {
        .literal => |literal| if (initial.position < source.len and unitsEqual(source[initial.position], literal, flags.ignore_case)) {
            var candidate = initial;
            candidate.position += 1;
            try output.append(allocator, candidate);
        },
        .code_point => |code_point| if (codePointAt(source, initial.position)) |actual| if (actual.value == code_point) {
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
        .start_anchor => if (initial.position == 0 or (flags.multiline and initial.position > 0 and isLineTerminator(source[initial.position - 1]))) try output.append(allocator, initial),
        .end_anchor => if (initial.position == source.len or (flags.multiline and initial.position < source.len and isLineTerminator(source[initial.position]))) try output.append(allocator, initial),
        .word_boundary => |expected| {
            const left_word = initial.position > 0 and isWord(source[initial.position - 1]);
            const right_word = initial.position < source.len and isWord(source[initial.position]);
            if ((left_word != right_word) == expected) try output.append(allocator, initial);
        },
        .backreference => |capture_index| {
            if (capture_index >= max_captures or !initial.captures[capture_index].matched) return output.toOwnedSlice(allocator);
            const span = initial.captures[capture_index];
            const length = span.end - span.start;
            if (initial.position + length <= source.len and slicesEqual(source[span.start..span.end], source[initial.position .. initial.position + length], flags.ignore_case)) {
                var candidate = initial;
                candidate.position += length;
                try output.append(allocator, candidate);
            }
        },
        .group => |group| {
            const matches = try matchExpression(allocator, source, group.expression, initial, flags);
            for (matches) |match| {
                var candidate = match;
                if (group.capture) |capture_index| candidate.captures[capture_index] = .{ .start = initial.position, .end = match.position, .matched = true };
                try output.append(allocator, candidate);
            }
        },
        .assertion => |assertion| {
            if (!assertion.behind) {
                const assertion_matches = try matchExpression(allocator, source, assertion.expression, initial, flags);
                if (assertion.positive) {
                    for (assertion_matches) |match| {
                        var accepted = match;
                        accepted.position = initial.position;
                        try output.append(allocator, accepted);
                    }
                } else if (assertion_matches.len == 0) try output.append(allocator, initial);
            } else {
                var matched = false;
                var start: usize = 0;
                while (start <= initial.position) : (start += 1) {
                    const behind_initial = Candidate{ .position = start, .captures = initial.captures };
                    const candidates = try matchExpression(allocator, source, assertion.expression, behind_initial, flags);
                    for (candidates) |candidate| if (candidate.position == initial.position) {
                        matched = true;
                        if (assertion.positive) {
                            var accepted = candidate;
                            accepted.position = initial.position;
                            try output.append(allocator, accepted);
                        }
                    };
                }
                if (!assertion.positive and !matched) try output.append(allocator, initial);
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

fn classMatches(class: CharacterClass, source: []const u16, position: usize, flags: Flags) bool {
    const unit = source[position];
    const code_point = codePointAt(source, position).?;
    var matched = false;
    for (class.items) |item| {
        matched = switch (item) {
            .literal => |literal| code_point.value <= std.math.maxInt(u16) and unitsEqual(unit, literal, flags.ignore_case),
            .code_point => |literal| if (flags.unicode) code_point.value == literal else literal <= std.math.maxInt(u16) and unit == literal,
            .range => |range| blk: {
                const folded = foldAscii(unit, flags.ignore_case);
                break :blk folded >= foldAscii(range.first, flags.ignore_case) and folded <= foldAscii(range.last, flags.ignore_case);
            },
            .digit => isDigit(unit),
            .not_digit => !isDigit(unit),
            .word => isWord(unit),
            .not_word => !isWord(unit),
            .space => isWhitespace(unit),
            .not_space => !isWhitespace(unit),
        };
        if (matched) break;
    }
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

fn slicesEqual(left: []const u16, right: []const u16, ignore_case: bool) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!unitsEqual(a, b, ignore_case)) return false;
    return true;
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
    return isDigit(unit) or (unit >= 'A' and unit <= 'Z') or (unit >= 'a' and unit <= 'z') or unit == '_';
}

fn isWhitespace(unit: u16) bool {
    return switch (unit) {
        0x0009...0x000d, 0x0020, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
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

    var indices_pattern = try runtime.stringUtf8("/(x)/d");
    try roots.protect(&indices_pattern);
    const indices = (try call(&runtime, "正規表現マッチ", &.{ source, indices_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'x'}, indices.string.units);
}
