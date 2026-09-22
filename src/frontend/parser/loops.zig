const std = @import("std");
const ast = @import("../ast.zig");
const token_mod = @import("../token.zig");
const parser_mod = @import("../parser.zig");
const builder = @import("builder.zig");
const helpers = @import("helpers.zig");

const Parser = parser_mod.Parser;
const ParseFailure = parser_mod.ParseFailure;
const Token = token_mod.Token;

pub fn atLoopKeyword(self: *Parser) bool {
    return self.at(.keyword_repeat_while) or self.at(.keyword_repeat_count) or
        self.at(.keyword_repeat) or self.at(.keyword_foreach);
}

/// `offset`先のトークンがループの語かどうか。
pub fn atLoopKeywordAhead(self: *Parser, offset: usize) bool {
    const token = self.peekAhead(offset);
    return token.kind == .keyword_repeat_while or token.kind == .keyword_repeat_count or
        token.kind == .keyword_repeat or token.kind == .keyword_foreach;
}

/// 助詞付き呼出しの直後が、引数列を挟んでループの語へ続くか。
/// 公式は呼出し結果をスタックに残すため、`範囲を2ずつ増繰返す`のように
/// 間に引数があっても呼出しはループの引数になる。`NでAが5以下の間`や
/// `Nで3回繰り返す`の『Nで』のように、『間』『回』の前にも引数を
/// 挟み得る（残った引数は公式の未解決単語と同じく構文エラーになる）。
/// 連文呼出し(『して』等)は従来どおり直後のループ語のときだけ引数とし、
/// 間に引数があれば先行文とする。
pub fn atForLoopKeywordAhead(self: *Parser, sequence_josi: bool) bool {
    var offset: usize = 0;
    var depth: usize = 0;
    while (true) : (offset += 1) {
        if (sequence_josi and offset > 0) return false;
        const token = self.peekAhead(offset);
        // 括弧内は対応する閉じ区切りまで任意の式を読み飛ばす
        // （`範囲を(1+1)ずつ増繰返す`や`範囲をF(2)ずつ増繰返す`）。
        if (depth > 0) {
            switch (token.kind) {
                .left_paren, .left_bracket, .left_brace => depth += 1,
                .right_paren, .right_bracket, .right_brace => depth -= 1,
                .eol, .eof => return false,
                else => {},
            }
            continue;
        }
        switch (token.kind) {
            .keyword_repeat, .keyword_foreach, .keyword_repeat_while, .keyword_repeat_count => return true,
            .left_paren, .left_bracket, .left_brace => depth += 1,
            .identifier => {
                // 『増』『減』+繰返の組もループ開始。命令名に解決できる識別子は境界。
                if ((std.mem.eql(u8, token.value, "増") or std.mem.eql(u8, token.value, "減")) and
                    self.peekAhead(offset + 1).kind == .keyword_repeat) return true;
                if (token.josi.len > 0) {
                    if (self.isKnownCommandName(token.value)) return false;
                    continue;
                }
                // 助詞なし識別子でも、呼出し括弧や式演算子で続く場合は引数式の一部
                // （`範囲をF(1)ずつ増繰返す`、`範囲を1+2ずつ増繰返す`）。
                const next = self.peekAhead(offset + 1).kind;
                if (next == .left_paren or helpers.operatorInfo(next) != null) continue;
                return false;
            },
            else => {
                // 式を構成するトークン（リテラル・演算子・区切りカンマ）は引数式として読み飛ばす。
                if (helpers.canStartExpression(token.kind) or helpers.operatorInfo(token.kind) != null or
                    token.kind == .comma) continue;
                return false;
            },
        }
    }
}

pub fn parseRepeatTimes(self: *Parser, start: Token, count: *ast.Node) ParseFailure!*ast.Node {
    if (self.at(.comma)) _ = self.advance();
    if (self.at(.keyword_repeat)) _ = self.advance();
    const body = try self.parseLoopBody("『回』繰り返し");
    return builder.makeNodeWithChildren(self, .repeat_times, start, try builder.copyChildren(self, &.{ count, body }));
}

