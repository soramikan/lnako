const std = @import("std");
const source_mod = @import("source.zig");
const josi_mod = @import("josi.zig");
const token_mod = @import("token.zig");

pub const Kind = token_mod.Kind;
pub const Mode = token_mod.Mode;
pub const Token = token_mod.Token;

pub const TokenStream = struct {
    arena: std.heap.ArenaAllocator,
    source: source_mod.NormalizedSource,
    tokens: []Token,
    mode: Mode,

    pub fn deinit(self: *TokenStream) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Error = error{ InvalidUtf8, UnexpectedCharacter, UnterminatedString, InvalidNumber } || std.mem.Allocator.Error;

pub fn tokenize(backing_allocator: std.mem.Allocator, input: []const u8) Error!TokenStream {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const normalized = source_mod.normalize(allocator, input) catch |err| switch (err) {
        error.InvalidUtf8 => return error.InvalidUtf8,
        error.OutOfMemory => return error.OutOfMemory,
    };

    var lexer = Lexer{
        .allocator = allocator,
        .source = normalized,
        .tokens = .empty,
    };
    const tokens = try lexer.run();
    return .{ .arena = arena, .source = normalized, .tokens = tokens, .mode = detectMode(input) };
}

pub fn detectMode(input: []const u8) Mode {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        if (count >= 100) break;
        const trimmed = trimModeIndent(line);
        if (std.mem.startsWith(u8, trimmed, "!DNCL2モード") or std.mem.startsWith(u8, trimmed, "💡DNCL2モード") or
            std.mem.startsWith(u8, trimmed, "!DNCL2") or std.mem.startsWith(u8, trimmed, "💡DNCL2")) return .dncl2;
        if (std.mem.startsWith(u8, trimmed, "!DNCLモード") or std.mem.startsWith(u8, trimmed, "💡DNCLモード")) return .dncl;
        if (std.mem.startsWith(u8, trimmed, "!インデント構文") or std.mem.startsWith(u8, trimmed, "💡インデント構文") or
            std.mem.startsWith(u8, trimmed, "!ここまでだるい") or std.mem.startsWith(u8, trimmed, "💡ここまでだるい")) return .indent;
    }
    return .standard;
}

fn trimModeIndent(line: []const u8) []const u8 {
    var offset: usize = 0;
    while (offset < line.len) {
        if (line[offset] == ' ' or line[offset] == '\t' or line[offset] == '\r') {
            offset += 1;
        } else if (std.mem.startsWith(u8, line[offset..], "　") or std.mem.startsWith(u8, line[offset..], "・")) {
            offset += "　".len;
        } else break;
    }
    return line[offset..];
}

