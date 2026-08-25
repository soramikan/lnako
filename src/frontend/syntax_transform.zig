const std = @import("std");
const lexer_mod = @import("lexer.zig");
const token_mod = @import("token.zig");

pub const Error = lexer_mod.Error || error{ ExplicitEndInIndentMode, UnterminatedStringTemplate };
const Kind = token_mod.Kind;
const Token = token_mod.Token;

/// DNCL/DNCL2、明示インデント、行末コロンの順に公式パイプラインと同じ変換を適用する。
pub fn apply(stream: *lexer_mod.TokenStream) Error!void {
    const allocator = stream.arena.allocator();
    var tokens: std.ArrayList(Token) = .empty;
    for (stream.tokens) |token| {
        if (token.kind != .eof) try tokens.append(allocator, token);
    }
    const eof = stream.tokens[stream.tokens.len - 1];

    try expandStringTemplates(stream, &tokens, allocator);
    switch (stream.mode) {
        .dncl => try transformDncl(&tokens, allocator, false),
        .dncl2 => try transformDncl(&tokens, allocator, true),
        else => {},
    }
    try expandAssignmentJosi(&tokens, allocator);
    if (stream.mode == .indent) try transformExplicitIndent(&tokens, allocator);
    removeCollectionEols(&tokens);
    try transformInlineIndent(&tokens, allocator);
    try tokens.append(allocator, eof);
    stream.tokens = try tokens.toOwnedSlice(allocator);
}

fn expandStringTemplates(stream: *lexer_mod.TokenStream, tokens: *std.ArrayList(Token), allocator: std.mem.Allocator) Error!void {
    var index: usize = 0;
    while (index < tokens.items.len) {
        const token = tokens.items[index];
        if (token.kind != .string_template) {
            index += 1;
            continue;
        }

        const source_base = @intFromPtr(stream.source.text.ptr);
        const value_base = @intFromPtr(token.value.ptr);
        if (value_base < source_base or value_base > source_base + stream.source.text.len) return error.UnterminatedStringTemplate;
        const content_start = value_base - source_base;
        var replacement: std.ArrayList(Token) = .empty;
        errdefer replacement.deinit(allocator);
        try replacement.append(allocator, synthetic(.left_paren, "(", token));

        var cursor: usize = 0;
        while (findTemplateOpen(token.value, cursor)) |open| {
            try replacement.append(allocator, templateStringToken(token.value[cursor..open.index], token));
            try replacement.append(allocator, synthetic(.bit_and, "&", token));
            try replacement.append(allocator, synthetic(.left_paren, "(", token));

            const expression_start = open.index + open.len;
            const close = findTemplateClose(token.value, expression_start) orelse return error.UnterminatedStringTemplate;
            var nested = try lexer_mod.tokenize(allocator, token.value[expression_start..close.index]);
            defer nested.deinit();
            for (nested.tokens) |nested_token| {
                if (nested_token.kind == .eof) continue;
                try replacement.append(allocator, try cloneTemplateExpressionToken(
                    stream,
                    nested,
                    nested_token,
                    content_start + expression_start,
                    token.indent,
                    allocator,
                ));
            }
            try replacement.append(allocator, synthetic(.right_paren, ")", token));
            try replacement.append(allocator, synthetic(.bit_and, "&", token));
            cursor = close.index + close.len;
        }
        try replacement.append(allocator, templateStringToken(token.value[cursor..], token));
        var close = synthetic(.right_paren, ")", token);
        close.josi = token.josi;
        close.raw_josi = token.raw_josi;
        close.span = token.span;
        try replacement.append(allocator, close);

        const replacement_len = replacement.items.len;
        try tokens.replaceRange(allocator, index, 1, replacement.items);
        replacement.deinit(allocator);
        index += replacement_len;
    }
}

const TemplateDelimiter = struct { index: usize, len: usize };

fn findTemplateOpen(value: []const u8, start: usize) ?TemplateDelimiter {
    const ascii = std.mem.indexOfPos(u8, value, start, "{");
    const fullwidth = std.mem.indexOfPos(u8, value, start, "｛");
    if (ascii == null and fullwidth == null) return null;
    if (fullwidth == null or (ascii != null and ascii.? < fullwidth.?)) return .{ .index = ascii.?, .len = 1 };
    return .{ .index = fullwidth.?, .len = "｛".len };
}

