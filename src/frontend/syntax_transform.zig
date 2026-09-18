const std = @import("std");
const lexer_mod = @import("lexer.zig");
const source_mod = @import("source.zig");
const token_mod = @import("token.zig");

pub const Error = lexer_mod.Error || error{ ExplicitEndInIndentMode, UnterminatedStringTemplate };
const Kind = token_mod.Kind;
const Token = token_mod.Token;

/// 公式パイプラインと同じく convertDNCL2 → convertDNCL → インデント構文 →
/// インラインインデントの順に変換を適用する。各モードは独立して有効化され得る。
pub fn apply(stream: *lexer_mod.TokenStream) Error!void {
    const allocator = stream.arena.allocator();
    var tokens: std.ArrayList(Token) = .empty;
    for (stream.tokens) |token| {
        if (token.kind != .eof) try tokens.append(allocator, token);
    }
    const eof = stream.tokens[stream.tokens.len - 1];

    if (stream.mode.dncl2) try transformDncl(&tokens, allocator, true);
    if (stream.mode.dncl) try transformDncl(&tokens, allocator, false);
    try expandStringTemplates(stream, &tokens, allocator);
    try expandAssignmentJosi(&tokens, allocator);
    if (stream.mode.indent) try transformExplicitIndent(&tokens, allocator);
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
            var nested = try lexer_mod.tokenizeFragment(allocator, token.value[expression_start..close.index]);
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

/// 公式 nako_from_dncl.mts / nako_from_dncl2.mts の行単位変換を再現する。
/// 行分割は `{`/`}` のネスト中はeolで分割しない公式の splitTokens と同じ規則。
fn transformDncl(tokens: *std.ArrayList(Token), allocator: std.mem.Allocator, comptime is_v2: bool) !void {
    var lines: std.ArrayList(std.ArrayList(Token)) = .empty;
    defer {
        for (lines.items) |*line| line.deinit(allocator);
        lines.deinit(allocator);
    }
    try splitTokenLines(tokens.items, &lines, allocator);
    for (lines.items) |*line| {
        if (line.items.len <= 1) continue;
        if (is_v2) try transformDncl2Line(line, allocator) else try transformDncl1Line(line, allocator);
    }
    tokens.clearRetainingCapacity();
    for (lines.items) |line| {
        var index: usize = 0;
        // DNCL(v1)は行頭の連続する'|'をコメント（＝削除対象）として扱う
        if (!is_v2) while (index < line.items.len and line.items[index].kind == .pipe) : (index += 1) {};
        try tokens.appendSlice(allocator, line.items[index..]);
    }
    applyDnclSimpleReplacements(tokens.items, is_v2);
}

/// 公式 splitTokens と同じく、eolで分割するが `{`/`}` のネスト中は分割しない。
/// `}` が `{` より多い場合は負になり得る点も公式の挙動に合わせる。
fn splitTokenLines(tokens: []const Token, lines: *std.ArrayList(std.ArrayList(Token)), allocator: std.mem.Allocator) !void {
    var line: std.ArrayList(Token) = .empty;
    var kakko: isize = 0;
    for (tokens) |token| {
        try line.append(allocator, token);
        switch (token.kind) {
            .left_brace => kakko += 1,
            .right_brace => kakko -= 1,
            .eol => if (kakko == 0) {
                try lines.append(allocator, line);
                line = .empty;
            },
            else => {},
        }
    }
    if (line.items.len > 0) try lines.append(allocator, line);
}

/// 公式の `type:value` パターン表記に対応するマッチャー。
const Matcher = union(enum) {
    /// `word:値` … lnakoでは公式の'word'に相当する語由来kindをまとめて判定する
    word: []const u8,
    /// `word`（値不問）
    word_any,
    /// `word:そう` … lnakoでは「そう」が値「それ」へ正規化されるため字句で判定する
    sou,
    /// `*`（ワイルドカード）
    any,
    /// 特定のkind（値不問）
    kind: Kind,
    /// `kind:値`
    kind_value: KindValue,
    /// 候補のいずれかに一致
    alt: []const Matcher,
};

const KindValue = struct { kind: Kind, value: []const u8 };

/// 公式でtype 'word'として生成されるトークンに対応するkindかどうか。
/// `もし`/`違えば`/`ここまで`等は公式でも専用typeなのでwordには含めない。
fn isWordToken(token: Token) bool {
    return switch (token.kind) {
        .identifier,
        .keyword_repeat,
        .keyword_repeat_while,
        .keyword_repeat_count,
        .keyword_after_test,
        .keyword_foreach,
        .keyword_break,
        .keyword_continue,
        .keyword_return,
        .keyword_let,
        .keyword_const,
        .keyword_import,
        .keyword_error_guard,
        .keyword_error,
        .keyword_async,
        .keyword_mode,
        => true,
        .def_func => !std.mem.startsWith(u8, token.lexeme, "●"), // 「関数」はword、`●`はdef_func
        else => false,
    };
}

/// 公式の `word:そう`。lnakoは字句「そう」を値「それ」へ正規化するため、
/// lexemeの先頭で区別する（「それ」は `word:そう` パターンに一致しない）。
fn isSouWord(token: Token) bool {
    if (!isWordToken(token)) return false;
    if (std.mem.eql(u8, token.value, "それ") and std.mem.startsWith(u8, token.lexeme, "そう")) return true;
    return std.mem.eql(u8, token.value, "そう");
}

/// 公式の `t.value === 'そう' || t.value === 'それ'`。
fn isSouOrSore(token: Token) bool {
    return isWordToken(token) and (std.mem.eql(u8, token.value, "それ") or std.mem.eql(u8, token.value, "そう"));
}

fn matchToken(token: Token, matcher: Matcher) bool {
    return switch (matcher) {
        .word => |value| isWordToken(token) and std.mem.eql(u8, token.value, value),
        .word_any => isWordToken(token),
        .sou => isSouWord(token),
        .any => true,
        .kind => |kind| token.kind == kind,
        .kind_value => |kv| token.kind == kv.kind and std.mem.eql(u8, token.value, kv.value),
        .alt => |alternatives| blk: {
            for (alternatives) |alternative| if (matchToken(token, alternative)) break :blk true;
            break :blk false;
        },
    };
}

/// 公式 findTokens と同じく、行内で最初に一致した位置を返す。
fn findSeq(line: []const Token, matchers: []const Matcher) ?usize {
    var index: usize = 0;
    outer: while (index < line.len) : (index += 1) {
        for (matchers, 0..) |matcher, offset| {
            const at = index + offset;
            if (at >= line.len) return null;
            if (!matchToken(line[at], matcher)) continue :outer;
        }
        return index;
    }
    return null;
}

/// 公式 tokenEq と同じく、指定位置からの連続一致を確認する。
fn matchesAt(line: []const Token, start: usize, matchers: []const Matcher) bool {
    for (matchers, 0..) |matcher, offset| {
        const at = start + offset;
        if (at >= line.len) return false;
        if (!matchToken(line[at], matcher)) return false;
    }
    return true;
}

fn transformDncl1Line(line: *std.ArrayList(Token), allocator: std.mem.Allocator) !void {
    // 行頭の「繰返」は後判定繰り返し。公式は行全体を2トークンへ置き換える。
    if (isWordValue(line.items[0], "繰返")) {
        const repeat = line.items[0];
        line.clearRetainingCapacity();
        try line.append(allocator, synthetic(.keyword_after_test, "後判定", repeat));
        try line.append(allocator, repeat);
    }
    // 「…になるまで(繰り返す|実行する)」→ 後判定条件ループ
    if (findSeq(line.items, &.{ .{ .word = "なる" }, .{ .word = "繰返" } })) |index| {
        if (index > 0) replaceAtohantei(line.items, index);
    }
    if (findSeq(line.items, &.{ .{ .word = "なる" }, .{ .word = "実行" } })) |index| {
        if (index > 0) replaceAtohantei(line.items, index);
    }
    try convertNaiNaraba(line);
    try mergeDisplayDirectives(line);
    try convertSouAfterExecute(line, allocator);
    try mergeWordLoop(line, allocator, "増", "ら", "増繰返");
    try mergeWordLoop(line, allocator, "減", "ら", "減繰返");
    // 「を繰り返す」→ ここまで
    while (findSeq(line.items, &.{.{ .word = "を繰り返" }})) |index| {
        var token = &line.items[index];
        token.kind = .keyword_here_end;
        token.value = "ここまで";
        token.josi = "";
        token.raw_josi = "";
    }
    // 「(変数)のすべての要素/値を値にする」→ 変数=[値]に100を掛
    while (findSeq(line.items, &.{ .{ .word = "すべて" }, .{ .word = "要素" } })) |index| {
        if (index < 1 or index + 2 >= line.items.len) break;
        try replaceAllElementV1(line, allocator, index);
    }
    while (findSeq(line.items, &.{ .{ .word = "すべて" }, .{ .word = "値" } })) |index| {
        if (index < 1 or index + 2 >= line.items.len) break;
        try replaceAllElementV1(line, allocator, index);
    }
    try splitGrowShrinkSuffix(line, allocator);
}

fn transformDncl2Line(line: *std.ArrayList(Token), allocator: std.mem.Allocator) !void {
    try convertNaiNaraba(line);
    // 「そうでなければ」「そうでなく」→ 違えば（「それ」でも同じ）
    for (line.items) |*token| {
        if (isSouOrSore(token.*) and
            (std.mem.eql(u8, token.josi, "でなければ") or std.mem.eql(u8, token.josi, "でなく")))
        {
            token.kind = .keyword_else;
            token.value = "違えば";
            token.josi = "";
            token.raw_josi = "";
        }
    }
    try convertSouAfterExecute(line, allocator);
    // 「そう,なく」→ 違えば（「そう」の助詞が「で」の場合のみ）
    while (findSeq(line.items, &.{ .sou, .{ .word = "なく" } })) |index| {
        if (!std.mem.eql(u8, line.items[index].josi, "で")) break;
        line.items[index].kind = .keyword_else;
        line.items[index].value = "違えば";
        line.items[index].josi = "";
        line.items[index].raw_josi = "";
        _ = line.orderedRemove(index + 1);
    }
    // 「そう,なくもし」→ 違えば,もし
    while (findSeq(line.items, &.{ .sou, .{ .word = "なくもし" } })) |index| {
        line.items[index].kind = .keyword_else;
        line.items[index].value = "違えば";
        line.items[index].josi = "";
        line.items[index].raw_josi = "";
        const moshi = &line.items[index + 1];
        moshi.kind = .keyword_if;
        moshi.value = "もし";
        moshi.josi = "";
        moshi.raw_josi = "";
    }
    try mergeWordLoop(line, allocator, "増", "ら", "増繰返");
    try mergeWordLoop(line, allocator, "減", "ら", "減繰返");
    try mergeWordLoop(line, allocator, "増", "ら繰り返", "増繰返");
    try mergeWordLoop(line, allocator, "減", "ら繰り返", "減繰返");
    try transformDncl2Arrays(line, allocator);
    try mergeDisplayDirectives(line);
    try splitGrowShrinkSuffix(line, allocator);
}

/// 「もし(条件)でないならば」→「もし(条件)でなければ」。公式は行内の最初の1件のみ変換する。
fn convertNaiNaraba(line: *std.ArrayList(Token)) !void {
    if (findSeq(line.items, &.{.{ .word = "ない" }})) |index| {
        if (index >= 1 and std.mem.eql(u8, line.items[index].josi, "ならば")) {
            line.items[index - 1].josi = "でなければ";
            line.items[index - 1].raw_josi = "でなければ";
            _ = line.orderedRemove(index);
        }
    }
}

/// 「二進で表示」→「二進表示」、「改行なしで表示」→「連続無改行表示」。
fn mergeDisplayDirectives(line: *std.ArrayList(Token)) !void {
    while (findSeq(line.items, &.{ .{ .word = "二進" }, .{ .word = "表示" } })) |index| {
        line.items[index].value = "二進表示";
        line.items[index].josi = "";
        _ = line.orderedRemove(index + 1);
    }
    while (findSeq(line.items, &.{ .{ .word = "改行" }, .{ .word = "表示" } })) |index| {
        line.items[index].value = "連続無改行表示";
        line.items[index].josi = "";
        _ = line.orderedRemove(index + 1);
    }
}

/// 「を実行し、そうでなければ」→「違えば」、「を実行し、そうでなくもし…」→「違えば,もし…」。
fn convertSouAfterExecute(line: *std.ArrayList(Token), allocator: std.mem.Allocator) !void {
    const comma: Matcher = .{ .kind_value = .{ .kind = .comma, .value = "," } };
    while (findSeq(line.items, &.{ .{ .word = "を実行" }, comma, .sou })) |index| {
        const sou = line.items[index + 2];
        if (std.mem.eql(u8, sou.josi, "でなければ")) {
            var else_token = sou;
            else_token.kind = .keyword_else;
            else_token.value = "違えば";
            else_token.josi = "";
            else_token.raw_josi = "";
            try line.replaceRange(allocator, index, 3, &.{else_token});
            continue;
        }
        if (std.mem.eql(u8, sou.josi, "で") and index + 3 < line.items.len and
            std.mem.startsWith(u8, line.items[index + 3].value, "なくもし"))
        {
            var else_token = sou;
            else_token.kind = .keyword_else;
            else_token.value = "違えば";
            else_token.josi = "";
            else_token.raw_josi = "";
            try line.replaceRange(allocator, index, 3, &.{else_token});
            const nakumosi_index = index + 1;
            if (line.items[nakumosi_index].value.len > "なくもし".len) {
                const suffix = line.items[nakumosi_index].value["なくもし".len..];
                var suffix_token = synthetic(.identifier, suffix, line.items[nakumosi_index]);
                if (std.ascii.isDigit(suffix[0])) {
                    suffix_token.kind = .number;
                    suffix_token.number_value = std.fmt.parseFloat(f64, suffix) catch null;
                }
                try line.insert(allocator, nakumosi_index + 1, suffix_token);
                line.items[nakumosi_index].value = "なくもし";
            }
            line.items[nakumosi_index].kind = .keyword_if;
            line.items[nakumosi_index].value = "もし";
            line.items[nakumosi_index].josi = "";
            line.items[nakumosi_index].raw_josi = "";
            continue;
        }
        break;
    }
}

/// 「(増|減)やしながら…」→ 増繰返/減繰返。語「増|減」＋指定語の連続を1語に併合する。
fn mergeWordLoop(line: *std.ArrayList(Token), allocator: std.mem.Allocator, first: []const u8, second: []const u8, merged: []const u8) !void {
    while (findSeq(line.items, &.{ .{ .word = first }, .{ .word = second } })) |index| {
        var token = line.items[index];
        token.kind = .keyword_repeat;
        token.value = merged;
        token.josi = "";
        token.raw_josi = "";
        try line.replaceRange(allocator, index, 2, &.{token});
    }
}

/// 「…になるまで(繰り返す|実行する)」用。行内の最初の「を」「が」をここまでに、
/// 「繰返/実行」を「間」に置き換える。
fn replaceAtohantei(line: []Token, index: usize) void {
    if (findSeq(line, &.{.{ .word = "を" }})) |wo| {
        line[wo].kind = .keyword_here_end;
        line[wo].value = "ここまで";
    }
    if (findSeq(line, &.{.{ .word = "が" }})) |ga| {
        line[ga].kind = .keyword_here_end;
        line[ga].value = "ここまで";
    }
    line[index + 1].kind = .keyword_repeat_while;
    line[index + 1].value = "間";
}

/// DNCL(v1)の「(変数)のすべての(要素|値)を値にする」。
/// 「すべて」の位置niから4トークンを「= [値]に 100を 掛」へ置き換える。
fn replaceAllElementV1(line: *std.ArrayList(Token), allocator: std.mem.Allocator, index: usize) !void {
    const anchor = line.items[index];
    line.items[index - 1].josi = "";
    line.items[index - 1].raw_josi = "";
    var value = line.items[index + 2];
    value.josi = "";
    value.raw_josi = "";
    var close = synthetic(.right_bracket, "]", anchor);
    close.josi = "に";
    var count = syntheticNumber(100, anchor);
    count.josi = "を";
    const replacement = [_]Token{
        synthetic(.equal, "=", anchor),
        synthetic(.left_bracket, "[", anchor),
        value,
        close,
        count,
        synthetic(.identifier, "掛", anchor),
    };
    try line.replaceRange(allocator, index, @min(@as(usize, 4), line.items.len - index), &replacement);
}

/// DNCL2の配列初期化3パターン。いずれも「変数 = 掛([値],30)」へ変換する。
fn transformDncl2Arrays(line: *std.ArrayList(Token), allocator: std.mem.Allocator) !void {
    const array_word: Matcher = .{ .alt = &.{ .{ .word = "配列" }, .{ .word = "配列変数" } } };
    const element_word: Matcher = .{ .alt = &.{ .{ .word = "要素" }, .{ .word = "値" } } };
    const value_token: Matcher = .{ .alt = &.{ .{ .kind = .number }, .{ .kind = .string }, .word_any } };
    var index: usize = 0;
    while (index < line.items.len) : (index += 1) {
        // 「配列(変数) 変数 のすべての(要素|値)に 値 を代入する」
        if (matchesAt(line.items, index, &.{ array_word, .word_any, .{ .word = "すべて" }, element_word, .any, .{ .word = "代入" } })) {
            var variable = line.items[index + 1];
            variable.josi = "";
            variable.raw_josi = "";
            var value = line.items[index + 4];
            value.josi = "";
            value.raw_josi = "";
            try line.replaceRange(allocator, index, 6, &arrayInitReplacement(variable, value, line.items[index]));
            index += 6; // 公式のskip相当
            continue;
        }
        // 「変数 のすべての(要素|値)を 値 にする」
        if (matchesAt(line.items, index, &.{ .word_any, .{ .word = "すべて" }, element_word, value_token, .{ .word = "する" } })) {
            var variable = line.items[index];
            variable.josi = "";
            variable.raw_josi = "";
            var value = line.items[index + 3];
            value.josi = "";
            value.raw_josi = "";
            try line.replaceRange(allocator, index, 5, &arrayInitReplacement(variable, value, line.items[index]));
            continue;
        }
        // 「配列変数 変数 を初期化する」
        if (matchesAt(line.items, index, &.{ .{ .alt = &.{ .{ .word = "配列変数" }, .{ .word = "配列" } } }, .word_any, .{ .word = "初期化" } })) {
            var variable = line.items[index + 1];
            variable.josi = "";
            variable.raw_josi = "";
            const anchor = line.items[index];
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
            try line.replaceRange(allocator, index, 3, &replacement);
            continue;
        }
    }
}

fn arrayInitReplacement(variable: Token, value: Token, anchor: Token) [10]Token {
    return .{
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
}

/// 「…増」「…減」で終わる2文字以上の語を「…だけ 増|減」へ分割する。
fn splitGrowShrinkSuffix(line: *std.ArrayList(Token), allocator: std.mem.Allocator) !void {
    var index: usize = 0;
    while (index < line.items.len) : (index += 1) {
        const token = &line.items[index];
        if (isWordToken(token.*) and token.value.len > "増".len and
            (std.mem.endsWith(u8, token.value, "増") or std.mem.endsWith(u8, token.value, "減")))
        {
            const suffix = token.value[token.value.len - "増".len ..];
            token.value = token.value[0 .. token.value.len - "増".len];
            token.josi = "だけ";
            token.raw_josi = "だけ";
            try line.insert(allocator, index + 1, synthetic(.identifier, suffix, token.*));
        }
    }
}

/// 公式 DNCL_SIMPLES の単純置換を行末尾まで全トークンへ適用する。
fn applyDnclSimpleReplacements(tokens: []Token, is_v2: bool) void {
    for (tokens) |*token| {
        if (token.kind == .assign_arrow and std.mem.eql(u8, token.value, "←")) {
            token.kind = .equal;
            token.value = "=";
        } else if (token.kind == .divide and std.mem.eql(u8, token.value, "÷")) {
            token.kind = .integer_divide;
            token.value = "÷÷";
        } else if (token.kind == .left_brace) {
            token.kind = .left_bracket;
            token.value = "[";
        } else if (token.kind == .right_brace) {
            token.kind = .right_bracket;
            token.value = "]";
        } else if (is_v2 and isWordToken(token.*) and std.mem.eql(u8, token.value, "not")) {
            token.kind = .not;
            token.value = "!";
        } else if (isWordToken(token.*) and std.mem.eql(u8, token.value, "乱数")) {
            token.value = "乱数範囲";
        } else if (isWordToken(token.*) and std.mem.eql(u8, token.value, "表示")) {
            token.value = "連続表示";
        } else if (!is_v2 and isWordToken(token.*) and std.mem.eql(u8, token.value, "を実行")) {
            token.kind = .keyword_here_end;
            token.value = "ここまで";
        } else if (is_v2 and isWordToken(token.*) and std.mem.eql(u8, token.value, "と定義")) {
            token.kind = .keyword_here_end;
            token.value = "ここまで";
        }
    }
}

fn isWordValue(token: Token, value: []const u8) bool {
    return isWordToken(token) and std.mem.eql(u8, token.value, value);
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
    try std.testing.expect(stream.mode.dncl);
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

test "展開式の先頭BOMは本文として拒否する" {
    var stream = try lexer_mod.tokenize(std.testing.allocator, "A=1\n「{" ++ source_mod.utf8_bom ++ "A}」を表示\n");
    defer stream.deinit();
    try std.testing.expectError(error.UnexpectedCharacter, apply(&stream));
}