const Lexer = struct {
    allocator: std.mem.Allocator,
    source: source_mod.NormalizedSource,
    tokens: std.ArrayList(Token),
    offset: usize = 0,
    line: usize = 0,
    column: usize = 1,
    indent: usize = 0,
    at_line_start: bool = true,

    fn run(self: *Lexer) Error![]Token {
        while (self.offset < self.source.text.len) {
            if (self.at_line_start) try self.readIndent();
            if (self.offset >= self.source.text.len) break;
            if (try self.readTrivia()) continue;
            try self.readToken();
        }
        try self.emit(.eof, self.offset, self.offset, "", "", "");
        return self.tokens.toOwnedSlice(self.allocator);
    }

    fn readIndent(self: *Lexer) Error!void {
        self.indent = 0;
        while (self.offset < self.source.text.len) {
            const decoded = source_mod.decodeAt(self.source.text, self.offset) catch return error.InvalidUtf8;
            const width = indentationWidth(decoded.codepoint);
            if (width == 0) break;
            self.offset += decoded.len;
            self.column += 1;
            self.indent += width;
        }
        self.at_line_start = false;
    }

    fn readTrivia(self: *Lexer) Error!bool {
        const rest = self.source.text[self.offset..];
        if (rest[0] == ' ' or rest[0] == '\t' or std.mem.startsWith(u8, rest, "　") or
            std.mem.startsWith(u8, rest, "・") or std.mem.startsWith(u8, rest, "｜") or
            std.mem.startsWith(u8, rest, "└") or std.mem.startsWith(u8, rest, "⎿"))
        {
            try self.advanceCodepoint();
            return true;
        }
        if (rest[0] == '#' or std.mem.startsWith(u8, rest, "//")) {
            while (self.offset < self.source.text.len and self.source.text[self.offset] != '\n') try self.advanceCodepoint();
            return true;
        }
        if (std.mem.startsWith(u8, rest, "/*")) {
            try self.advanceBytes(2);
            while (self.offset < self.source.text.len and !std.mem.startsWith(u8, self.source.text[self.offset..], "*/")) {
                try self.advanceCodepoint();
            }
            if (self.offset < self.source.text.len) try self.advanceBytes(2);
            return true;
        }
        return false;
    }

    fn readToken(self: *Lexer) Error!void {
        const start = self.offset;
        const rest = self.source.text[start..];

        if (rest[0] == '\n' or rest[0] == ';') {
            const line = self.line;
            const column = self.column;
            if (rest[0] == '\n') {
                self.offset += 1;
                self.line += 1;
                self.column = 1;
                self.at_line_start = true;
            } else {
                self.offset += 1;
                self.column += 1;
            }
            try self.emitAt(.eol, start, self.offset, "", "", "", line, column);
            return;
        }
        if (rest[0] == ',') return self.simple(.comma, 1);
        if (std.mem.startsWith(u8, rest, "●テスト:")) return self.simple(.def_test, "●テスト:".len);
        if (std.mem.startsWith(u8, rest, "●")) return self.simple(.def_func, "●".len);
        if (rest[0] == '_') {
            var continuation_end: usize = 1;
            while (continuation_end < rest.len and (rest[continuation_end] == ' ' or rest[continuation_end] == '\t')) continuation_end += 1;
            if (continuation_end < rest.len and rest[continuation_end] == '\n') {
                try self.advanceBytes(continuation_end + 1);
                return;
            }
        }
        if (std.mem.startsWith(u8, rest, "‰")) {
            try self.advanceBytes("‰".len);
            if (self.line > 0) self.line -= 1;
            return;
        }
        if (std.mem.startsWith(u8, rest, "ここから")) return self.simple(.keyword_here_from, "ここから".len);
        if (std.mem.startsWith(u8, rest, "ここまで") or std.mem.startsWith(u8, rest, "💧")) {
            const len = if (std.mem.startsWith(u8, rest, "ここまで")) "ここまで".len else "💧".len;
            return self.simple(.keyword_here_end, len);
        }
        if (std.mem.startsWith(u8, rest, ";;;")) return self.simple(.keyword_here_end, 3);
        if (std.mem.startsWith(u8, rest, "もしも")) return self.simple(.keyword_if, "もしも".len);
        if (std.mem.startsWith(u8, rest, "もし")) return self.simple(.keyword_if, "もし".len);
        if (std.mem.startsWith(u8, rest, "違えば")) return self.simple(.keyword_else, "違えば".len);
        if (std.mem.startsWith(u8, rest, "違え")) return self.simple(.keyword_else, "違え".len);
        if (std.mem.startsWith(u8, rest, "違")) return self.simple(.keyword_else, "違".len);
        if (rest[0] == '.' and rest.len > 1 and rest[1] >= '0' and rest[1] <= '9') return self.readNumber();
        if (std.mem.startsWith(u8, rest, "${")) return self.readExtendedWord("${", "}");
        if (std.mem.startsWith(u8, rest, "《")) return self.readExtendedWord("《", "》");
        if (std.mem.startsWith(u8, rest, "{関数}")) {
            var length = "{関数}".len;
            if (rest.len > length and rest[length] == ',') length += 1;
            return self.simple(.function_ref, length);
        }

        const operators = [_]struct { text: []const u8, kind: Kind }{
            .{ .text = ">>>", .kind = .shift_right_unsigned }, .{ .text = "===", .kind = .strict_equal },
            .{ .text = "!==", .kind = .strict_not_equal },     .{ .text = "<--", .kind = .assign_arrow },
            .{ .text = "...", .kind = .range },                .{ .text = "..", .kind = .range },
            .{ .text = ">>", .kind = .shift_right },           .{ .text = "<<", .kind = .shift_left },
            .{ .text = ">=", .kind = .greater_equal },         .{ .text = "=>", .kind = .greater_equal },
            .{ .text = "<=", .kind = .less_equal },            .{ .text = "=<", .kind = .less_equal },
            .{ .text = "!=", .kind = .not_equal },             .{ .text = "<>", .kind = .not_equal },
            .{ .text = "==", .kind = .equal },                 .{ .text = "&&", .kind = .logical_and },
            .{ .text = "||", .kind = .logical_or },            .{ .text = "**", .kind = .power },
            .{ .text = "??", .kind = .question_display },
            .{ .text = "≧", .kind = .greater_equal },
            .{ .text = "≦", .kind = .less_equal },
            .{ .text = "≠", .kind = .not_equal },
            .{ .text = "←", .kind = .assign_arrow },
            .{ .text = "…", .kind = .range },
            .{ .text = "××", .kind = .power },
            .{ .text = "÷÷", .kind = .integer_divide },
            .{ .text = "×", .kind = .multiply },
        };
        for (operators) |operator| {
            if (std.mem.startsWith(u8, rest, operator.text)) return self.simpleWithJosi(operator.kind, operator.text.len, operator.kind == .right_paren);
        }

        if (rest[0] == '!' or std.mem.startsWith(u8, rest, "💡")) {
            const length: usize = if (rest[0] == '!') 1 else "💡".len;
            const after = rest[length..];
            if (std.mem.startsWith(u8, after, "インデント構文") or std.mem.startsWith(u8, after, "ここまでだるい") or
                std.mem.startsWith(u8, after, "DNCLモード") or std.mem.startsWith(u8, after, "DNCL2モード") or std.mem.startsWith(u8, after, "DNCL2"))
            {
                while (self.offset < self.source.text.len and self.source.text[self.offset] != '\n') try self.advanceCodepoint();
                return;
            }
            return self.simple(.not, length);
        }

        const singles = [_]struct { byte: u8, kind: Kind, read_josi: bool }{
            .{ .byte = '=', .kind = .equal, .read_josi = false },        .{ .byte = '>', .kind = .greater, .read_josi = false },
            .{ .byte = '<', .kind = .less, .read_josi = false },         .{ .byte = '+', .kind = .plus, .read_josi = false },
            .{ .byte = '-', .kind = .minus, .read_josi = false },        .{ .byte = '*', .kind = .multiply, .read_josi = false },
            .{ .byte = '/', .kind = .divide, .read_josi = false },       .{ .byte = '%', .kind = .modulo, .read_josi = false },
            .{ .byte = '^', .kind = .bit_xor, .read_josi = false },      .{ .byte = '&', .kind = .bit_and, .read_josi = false },
            .{ .byte = '@', .kind = .at, .read_josi = false },           .{ .byte = '$', .kind = .property, .read_josi = false },
            .{ .byte = '.', .kind = .property, .read_josi = false },     .{ .byte = '(', .kind = .left_paren, .read_josi = false },
            .{ .byte = ')', .kind = .right_paren, .read_josi = true },   .{ .byte = '[', .kind = .left_bracket, .read_josi = false },
            .{ .byte = ']', .kind = .right_bracket, .read_josi = true }, .{ .byte = '{', .kind = .left_brace, .read_josi = false },
            .{ .byte = '}', .kind = .right_brace, .read_josi = true },   .{ .byte = '|', .kind = .pipe, .read_josi = false },
            .{ .byte = ':', .kind = .colon, .read_josi = false },
        };
        for (singles) |single| {
            if (rest[0] == single.byte) return self.simpleWithJosi(single.kind, 1, single.read_josi);
        }
        if (std.mem.startsWith(u8, rest, "÷")) return self.simple(.divide, "÷".len);
        if (std.mem.startsWith(u8, rest, "かつ")) return self.simple(.logical_and, "かつ".len);
        if (std.mem.startsWith(u8, rest, "または")) return self.simple(.logical_or, "または".len);
        if (std.mem.startsWith(u8, rest, "或いは")) return self.simple(.logical_or, "或いは".len);
        if (std.mem.startsWith(u8, rest, "あるいは")) return self.simple(.logical_or, "あるいは".len);
        if (std.mem.startsWith(u8, rest, "and ") or std.mem.startsWith(u8, rest, "and\t")) return self.simple(.logical_and, 4);
        if (std.mem.startsWith(u8, rest, "or ") or std.mem.startsWith(u8, rest, "or\t")) return self.simple(.logical_or, 3);

        if (isStringStart(rest)) return self.readString();
        if (rest[0] >= '0' and rest[0] <= '9') return self.readNumber();

        const decoded = source_mod.decodeAt(self.source.text, self.offset) catch return error.InvalidUtf8;
        if (isWordStart(decoded.codepoint)) return self.readWord();
        return error.UnexpectedCharacter;
    }

    fn simple(self: *Lexer, kind: Kind, length: usize) Error!void {
        return self.simpleWithJosi(kind, length, false);
    }

    fn simpleWithJosi(self: *Lexer, kind: Kind, length: usize, read_josi: bool) Error!void {
        const start = self.offset;
        try self.advanceBytes(length);
        var raw_josi: []const u8 = "";
        var value_josi: []const u8 = "";
        if (read_josi) {
            if (josi_mod.match(self.source.text[self.offset..])) |matched| {
                raw_josi = matched.raw;
                value_josi = matched.value;
                try self.advanceBytes(matched.consumed);
                if (self.offset < self.source.text.len and self.source.text[self.offset] == ',') try self.advanceBytes(1);
            }
        }
        try self.emit(kind, start, self.offset, self.source.text[start .. start + length], value_josi, raw_josi);
    }

    fn readNumber(self: *Lexer) Error!void {
        const start = self.offset;
        var i = self.offset;
        var base: u8 = 10;
        const starts_with_dot = self.source.text[i] == '.';
        if (i + 2 <= self.source.text.len and self.source.text[i] == '0') {
            if (self.source.text[i + 1] == 'x' or self.source.text[i + 1] == 'X') base = 16;
            if (self.source.text[i + 1] == 'o' or self.source.text[i + 1] == 'O') base = 8;
            if (self.source.text[i + 1] == 'b' or self.source.text[i + 1] == 'B') base = 2;
            if (base != 10) i += 2;
        }
        var saw_digit = starts_with_dot;
        if (starts_with_dot) i += 1;
        while (i < self.source.text.len and (isDigitForBase(self.source.text[i], base) or self.source.text[i] == '_')) : (i += 1) {
            if (self.source.text[i] != '_') saw_digit = true;
        }
        if (!saw_digit) return error.InvalidNumber;
        if (!starts_with_dot and base == 10 and i < self.source.text.len and self.source.text[i] == '.') {
            i += 1;
            while (i < self.source.text.len and (std.ascii.isDigit(self.source.text[i]) or self.source.text[i] == '_')) : (i += 1) {}
        }
        if (base == 10 and i < self.source.text.len and (self.source.text[i] == 'e' or self.source.text[i] == 'E')) {
            const exponent = i;
            i += 1;
            if (i < self.source.text.len and (self.source.text[i] == '+' or self.source.text[i] == '-')) i += 1;
            const digit_start = i;
            while (i < self.source.text.len and (std.ascii.isDigit(self.source.text[i]) or self.source.text[i] == '_')) : (i += 1) {}
            if (i == digit_start) i = exponent;
        }
        var kind: Kind = .number;
        if (i < self.source.text.len and self.source.text[i] == 'n') {
            kind = .bigint;
            i += 1;
        }
        try self.advanceBytes(i - self.offset);
        const literal_end = self.offset;

        var css_end: ?usize = null;
        if (kind == .number) {
            const css_units = [_][]const u8{ "vmin", "vmax", "rem", "px", "em", "ex", "vw", "vh" };
            for (css_units) |unit| if (std.mem.startsWith(u8, self.source.text[self.offset..], unit)) {
                try self.advanceBytes(unit.len);
                css_end = self.offset;
                kind = .string;
                break;
            };
            const units = [_][]const u8{ "セット", "ドル", "mm", "cm", "km", "kg", "mb", "kb", "gb", "円", "元", "歩", "㎡", "坪", "度", "℃", "°", "個", "つ", "本", "冊", "才", "歳", "匹", "枚", "皿", "羽", "人", "件", "行", "列", "機", "品", "m", "g", "t", "b" };
            if (css_end == null) for (units) |unit| if (std.mem.startsWith(u8, self.source.text[self.offset..], unit)) {
                try self.advanceBytes(unit.len);
                break;
            };
        }
        var raw_josi: []const u8 = "";
        var value_josi: []const u8 = "";
        if (josi_mod.match(self.source.text[self.offset..])) |matched| {
            raw_josi = matched.raw;
            value_josi = matched.value;
            try self.advanceBytes(matched.consumed);
            if (self.offset < self.source.text.len and self.source.text[self.offset] == ',') try self.advanceBytes(1);
        }
        const value_end = css_end orelse literal_end;
        const value = if (kind == .bigint)
            self.source.text[start..value_end]
        else
            try removeUnderscores(self.allocator, self.source.text[start..value_end]);
        try self.emit(kind, start, self.offset, value, value_josi, raw_josi);
        if (kind == .number) self.tokens.items[self.tokens.items.len - 1].number_value = try parseNumberValue(value, base);
    }

    fn readString(self: *Lexer) Error!void {
        const start = self.offset;
        const start_line = self.line;
        const start_column = self.column;
        const start_indent = self.indent;
        const delimiter = stringDelimiter(self.source.text[start..]).?;
        try self.advanceBytes(delimiter.open.len);
        const content_start = self.offset;
        while (self.offset < self.source.text.len and !std.mem.startsWith(u8, self.source.text[self.offset..], delimiter.close)) {
            if (std.mem.startsWith(u8, self.source.text[self.offset..], delimiter.open)) return error.UnterminatedString;
            try self.advanceCodepoint();
        }
        if (self.offset >= self.source.text.len) return error.UnterminatedString;
        const content_end = self.offset;
        try self.advanceBytes(delimiter.close.len);
        var raw_josi: []const u8 = "";
        var value_josi: []const u8 = "";
        if (josi_mod.match(self.source.text[self.offset..])) |matched| {
            raw_josi = matched.raw;
            value_josi = matched.value;
            try self.advanceBytes(matched.consumed);
            if (self.offset < self.source.text.len and self.source.text[self.offset] == ',') try self.advanceBytes(1);
        }
        const kind: Kind = if (delimiter.template and std.mem.indexOfScalar(u8, self.source.text[content_start..content_end], '{') != null) .string_template else .string;
        self.indent = start_indent;
        self.at_line_start = false;
        try self.emitAt(kind, start, self.offset, self.source.text[content_start..content_end], value_josi, raw_josi, start_line, start_column);
    }

    fn readExtendedWord(self: *Lexer, open: []const u8, close: []const u8) Error!void {
        const start = self.offset;
        try self.advanceBytes(open.len);
        const value_start = self.offset;
        while (self.offset < self.source.text.len and !std.mem.startsWith(u8, self.source.text[self.offset..], close)) try self.advanceCodepoint();
        if (self.offset >= self.source.text.len) return error.UnterminatedString;
        const value_end = self.offset;
        try self.advanceBytes(close.len);
        var raw_josi: []const u8 = "";
        var value_josi: []const u8 = "";
        if (josi_mod.match(self.source.text[self.offset..])) |matched| {
            raw_josi = matched.raw;
            value_josi = matched.value;
            try self.advanceBytes(matched.consumed);
        }
        try self.emit(.identifier, start, self.offset, self.source.text[value_start..value_end], value_josi, raw_josi);
    }

    fn readWord(self: *Lexer) Error!void {
        const start = self.offset;
        var word_end: usize = start;
        var raw_josi: []const u8 = "";
        var value_josi: []const u8 = "";
        while (self.offset < self.source.text.len) {
            if (self.offset > start) {
                const rest = self.source.text[self.offset..];
                if (std.mem.startsWith(u8, rest, "かつ") or std.mem.startsWith(u8, rest, "または")) break;
                if (josi_mod.match(rest)) |matched| {
                    word_end = self.offset;
                    raw_josi = matched.raw;
                    value_josi = matched.value;
                    try self.advanceBytes(matched.consumed);
                    if (self.offset < self.source.text.len and self.source.text[self.offset] == ',') try self.advanceBytes(1);
                    break;
                }
            }
            const decoded = source_mod.decodeAt(self.source.text, self.offset) catch return error.InvalidUtf8;
            if (!isWordContinue(decoded.codepoint)) break;
            try self.advanceCodepoint();
            word_end = self.offset;
        }
        if (word_end <= start) return error.UnexpectedCharacter;
        const raw_word = self.source.text[start..word_end];
        const split_suffixes = [_][]const u8{ "以上", "以下", "未満", "超" };
        for (split_suffixes) |suffix| {
            if (raw_word.len > suffix.len and std.mem.endsWith(u8, raw_word, suffix)) {
                return self.emitSplitWord(start, word_end - suffix.len, word_end, suffix, value_josi, raw_josi, .identifier);
            }
        }
        if (raw_josi.len == 0 and raw_word.len > "回".len and std.mem.endsWith(u8, raw_word, "回")) {
            return self.emitSplitWord(start, word_end - "回".len, word_end, "回", "", "", .keyword_repeat_count);
        }
        if (raw_word.len > "間".len and std.mem.endsWith(u8, raw_word, "間")) {
            const before = raw_word[0 .. raw_word.len - "間".len];
            const previous = previousCodepoint(before) catch return error.InvalidUtf8;
            if (isHiragana(previous)) {
                return self.emitSplitWord(start, word_end - "間".len, word_end, "間", value_josi, raw_josi, .keyword_repeat_while);
            }
        }
        const value = try trimOkurigana(self.allocator, raw_word);
        const kind = reservedKind(value) orelse .identifier;
        const canonical = if (std.mem.eql(u8, value, "そう")) "それ" else value;
        try self.emit(kind, start, self.offset, canonical, value_josi, raw_josi);
    }

    fn emitSplitWord(
        self: *Lexer,
        start: usize,
        suffix_start: usize,
        word_end: usize,
        suffix: []const u8,
        value_josi: []const u8,
        raw_josi: []const u8,
        suffix_kind: Kind,
    ) Error!void {
        const first_value = try trimOkurigana(self.allocator, self.source.text[start..suffix_start]);
        try self.emitAt(.identifier, start, suffix_start, first_value, "", "", self.line, self.columnFor(start));
        try self.emitAt(suffix_kind, suffix_start, self.offset, suffix, value_josi, raw_josi, self.line, self.columnFor(suffix_start));
        _ = word_end;
    }

    fn emit(self: *Lexer, kind: Kind, start: usize, end: usize, value: []const u8, josi: []const u8, raw_josi: []const u8) Error!void {
        try self.emitAt(kind, start, end, value, josi, raw_josi, self.line, self.columnFor(start));
    }

    fn emitAt(self: *Lexer, kind: Kind, start: usize, end: usize, value: []const u8, josi: []const u8, raw_josi: []const u8, line: usize, column: usize) Error!void {
        try self.tokens.append(self.allocator, .{
            .kind = kind,
            .lexeme = self.source.text[start..end],
            .value = value,
            .number_value = null,
            .josi = josi,
            .raw_josi = raw_josi,
            .indent = self.indent,
            .span = .{
                .start = start,
                .end = end,
                .source_start = self.source.sourceOffset(start),
                .source_end = self.source.sourceOffset(end),
                .line = line,
                .column = column,
            },
        });
    }

    fn advanceBytes(self: *Lexer, count: usize) Error!void {
        const end = self.offset + count;
        while (self.offset < end) try self.advanceCodepoint();
    }

    fn advanceCodepoint(self: *Lexer) Error!void {
        const decoded = source_mod.decodeAt(self.source.text, self.offset) catch return error.InvalidUtf8;
        self.offset += decoded.len;
        if (decoded.codepoint == '\n') {
            self.line += 1;
            self.column = 1;
            self.at_line_start = true;
        } else self.column += 1;
    }

    fn columnFor(self: *Lexer, start: usize) usize {
        var line_start = start;
        while (line_start > 0 and self.source.text[line_start - 1] != '\n') line_start -= 1;
        var column: usize = 1;
        var i = line_start;
        while (i < start) {
            const decoded = source_mod.decodeAt(self.source.text, i) catch return column;
            i += decoded.len;
            column += 1;
        }
        return column;
    }
};