fn findTemplateClose(value: []const u8, start: usize) ?TemplateDelimiter {
    const ascii = std.mem.indexOfPos(u8, value, start, "}");
    const fullwidth = std.mem.indexOfPos(u8, value, start, "｝");
    if (ascii == null and fullwidth == null) return null;
    if (fullwidth == null or (ascii != null and ascii.? < fullwidth.?)) return .{ .index = ascii.?, .len = 1 };
    return .{ .index = fullwidth.?, .len = "｝".len };
}

fn templateStringToken(value: []const u8, anchor: Token) Token {
    var token = synthetic(.string, value, anchor);
    token.value = value;
    return token;
}

fn cloneTemplateExpressionToken(
    stream: *lexer_mod.TokenStream,
    nested: lexer_mod.TokenStream,
    source: Token,
    expression_start: usize,
    indent: usize,
    allocator: std.mem.Allocator,
) !Token {
    var result = source;
    result.lexeme = try allocator.dupe(u8, source.lexeme);
    result.value = try allocator.dupe(u8, source.value);
    result.josi = try allocator.dupe(u8, source.josi);
    result.raw_josi = try allocator.dupe(u8, source.raw_josi);
    result.indent = indent;
    result.span.start = expression_start + nested.source.sourceOffset(source.span.start);
    result.span.end = expression_start + nested.source.sourceOffset(source.span.end);
    result.span.source_start = stream.source.sourceOffset(result.span.start);
    result.span.source_end = stream.source.sourceOffset(result.span.end);
    const position = lineColumnAt(stream.source.text, result.span.start);
    result.span.line = position.line;
    result.span.column = position.column;
    return result;
}

fn lineColumnAt(source: []const u8, offset: usize) struct { line: usize, column: usize } {
    var line: usize = 0;
    var column: usize = 1;
    var index: usize = 0;
    while (index < @min(offset, source.len)) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(source[index]) catch 1;
        if (source[index] == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
        index += @min(sequence_length, source.len - index);
    }
    return .{ .line = line, .column = column };
}

fn expandAssignmentJosi(tokens: *std.ArrayList(Token), allocator: std.mem.Allocator) !void {
    var index: usize = 0;
    while (index < tokens.items.len) : (index += 1) {
        const token = &tokens.items[index];
        if (!std.mem.eql(u8, token.josi, "は")) continue;
        var equal = synthetic(.equal, "=", token.*);
        const josi_length = token.raw_josi.len;
        if (josi_length <= token.span.end - token.span.start) {
            const assignment_offset = token.span.end - josi_length;
            equal.span.start = assignment_offset;
            equal.span.end = token.span.end;
            equal.span.source_start = if (josi_length <= token.span.source_end - token.span.source_start) token.span.source_end - josi_length else token.span.source_start;
            equal.span.source_end = token.span.source_end;
            token.span.end = assignment_offset;
            token.span.source_end = equal.span.source_start;
        }
        token.josi = "";
        token.raw_josi = "";
        try tokens.insert(allocator, index + 1, equal);
        index += 1;
    }
}