pub fn parseWhile(self: *Parser, start: Token, condition: *ast.Node) ParseFailure!*ast.Node {
    self.skipCommas();
    if (self.at(.keyword_repeat)) _ = self.advance();
    const body = try self.parseLoopBody("『間』繰り返し");
    const result = try builder.makeNodeWithChildren(self, .while_statement, start, try builder.copyChildren(self, &.{ condition, body }));
    result.josi = "";
    result.raw_josi = "";
    return result;
}

pub fn parseFor(self: *Parser, start: Token, arguments: []const *ast.Node) ParseFailure!*ast.Node {
    var direction: ast.LoopDirection = .automatic;
    if (self.identifierValue("増") or self.identifierValue("減")) {
        direction = if (self.identifierValue("増")) .up else .down;
        _ = self.advance();
    }
    const keyword = self.advance();
    // 公式`yFor`相当: 助詞で引数を末尾側から取り出す。
    // 『ずつ』(増減繰返のみ)→『まで|を』(終了値)→『から』(開始値)→『を|で』(繰り返し変数)。
    var args: std.ArrayList(*ast.Node) = .empty;
    try args.appendSlice(self.allocator, arguments);
    const incdec = direction != .automatic or
        std.mem.eql(u8, keyword.value, "増繰返") or std.mem.eql(u8, keyword.value, "減繰返");
    const increment_arg = if (incdec) popJosiArgument(&args, "ずつ") else null;
    const to_arg = popJosiArgumentAny(&args, &.{ "まで", "を" });
    const from_arg = popJosiArgument(&args, "から");
    var variable_arg = popJosiArgumentAny(&args, &.{ "を", "で" });
    if (variable_arg == null and to_arg != null and to_arg.?.kind == .function_call and
        std.mem.eql(u8, to_arg.?.name, "範囲") and to_arg.?.children.len > 0)
    {
        // 『NでAからBの範囲を繰り返す』: 範囲の助詞仕様は『から』『の』『までの』のみ
        // なので、先頭引数の『を』『で』助詞の語は繰り返し変数として救い出す。
        const first = to_arg.?.children[0];
        if (first.kind == .word and (std.mem.eql(u8, first.josi, "で") or std.mem.eql(u8, first.josi, "を"))) {
            variable_arg = first;
            to_arg.?.children = to_arg.?.children[1..];
        }
    }
    var variable: []const u8 = "";
    if (variable_arg) |arg| {
        // 公式は変数位置が単語でなければ構文エラーにする
        if (arg.kind != .word)
            return self.fail(.invalid_control_statement, "『(変数名)をAからBまで繰り返す』で指定してください", keyword);
        variable = arg.value;
    }
    // 取り出せなかった引数は公式でも未解決の単語として構文エラーになる
    if (args.items.len > 0) try self.failUnresolvedWords(args.items);
    const is_range_object = to_arg != null and to_arg.?.kind == .function_call and
        std.mem.eql(u8, to_arg.?.name, "範囲");
    if (to_arg == null or (from_arg == null and !is_range_object))
        return self.fail(.invalid_control_statement, "『繰り返す』に開始値と終了値が必要です", keyword);
    // 公式は繰り返し変数を省略した範囲繰り返しを『それ』へ束縛する
    // （繰り返し中に『それ』へ現在値が入り、『回数』は変化しない）。
    if (variable.len == 0) variable = "それ";
    var from_node = from_arg orelse try builder.nop(self, keyword);
    var to_node = to_arg.?;
    var range_temp_assign: ?*ast.Node = null;
    if (is_range_object) {
        // 『AからBの範囲を繰り返す』『NでA…Bを繰り返す』(#1704互換):
        // 範囲オブジェクトの『先頭』『末尾』が開始値・終了値になる。
        // 公式convForは範囲オブジェクトを$nako_tempへ一度だけ評価するため、
        // AST複製による二重評価（副作用の二重発生）を避け、一時変数への
        // 代入文をループの前へ置く。名前に『}』と『》』を両方含めることで
        // 拡張単語（${…}・《…》）でも記述できない名前とし、同スコープの
        // 利用者変数・定数を決して上書きしない。
        const temp_name = "繰り返し範囲$一時値}》";
        const assign = try builder.makeNodeWithChildren(self, .assignment, start, try builder.copyChildren(self, &.{to_node}));
        assign.name = temp_name;
        assign.josi = "";
        range_temp_assign = assign;
        const head_base = try builder.makeNode(self, .word, keyword);
        head_base.value = temp_name;
        head_base.josi = "";
        head_base.raw_josi = "";
        const tail_base = try builder.makeNode(self, .word, keyword);
        tail_base.value = temp_name;
        tail_base.josi = "";
        tail_base.raw_josi = "";
        from_node = try builder.reference(self, .array_value_reference, head_base, &.{try stringNode(self, "先頭", keyword)}, keyword);
        to_node = try builder.reference(self, .array_value_reference, tail_base, &.{try stringNode(self, "末尾", keyword)}, keyword);
    }
    const increment = increment_arg orelse try builder.nop(self, keyword);
    const body = try self.parseLoopBody("『繰り返す』文");
    const node = try builder.makeNodeWithChildren(self, .for_statement, start, try builder.copyChildren(self, &.{ from_node, to_node, increment, body }));
    node.name = variable;
    node.josi = "";
    node.loop_direction = direction;
    if (std.mem.eql(u8, keyword.value, "増繰返")) node.loop_direction = .up;
    if (std.mem.eql(u8, keyword.value, "減繰返")) node.loop_direction = .down;
    if (range_temp_assign) |assign|
        return builder.makeNodeWithChildren(self, .block, start, try builder.copyChildren(self, &.{ assign, node }));
    return node;
}