const StringDelimiter = struct { open: []const u8, close: []const u8, template: bool };

fn stringDelimiter(source: []const u8) ?StringDelimiter {
    const delimiters = [_]StringDelimiter{
        .{ .open = "🌴", .close = "🌴", .template = true },
        .{ .open = "🌿", .close = "🌿", .template = false },
        .{ .open = "「", .close = "」", .template = true },
        .{ .open = "『", .close = "』", .template = false },
        .{ .open = "“", .close = "”", .template = true },
        .{ .open = "\"", .close = "\"", .template = true },
        .{ .open = "'", .close = "'", .template = false },
    };
    for (delimiters) |delimiter| if (std.mem.startsWith(u8, source, delimiter.open)) return delimiter;
    return null;
}

fn isStringStart(source: []const u8) bool {
    return stringDelimiter(source) != null;
}

fn isDigitForBase(byte: u8, base: u8) bool {
    return switch (base) {
        2 => byte == '0' or byte == '1',
        8 => byte >= '0' and byte <= '7',
        10 => std.ascii.isDigit(byte),
        16 => std.ascii.isHex(byte),
        else => false,
    };
}

fn isHiragana(codepoint: u21) bool {
    return codepoint >= 0x3041 and codepoint <= 0x3093;
}

fn indentationWidth(codepoint: u21) usize {
    if (codepoint == '\t') return 4;
    if (codepoint == ' ' or codepoint == '|') return 1;
    if (codepoint == 0x3000 or codepoint == 0x30FB or codepoint == 0x23CB or codepoint == 0x23CC) return 2;
    if ((codepoint >= 0x2500 and codepoint <= 0x257F) or
        (codepoint >= 0x23A0 and codepoint <= 0x23AF) or
        (codepoint >= 0x23B8 and codepoint <= 0x23BF)) return 2;
    return 0;
}