fn transformDncl(tokens: *std.ArrayList(Token), allocator: std.mem.Allocator, is_v2: bool) !void {
    var at_line_start = true;
    var i: usize = 0;
    while (i < tokens.items.len) {
        var token = &tokens.items[i];
        if (token.kind == .eol) {
            at_line_start = true;
            i += 1;
            continue;
        }
        if (at_line_start and token.kind == .pipe) {
            _ = tokens.orderedRemove(i);
            continue;
        }
        at_line_start = false;

        if (!is_v2 and token.kind == .keyword_repeat and std.mem.eql(u8, token.value, "繰返")) {
            const repeat = token.*;
            const replacement = [_]Token{ synthetic(.keyword_after_test, "後判定", repeat), repeat };
            var line_end = i;
            while (line_end < tokens.items.len and tokens.items[line_end].kind != .eol) line_end += 1;
            if (line_end < tokens.items.len) line_end += 1;
            try tokens.replaceRange(allocator, i, line_end - i, &replacement);
            i += replacement.len;
            continue;
        }

        if (token.kind == .assign_arrow) {
            token.kind = .equal;
            token.value = "=";
        } else if (token.kind == .divide and std.mem.startsWith(u8, token.lexeme, "÷")) {
            token.kind = .integer_divide;
            token.value = "÷÷";
        } else if (token.kind == .left_brace) {
            token.kind = .left_bracket;
            token.value = "[";
        } else if (token.kind == .right_brace) {
            token.kind = .right_bracket;
            token.value = "]";
        } else if (token.kind == .identifier and std.mem.eql(u8, token.value, "乱数")) {
            token.value = "乱数範囲";
        } else if (token.kind == .identifier and std.mem.eql(u8, token.value, "表示")) {
            token.value = "連続表示";
        } else if (token.kind == .identifier and std.mem.eql(u8, token.value, "を実行")) {
            token.kind = .keyword_here_end;
            token.value = "ここまで";
            token.josi = "";
            token.raw_josi = "";
        } else if (!is_v2 and token.kind == .identifier and std.mem.eql(u8, token.value, "を繰り返")) {
            token.kind = .keyword_here_end;
            token.value = "ここまで";
            token.josi = "";
            token.raw_josi = "";
        } else if (is_v2 and token.kind == .identifier and std.mem.eql(u8, token.value, "not")) {
            token.kind = .not;
            token.value = "!";
        } else if (is_v2 and token.kind == .identifier and std.mem.eql(u8, token.value, "と定義")) {
            token.kind = .keyword_here_end;
            token.value = "ここまで";
        }

        if (token.kind == .identifier and std.mem.eql(u8, token.value, "ない") and token_mod_isConditional(token.josi) and i > 0) {
            tokens.items[i - 1].josi = "でなければ";
            tokens.items[i - 1].raw_josi = token.raw_josi;
            _ = tokens.orderedRemove(i);
            continue;
        }
        if (token.kind == .identifier and std.mem.eql(u8, token.value, "それ") and
            (std.mem.eql(u8, token.josi, "でなければ") or std.mem.eql(u8, token.josi, "でなく")))
        {
            token.kind = .keyword_else;
            token.value = "違えば";
            token.josi = "";
            token.raw_josi = "";
        }

        if (i + 2 < tokens.items.len and token.kind == .keyword_here_end and tokens.items[i + 1].kind == .comma and
            tokens.items[i + 2].kind == .identifier and std.mem.eql(u8, tokens.items[i + 2].value, "それ"))
        {
            var else_token = tokens.items[i + 2];
            else_token.kind = .keyword_else;
            else_token.value = "違えば";
            else_token.josi = "";
            else_token.raw_josi = "";
            try tokens.replaceRange(allocator, i, 3, &.{else_token});
            token = &tokens.items[i];
        }

        if (i + 1 < tokens.items.len and token.kind == .identifier and std.mem.eql(u8, token.value, "それ") and std.mem.eql(u8, token.josi, "で")) {
            const next = &tokens.items[i + 1];
            if (std.mem.eql(u8, next.value, "なく")) {
                token.kind = .keyword_else;
                token.value = "違えば";
                token.josi = "";
                _ = tokens.orderedRemove(i + 1);
            } else if (std.mem.eql(u8, next.value, "なくもし")) {
                token.kind = .keyword_else;
                token.value = "違えば";
                token.josi = "";
                next.kind = .keyword_if;
                next.value = "もし";
                next.josi = "";
            }
        }

        if (i + 1 < tokens.items.len and token.kind == .identifier and
            (std.mem.eql(u8, token.value, "増") or std.mem.eql(u8, token.value, "減")) and
            tokens.items[i + 1].kind == .identifier and
            (std.mem.eql(u8, tokens.items[i + 1].value, "ら") or std.mem.eql(u8, tokens.items[i + 1].value, "ら繰返") or
                std.mem.eql(u8, tokens.items[i + 1].value, "ら繰り返")))
        {
            token.kind = .keyword_repeat;
            token.value = if (std.mem.eql(u8, token.value, "増")) "増繰返" else "減繰返";
            token.josi = "";
            _ = tokens.orderedRemove(i + 1);
        }
        if (token.kind == .identifier and
            ((token.value.len > "増".len and std.mem.endsWith(u8, token.value, "増")) or
                (token.value.len > "減".len and std.mem.endsWith(u8, token.value, "減"))))
        {
            const suffix = token.value[token.value.len - "増".len ..];
            token.value = token.value[0 .. token.value.len - "増".len];
            token.josi = "だけ";
            try tokens.insert(allocator, i + 1, synthetic(.identifier, suffix, token.*));
            i += 2;
            continue;
        }

        if (i + 1 < tokens.items.len and token.kind == .identifier and std.mem.eql(u8, token.value, "二進") and
            tokens.items[i + 1].kind == .identifier and std.mem.eql(u8, tokens.items[i + 1].value, "表示"))
        {
            token.value = "二進表示";
            token.josi = "";
            _ = tokens.orderedRemove(i + 1);
        }
        if (i + 1 < tokens.items.len and token.kind == .identifier and std.mem.eql(u8, token.value, "改行") and
            tokens.items[i + 1].kind == .identifier and std.mem.eql(u8, tokens.items[i + 1].value, "表示"))
        {
            token.value = "連続無改行表示";
            token.josi = "";
            _ = tokens.orderedRemove(i + 1);
        }
        if (!is_v2 and i + 1 < tokens.items.len and token.kind == .identifier and std.mem.eql(u8, token.value, "なる") and
            std.mem.eql(u8, token.josi, "まで") and tokens.items[i + 1].kind == .identifier and
            (std.mem.eql(u8, tokens.items[i + 1].value, "実行") or std.mem.eql(u8, tokens.items[i + 1].value, "繰返")))
        {
            tokens.items[i + 1].kind = .keyword_repeat_while;
            tokens.items[i + 1].value = "間";
            for (tokens.items[0..i]) |*before| {
                if (before.kind == .identifier and (std.mem.eql(u8, before.value, "を") or std.mem.eql(u8, before.value, "が"))) {
                    before.kind = .keyword_here_end;
                    before.value = "ここまで";
                }
            }
        }
        i += 1;
    }
    try transformDnclArrays(tokens, allocator, is_v2);
}

