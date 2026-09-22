const std = @import("std");
const ast = @import("../ast.zig");
const token_mod = @import("../token.zig");
const parser_mod = @import("../parser.zig");
const builder = @import("builder.zig");

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
/// 間に引数があっても呼出しはループの引数になる。
/// 連文呼出し(『して』等)と条件『間』・回数『回』は従来どおり直後の
/// ループ語のときだけ引数とし、間に引数があれば先行文とする。
pub fn atForLoopKeywordAhead(self: *Parser, sequence_josi: bool) bool {
    var offset: usize = 0;
    while (true) : (offset += 1) {
        if (sequence_josi and offset > 0) return false;
        const token = self.peekAhead(offset);
        switch (token.kind) {
            .keyword_repeat, .keyword_foreach => return true,
            .keyword_repeat_while, .keyword_repeat_count => return offset == 0,
            .identifier => {
                // 『増』『減』+繰返の組もループ開始。命令名に解決できる識別子は境界。
                if ((std.mem.eql(u8, token.value, "増") or std.mem.eql(u8, token.value, "減")) and
                    self.peekAhead(offset + 1).kind == .keyword_repeat) return true;
                if (token.josi.len > 0 and !self.isKnownCommandName(token.value)) continue;
                return false;
            },
            .number, .bigint, .string, .string_template, .comma, .left_paren, .left_bracket, .left_brace, .minus => continue,
            else => return false,
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
    if (args.items.len > 0)
        return self.fail(.invalid_control_statement, "『繰り返す』文に解決できない引数があります", keyword);
    const is_range_object = to_arg != null and to_arg.?.kind == .function_call and
        std.mem.eql(u8, to_arg.?.name, "範囲");
    if (to_arg == null or (from_arg == null and !is_range_object))
        return self.fail(.invalid_control_statement, "『繰り返す』に開始値と終了値が必要です", keyword);
    // 公式は繰り返し変数を省略した範囲繰り返しを『それ』へ束縛する
    // （繰り返し中に『それ』へ現在値が入り、『回数』は変化しない）。
    if (variable.len == 0) variable = "それ";
    var from_node = from_arg orelse try builder.nop(self, keyword);
    var to_node = to_arg.?;
    if (is_range_object) {
        // 『AからBの範囲を繰り返す』『NでA…Bを繰り返す』(#1704互換):
        // 範囲オブジェクトの『先頭』『末尾』が開始値・終了値になる。
        from_node = try builder.reference(self, .array_value_reference, to_node, &.{try stringNode(self, "先頭", keyword)}, keyword);
        to_node = try builder.reference(self, .array_value_reference, try copyAst(self, to_node), &.{try stringNode(self, "末尾", keyword)}, keyword);
    }
    const increment = increment_arg orelse try builder.nop(self, keyword);
    const body = try self.parseLoopBody("『繰り返す』文");
    const node = try builder.makeNodeWithChildren(self, .for_statement, start, try builder.copyChildren(self, &.{ from_node, to_node, increment, body }));
    node.name = variable;
    node.josi = "";
    node.loop_direction = direction;
    if (std.mem.eql(u8, keyword.value, "増繰返")) node.loop_direction = .up;
    if (std.mem.eql(u8, keyword.value, "減繰返")) node.loop_direction = .down;
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

/// 範囲オブジェクトの両端参照用にASTを複製する（同一ノードの二重参照を避ける）。
fn copyAst(self: *Parser, node: *ast.Node) ParseFailure!*ast.Node {
    const copy = try self.allocator.create(ast.Node);
    copy.* = node.*;
    if (node.children.len > 0) {
        const children = try self.allocator.alloc(*ast.Node, node.children.len);
        for (node.children, 0..) |child, i| children[i] = try copyAst(self, child);
        copy.children = children;
    }
    return copy;
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