fn previousCodepoint(bytes: []const u8) !u21 {
    if (bytes.len == 0) return error.InvalidUtf8;
    var start = bytes.len - 1;
    while (start > 0 and (bytes[start] & 0xC0) == 0x80) start -= 1;
    return (try source_mod.decodeAt(bytes, start)).codepoint;
}

fn isWordStart(codepoint: u21) bool {
    return isWordContinue(codepoint) and !(codepoint >= '0' and codepoint <= '9');
}

fn isWordContinue(codepoint: u21) bool {
    return codepoint == 0x3005 or codepoint == '_' or
        (codepoint >= 'a' and codepoint <= 'z') or (codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= '0' and codepoint <= '9') or isHiragana(codepoint) or
        (codepoint >= 0x30A1 and codepoint <= 0x30F6) or codepoint == 0x30FC or
        (codepoint >= 0x4E00 and codepoint <= 0x9FCF) or
        (codepoint >= 0x2460 and codepoint <= 0x24FF) or
        (codepoint >= 0x2776 and codepoint <= 0x277F) or
        (codepoint >= 0x3251 and codepoint <= 0x32BF) or codepoint > 0xFFFF;
}

fn trimOkurigana(allocator: std.mem.Allocator, word: []const u8) Error![]const u8 {
    const first = source_mod.decodeAt(word, 0) catch return error.InvalidUtf8;
    if (isHiragana(first.codepoint)) {
        var all_hiragana = true;
        var last_non_hiragana_end: usize = 0;
        var i: usize = 0;
        while (i < word.len) {
            const decoded = source_mod.decodeAt(word, i) catch return error.InvalidUtf8;
            i += decoded.len;
            if (!isHiragana(decoded.codepoint)) {
                all_hiragana = false;
                last_non_hiragana_end = i;
            }
        }
        return if (all_hiragana) word else word[0..last_non_hiragana_end];
    }
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < word.len) {
        const decoded = source_mod.decodeAt(word, i) catch return error.InvalidUtf8;
        if (!isHiragana(decoded.codepoint)) try result.appendSlice(allocator, word[i .. i + decoded.len]);
        i += decoded.len;
    }
    return result.toOwnedSlice(allocator);
}