fn transformDnclArrays(tokens: *std.ArrayList(Token), allocator: std.mem.Allocator, is_v2: bool) !void {
    var i: usize = 0;
    while (i < tokens.items.len) {
        if (is_v2 and matchValues(tokens.items, i, &.{ null, null, "すべて", null, null, "代入" }) and
            (std.mem.eql(u8, tokens.items[i].value, "配列") or std.mem.eql(u8, tokens.items[i].value, "配列変数")) and
            (std.mem.eql(u8, tokens.items[i + 3].value, "要素") or std.mem.eql(u8, tokens.items[i + 3].value, "値")))
        {
            const anchor = tokens.items[i];
            var variable = tokens.items[i + 1];
            var value = tokens.items[i + 4];
            variable.josi = "";
            value.josi = "";
            const replacement = [_]Token{
                variable,
                synthetic(.equal, "=", anchor),
                synthetic(.identifier, "掛", anchor),
                synthetic(.left_paren, "(", anchor),
                synthetic(.left_bracket, "[", anchor),
                value,
                synthetic(.right_bracket, "]", anchor),
                synthetic(.comma, ",", anchor),
                syntheticNumber(30, anchor),
                synthetic(.right_paren, ")", anchor),
            };
            try tokens.replaceRange(allocator, i, 6, &replacement);
            i += replacement.len;
            continue;
        }
        if (is_v2 and matchValues(tokens.items, i, &.{ null, "すべて", null, null, "する" }) and
            (std.mem.eql(u8, tokens.items[i + 2].value, "要素") or std.mem.eql(u8, tokens.items[i + 2].value, "値")))
        {
            const anchor = tokens.items[i];
            var variable = tokens.items[i];
            var value = tokens.items[i + 3];
            variable.josi = "";
            value.josi = "";
            const replacement = [_]Token{
                variable,
                synthetic(.equal, "=", anchor),
                synthetic(.identifier, "掛", anchor),
                synthetic(.left_paren, "(", anchor),
                synthetic(.left_bracket, "[", anchor),
                value,
                synthetic(.right_bracket, "]", anchor),
                synthetic(.comma, ",", anchor),
                syntheticNumber(30, anchor),
                synthetic(.right_paren, ")", anchor),
            };
            try tokens.replaceRange(allocator, i, 5, &replacement);
            i += replacement.len;
            continue;
        }
        if (is_v2 and matchValues(tokens.items, i, &.{ null, null, "初期化" }) and
            (std.mem.eql(u8, tokens.items[i].value, "配列変数") or std.mem.eql(u8, tokens.items[i].value, "配列")))
        {
            const anchor = tokens.items[i];
            var variable = tokens.items[i + 1];
            variable.josi = "";
            const replacement = [_]Token{
                variable,
                synthetic(.equal, "=", anchor),
                synthetic(.identifier, "掛", anchor),
                synthetic(.left_paren, "(", anchor),
                synthetic(.left_bracket, "[", anchor),
                syntheticNumber(0, anchor),
                synthetic(.right_bracket, "]", anchor),
                synthetic(.comma, ",", anchor),
                syntheticNumber(30, anchor),
                synthetic(.right_paren, ")", anchor),
            };
            try tokens.replaceRange(allocator, i, 3, &replacement);
            i += replacement.len;
            continue;
        }
        if (!is_v2 and matchValues(tokens.items, i, &.{ null, "すべて", null, null, null })) {
            const element = tokens.items[i + 2].value;
            if (std.mem.eql(u8, element, "要素") or std.mem.eql(u8, element, "値")) {
                const anchor = tokens.items[i];
                var variable = tokens.items[i];
                var value = tokens.items[i + 3];
                variable.josi = "";
                value.josi = "";
                var close = synthetic(.right_bracket, "]", anchor);
                close.josi = "に";
                var count = syntheticNumber(100, anchor);
                count.josi = "を";
                const replacement = [_]Token{
                    variable,
                    synthetic(.equal, "=", anchor),
                    synthetic(.left_bracket, "[", anchor),
                    value,
                    close,
                    count,
                    synthetic(.identifier, "掛", anchor),
                };
                try tokens.replaceRange(allocator, i, 5, &replacement);
                i += replacement.len;
                continue;
            }
        }
        i += 1;
    }
}

