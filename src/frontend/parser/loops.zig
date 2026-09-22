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
    if (arguments.len < 2) return self.fail(.invalid_control_statement, "『繰り返す』に開始値と終了値が必要です", keyword);
    var variable: []const u8 = "";
    var offset: usize = 0;
    if (arguments[0].kind == .word and std.mem.eql(u8, arguments[0].josi, "を")) {
        variable = arguments[0].value;
        offset = 1;
    }
    // 公式は繰り返し変数を省略した範囲繰り返しを『それ』へ束縛する
    // （繰り返し中に『それ』へ現在値が入り、『回数』は変化しない）。
    if (variable.len == 0) variable = "それ";
    if (arguments.len < offset + 2) return self.fail(.invalid_control_statement, "『繰り返す』に開始値と終了値が必要です", keyword);
    const increment = if (arguments.len > offset + 2) arguments[offset + 2] else try builder.nop(self, keyword);
    const body = try self.parseLoopBody("『繰り返す』文");
    const node = try builder.makeNodeWithChildren(self, .for_statement, start, try builder.copyChildren(self, &.{ arguments[offset], arguments[offset + 1], increment, body }));
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
    var index = arguments.items.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, arguments.items[index].josi, josi)) {
            return arguments.orderedRemove(index);
        }
    }
    return null;
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