fn removeUnderscores(allocator: std.mem.Allocator, literal: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, literal, '_') == null) return literal;
    var result: std.ArrayList(u8) = .empty;
    for (literal) |byte| if (byte != '_') try result.append(allocator, byte);
    return result.toOwnedSlice(allocator);
}

fn parseNumberValue(literal: []const u8, base: u8) Error!f64 {
    if (base == 10) return std.fmt.parseFloat(f64, literal) catch error.InvalidNumber;
    const integer = std.fmt.parseInt(u64, literal[2..], base) catch return error.InvalidNumber;
    return @floatFromInt(integer);
}

fn reservedKind(value: []const u8) ?Kind {
    const words = [_]struct { text: []const u8, kind: Kind }{
        .{ .text = "回", .kind = .keyword_repeat_count },
        .{ .text = "回繰返", .kind = .keyword_repeat_count },
        .{ .text = "間", .kind = .keyword_repeat_while },
        .{ .text = "間繰返", .kind = .keyword_repeat_while },
        .{ .text = "繰返", .kind = .keyword_repeat },
        .{ .text = "増繰返", .kind = .keyword_repeat },
        .{ .text = "減繰返", .kind = .keyword_repeat },
        .{ .text = "後判定", .kind = .keyword_after_test },
        .{ .text = "反復", .kind = .keyword_foreach },
        .{ .text = "抜", .kind = .keyword_break },
        .{ .text = "続", .kind = .keyword_continue },
        .{ .text = "戻", .kind = .keyword_return },
        .{ .text = "変数", .kind = .keyword_let },
        .{ .text = "定数", .kind = .keyword_const },
        .{ .text = "取込", .kind = .keyword_import },
        .{ .text = "エラー監視", .kind = .keyword_error_guard },
        .{ .text = "エラー", .kind = .keyword_error },
        .{ .text = "非同期モード", .kind = .keyword_async },
        .{ .text = "モード設定", .kind = .keyword_mode },
        .{ .text = "関数", .kind = .def_func },
    };
    for (words) |word| if (std.mem.eql(u8, value, word.text)) return word.kind;
    return null;
}