fn matchValues(tokens: []const Token, start: usize, pattern: []const ?[]const u8) bool {
    if (start + pattern.len > tokens.len) return false;
    for (pattern, 0..) |expected, offset| if (expected) |value| {
        if (!std.mem.eql(u8, tokens[start + offset].value, value)) return false;
    };
    return true;
}

fn transformExplicitIndent(tokens: *std.ArrayList(Token), allocator: std.mem.Allocator) Error!void {
    for (tokens.items) |token| if (token.kind == .keyword_here_end) return error.ExplicitEndInIndentMode;

    var output: std.ArrayList(Token) = .empty;
    var blocks: std.ArrayList(Block) = .empty;
    var last_indent: usize = 0;
    var nesting: usize = 0;
    var start: usize = 0;
    while (start < tokens.items.len) {
        const end = lineEnd(tokens.items, start);
        const line = tokens.items[start..end];
        const first_index = firstMeaningful(line);
        if (first_index) |index| {
            const first = line[index];
            if (nesting == 0) {
                const current = first.indent;
                while (blocks.items.len > 0 and blocks.items[blocks.items.len - 1].body_indent > current) {
                    const block = blocks.pop().?;
                    if (!(first.kind == .keyword_else and block.parent_indent == current)) {
                        try appendEnd(&output, allocator, lastToken(output.items));
                    }
                }
                last_indent = if (blocks.items.len > 0) blocks.items[blocks.items.len - 1].body_indent else 0;
                if (current > last_indent) {
                    try blocks.append(allocator, .{ .body_indent = current, .parent_indent = last_indent });
                    last_indent = current;
                }
            }
        }
        try output.appendSlice(allocator, line);
        updateNesting(line, &nesting);
        start = end;
    }
    const anchor = lastToken(output.items);
    while (blocks.pop()) |_| try appendEnd(&output, allocator, anchor);
    tokens.* = output;
}