/// 公式`popStack`相当: 引数リストの末尾から指定助詞を持つ値を取り出す。
/// 該当する助詞が見つからなければnullを返す。
pub fn popJosiArgument(arguments: *std.ArrayList(*ast.Node), josi: []const u8) ?*ast.Node {
    return popJosiArgumentAny(arguments, &.{josi});
}

/// `popJosiArgument`の複数助詞版。いずれかの助詞を持つ末尾側の値を取り出す。
pub fn popJosiArgumentAny(arguments: *std.ArrayList(*ast.Node), josi_list: []const []const u8) ?*ast.Node {
    var index = arguments.items.len;
    while (index > 0) {
        index -= 1;
        const josi = arguments.items[index].josi;
        for (josi_list) |wanted| {
            if (std.mem.eql(u8, josi, wanted)) return arguments.orderedRemove(index);
        }
    }
    return null;
}

/// 『先頭』『末尾』キー参照用の文字列リテラルノードを作る。
fn stringNode(self: *Parser, text: []const u8, token: Token) ParseFailure!*ast.Node {
    const node = try builder.makeNode(self, .string, token);
    node.value = text;
    node.josi = "";
    node.raw_josi = "";
    return node;
}

pub fn parseForeach(self: *Parser, start: Token, collection: *ast.Node, variable: []const u8) ParseFailure!*ast.Node {
    const body = try self.parseLoopBody("『反復』文");
    const result = try builder.makeNodeWithChildren(self, .foreach_statement, start, try builder.copyChildren(self, &.{ collection, body }));
    result.name = variable;
    result.josi = "";
    result.raw_josi = "";
    return result;
}

pub fn parseLoopBody(self: *Parser, description: []const u8) ParseFailure!*ast.Node {
    self.skipCommas();
    if (self.at(.keyword_here_from)) _ = self.advance();
    if (self.at(.eol)) {
        self.skipEols();
        const body = try self.parseBlock(.{ .end = true });
        try self.requireEnd(description);
        return body;
    }
    return builder.wrapSingle(self, try self.parseStatement());
}