test "公式の基本的な区切りと助詞を認識する" {
    var first = try tokenize(std.testing.allocator, "Nは30");
    defer first.deinit();
    try std.testing.expectEqual(Kind.identifier, first.tokens[0].kind);
    try std.testing.expectEqualStrings("N", first.tokens[0].value);
    try std.testing.expectEqualStrings("は", first.tokens[0].josi);
    try std.testing.expectEqual(Kind.number, first.tokens[1].kind);

    var second = try tokenize(std.testing.allocator, "もしN=30ならば");
    defer second.deinit();
    try std.testing.expectEqual(Kind.keyword_if, second.tokens[0].kind);
    try std.testing.expectEqual(Kind.identifier, second.tokens[1].kind);
    try std.testing.expectEqual(Kind.equal, second.tokens[2].kind);
    try std.testing.expectEqualStrings("ならば", second.tokens[3].josi);
}

test "文字列内部を正規化せず直後の助詞を読む" {
    var stream = try tokenize(std.testing.allocator, "「Ａ＝１」を表示する。");
    defer stream.deinit();
    try std.testing.expectEqual(Kind.string, stream.tokens[0].kind);
    try std.testing.expectEqualStrings("Ａ＝１", stream.tokens[0].value);
    try std.testing.expectEqualStrings("を", stream.tokens[0].josi);
    try std.testing.expectEqualStrings("表示", stream.tokens[1].value);
    try std.testing.expectEqual(Kind.eol, stream.tokens[2].kind);
}