fn removeCollectionEols(tokens: *std.ArrayList(Token)) void {
    var nesting: usize = 0;
    var collection_indent: usize = 0;
    var reset_on_eol = false;
    var i: usize = 0;
    while (i < tokens.items.len) {
        var token = &tokens.items[i];
        if (token.kind == .left_brace or token.kind == .left_bracket) {
            if (nesting == 0) collection_indent = token.indent;
            nesting += 1;
            token.indent = collection_indent;
            i += 1;
            continue;
        }
        if (token.kind == .right_brace or token.kind == .right_bracket) {
            if (nesting > 0) nesting -= 1;
            if (nesting == 0) reset_on_eol = true;
            i += 1;
            continue;
        }
        if (nesting > 0) token.indent = collection_indent;
        if (token.kind == .eol and nesting > 0) {
            _ = tokens.orderedRemove(i);
            continue;
        }
        if (token.kind == .eol and reset_on_eol) {
            token.indent = collection_indent;
            reset_on_eol = false;
        }
        i += 1;
    }
}

fn transformInlineIndent(tokens: *std.ArrayList(Token), allocator: std.mem.Allocator) Error!void {
    var output: std.ArrayList(Token) = .empty;
    var blocks: std.ArrayList(usize) = .empty;
    var nesting: usize = 0;
    var start: usize = 0;
    while (start < tokens.items.len) {
        const end = lineEnd(tokens.items, start);
        const line = tokens.items[start..end];
        const first_index = firstMeaningful(line);
        if (first_index) |index| {
            const first = line[index];
            if (nesting == 0) {
                while (blocks.items.len > 0 and blocks.items[blocks.items.len - 1] >= first.indent) {
                    const block_indent = blocks.pop().?;
                    if (!(first.kind == .keyword_else and block_indent == first.indent)) {
                        try appendEnd(&output, allocator, first);
                    }
                }
            }
        }

        const last_index = lastMeaningful(line);
        const opens_block = nesting == 0 and last_index != null and line[last_index.?].kind == .colon;
        for (line, 0..) |token, index| {
            if (opens_block and index == last_index.?) continue;
            try output.append(allocator, token);
        }
        updateNesting(line, &nesting);
        if (opens_block) try blocks.append(allocator, line[last_index.?].indent);
        start = end;
    }
    const anchor = lastToken(output.items);
    while (blocks.pop()) |_| try appendEnd(&output, allocator, anchor);
    tokens.* = output;
}

const Block = struct { body_indent: usize, parent_indent: usize };

fn lineEnd(tokens: []const Token, start: usize) usize {
    var end = start;
    while (end < tokens.len) : (end += 1) if (tokens[end].kind == .eol) return end + 1;
    return tokens.len;
}

fn firstMeaningful(line: []const Token) ?usize {
    for (line, 0..) |token, index| if (token.kind != .eol) return index;
    return null;
}

fn lastMeaningful(line: []const Token) ?usize {
    var index = line.len;
    while (index > 0) {
        index -= 1;
        if (line[index].kind != .eol) return index;
    }
    return null;
}

fn updateNesting(line: []const Token, nesting: *usize) void {
    for (line) |token| switch (token.kind) {
        .left_brace, .left_bracket => nesting.* += 1,
        .right_brace, .right_bracket => if (nesting.* > 0) {
            nesting.* -= 1;
        },
        else => {},
    };
}

fn appendEnd(output: *std.ArrayList(Token), allocator: std.mem.Allocator, anchor: Token) !void {
    var end = synthetic(.keyword_here_end, "ここまで", anchor);
    end.indent = anchor.indent;
    try output.append(allocator, end);
    try output.append(allocator, synthetic(.eol, "", anchor));
}

fn synthetic(kind: Kind, value: []const u8, anchor: Token) Token {
    return .{
        .kind = kind,
        .lexeme = "",
        .value = value,
        .indent = anchor.indent,
        .span = .{
            .start = anchor.span.start,
            .end = anchor.span.start,
            .source_start = anchor.span.source_start,
            .source_end = anchor.span.source_start,
            .line = anchor.span.line,
            .column = anchor.span.column,
        },
    };
}

fn syntheticNumber(value: u32, anchor: Token) Token {
    var token = synthetic(.number, if (value == 0) "0" else if (value == 30) "30" else "100", anchor);
    token.number_value = @floatFromInt(value);
    return token;
}

fn lastToken(tokens: []const Token) Token {
    if (tokens.len > 0) return tokens[tokens.len - 1];
    return .{
        .kind = .eol,
        .lexeme = "",
        .value = "",
        .span = .{ .start = 0, .end = 0, .source_start = 0, .source_end = 0, .line = 0, .column = 1 },
    };
}

fn token_mod_isConditional(value: []const u8) bool {
    return std.mem.eql(u8, value, "でなければ") or std.mem.eql(u8, value, "なければ") or
        std.mem.eql(u8, value, "ならば") or std.mem.eql(u8, value, "なら") or
        std.mem.eql(u8, value, "たら") or std.mem.eql(u8, value, "れば");
}

test "明示インデント構文へここまでを挿入する" {
    var stream = try lexer_mod.tokenize(std.testing.allocator, "!インデント構文\nもし1=1ならば\n　　1を表示\n2を表示\n");
    defer stream.deinit();
    try apply(&stream);
    var found_end = false;
    for (stream.tokens) |token| if (token.kind == .keyword_here_end) {
        found_end = true;
        break;
    };
    try std.testing.expect(found_end);
}

test "インラインインデントのコロンをここまでへ変換する" {
    var stream = try lexer_mod.tokenize(std.testing.allocator, "もし1=1ならば:\n　　1を表示\n2を表示\n");
    defer stream.deinit();
    try apply(&stream);
    var colon_count: usize = 0;
    var end_count: usize = 0;
    for (stream.tokens) |token| {
        if (token.kind == .colon) colon_count += 1;
        if (token.kind == .keyword_here_end) end_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), colon_count);
    try std.testing.expectEqual(@as(usize, 1), end_count);
}

test "DNCLの代入・整数除算・配列括弧を変換する" {
    var stream = try lexer_mod.tokenize(std.testing.allocator, "!DNCLモード\nA←{{7÷2}}\n");
    defer stream.deinit();
    try apply(&stream);
    try std.testing.expectEqual(token_mod.Mode.dncl, stream.mode);
    var equal_count: usize = 0;
    var integer_divide_count: usize = 0;
    for (stream.tokens) |token| {
        if (token.kind == .equal) equal_count += 1;
        if (token.kind == .integer_divide) integer_divide_count += 1;
        try std.testing.expect(token.kind != .left_brace and token.kind != .right_brace);
    }
    try std.testing.expectEqual(@as(usize, 1), equal_count);
    try std.testing.expectEqual(@as(usize, 1), integer_divide_count);
}

test "DNCL2の配列初期化を30要素の式へ変換する" {
    var stream = try lexer_mod.tokenize(std.testing.allocator, "!DNCL2\n配列 Hindo のすべての要素に 10 を代入する\n");
    defer stream.deinit();
    try apply(&stream);
    var has_multiply = false;
    var has_count = false;
    for (stream.tokens) |token| {
        if (token.kind == .identifier and std.mem.eql(u8, token.value, "掛")) has_multiply = true;
        if (token.kind == .number and token.number_value != null and token.number_value.? == 30) has_count = true;
    }
    try std.testing.expect(has_multiply);
    try std.testing.expect(has_count);
}

test "展開あり文字列の埋め込み式を文字列連結へ変換する" {
    var stream = try lexer_mod.tokenize(std.testing.allocator, "A=30\n「ab{A+1}cd｛A｝」を表示\n");
    defer stream.deinit();
    try apply(&stream);
    var strings: usize = 0;
    var concats: usize = 0;
    var additions: usize = 0;
    var embedded_identifier_column: ?usize = null;
    for (stream.tokens) |token| {
        try std.testing.expect(token.kind != .string_template);
        if (token.kind == .string) strings += 1;
        if (token.kind == .bit_and) concats += 1;
        if (token.kind == .plus) additions += 1;
        if (token.kind == .identifier and std.mem.eql(u8, token.value, "A") and token.span.line == 1 and embedded_identifier_column == null) {
            embedded_identifier_column = token.span.column;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), strings);
    try std.testing.expectEqual(@as(usize, 4), concats);
    try std.testing.expectEqual(@as(usize, 1), additions);
    try std.testing.expectEqual(@as(?usize, 5), embedded_identifier_column);
}

test "閉じ中括弧のない文字列テンプレートを拒否する" {
    var stream = try lexer_mod.tokenize(std.testing.allocator, "「A{B」を表示\n");
    defer stream.deinit();
    try std.testing.expectError(error.UnterminatedStringTemplate, apply(&stream));
}