test "全角演算子・BigInt・数値区切りを扱う" {
    var stream = try tokenize(std.testing.allocator, "Ａ＝0xFFn、B＝1_000.5");
    defer stream.deinit();
    try std.testing.expectEqualStrings("A", stream.tokens[0].value);
    try std.testing.expectEqual(Kind.bigint, stream.tokens[2].kind);
    try std.testing.expectEqualStrings("0xFFn", stream.tokens[2].value);
    try std.testing.expectEqual(Kind.comma, stream.tokens[3].kind);
    try std.testing.expectEqualStrings("1000.5", stream.tokens[6].value);
}

test "数値単位・小数・単語分割を公式規則で扱う" {
    var stream = try tokenize(std.testing.allocator, ".5e+2、10px、N回、A以上");
    defer stream.deinit();
    try std.testing.expectEqual(@as(f64, 50), stream.tokens[0].number_value.?);
    try std.testing.expectEqual(Kind.string, stream.tokens[2].kind);
    try std.testing.expectEqualStrings("10px", stream.tokens[2].value);
    try std.testing.expectEqualStrings("N", stream.tokens[4].value);
    try std.testing.expectEqual(Kind.keyword_repeat_count, stream.tokens[5].kind);
    try std.testing.expectEqualStrings("A", stream.tokens[7].value);
    try std.testing.expectEqualStrings("以上", stream.tokens[8].value);
}

test "改行とUTF-8の位置を保持する" {
    var stream = try tokenize(std.testing.allocator, "「A」を表示\n「B」を表示\n");
    defer stream.deinit();
    try std.testing.expectEqual(@as(usize, 1), stream.tokens[3].span.line);
    try std.testing.expectEqual(@as(usize, 1), stream.tokens[3].span.column);
    try std.testing.expectEqualStrings("B", stream.tokens[3].value);
}

test "先頭100行のモード指定を検出する" {
    try std.testing.expectEqual(Mode.indent, detectMode("　!インデント構文\n1を表示"));
    try std.testing.expectEqual(Mode.dncl, detectMode("💡DNCLモード\nA←1"));
    try std.testing.expectEqual(Mode.dncl2, detectMode("!DNCL2\nA=1"));
    try std.testing.expectEqual(Mode.standard, detectMode("1を表示"));
}
