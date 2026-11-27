const std = @import("std");
const ast = @import("../ast.zig");
const token_mod = @import("../token.zig");
const parser_mod = @import("../parser.zig");
const builder = @import("builder.zig");
const expressions = @import("expressions.zig");
const helpers = @import("helpers.zig");

const Parser = parser_mod.Parser;
const ParseFailure = parser_mod.ParseFailure;
const Token = token_mod.Token;
const isConditionalJosi = helpers.isConditionalJosi;
const isNegativeConditionJosi = helpers.isNegativeConditionJosi;
const clearConditionalJosi = helpers.clearConditionalJosi;

/// 公式`yIFCond`相当の条件式解析。`もし`以降の条件を、演算子比較式・
/// C風呼出しに加えて、助詞`が`の比較形（`AがBならば`＝`A=B`）と
/// 助詞付きの命令呼出し（`Aが3以下ならば`＝`以下(A,3)`）でも受理する。
/// 公式のトークン列では「ならば」「でなければ」が独立トークンになるが、
/// lnakoの字句解析は直前の語へ助詞として付けるため、ここで吸収する。
pub fn parseIfCondition(self: *Parser) ParseFailure!*ast.Node {
    const first = try expressions.parseExpression(self, 0);
    if (isConditionalJosi(first.josi)) return finishCondition(self, first);
    if (self.identifierValue("ならば")) {
        _ = self.advance();
        try clearConditionalJosi(self.allocator, first);
        return first;
    }
    // 公式`yIFCond`は`A`の直後が`func`トークン（既知の命令名）なら、
    // `A`を引数にした呼出し`B(A)`を作る（`Aが奇数ならば`＝`奇数(A)`）。
    // 括弧付きの `AがINT(3)ならば` では、C風呼出しを等価比較の右辺にする。
    const next = self.peek();
    const next_is_predicate = next.kind == .identifier and self.isKnownCommandName(next.value) and
        (next.josi.len != 0 or self.peekAhead(1).kind != .left_paren);
    // チェック: `AがBならば` --- 「A = B」のとき。公式`yIFCond`は一度
    // 二番目の値を読み、条件助詞が付かなければ位置を戻して呼出し解決へ進む。
    if (std.mem.eql(u8, first.josi, "が") and !next_is_predicate) {
        const saved = self.index;
        const second = try expressions.parseExpression(self, 0);
        if (isConditionalJosi(second.josi)) {
            const result = try builder.makeNodeWithChildren(self, .binary_operator, self.peekPrevious(), try builder.copyChildren(self, &.{ first, second }));
            result.operator = if (isNegativeConditionJosi(second.josi)) "noteq" else "eq";
            result.josi = "";
            result.raw_josi = "";
            return result;
        }
        self.index = saved;
    }
    // チェック: `AがBならば` --- 「関数B(A)」のとき
    const result = try self.parseJosiCallExpression(first);
    if (isConditionalJosi(result.josi)) return finishCondition(self, result);
    if (self.identifierValue("ならば")) {
        _ = self.advance();
        try clearConditionalJosi(self.allocator, result);
        return result;
    }
    return self.fail(.invalid_control_statement, "『もし』文の条件末尾に『ならば』が必要です", self.peek());
}

/// 公式parserは「Aでなければ」を条件式Aの否定ノードとして保持する。
/// DNCLの「Aでないならば」はsyntax_transformで同じ助詞へ正規化されるため、
/// 条件式のjosiを消す前にnotへ包む必要がある。公式の字句解析は
/// 「でなければ」「しなければ」「なければ」をすべて否定の条件助詞にする。
pub fn finishCondition(self: *Parser, condition: *ast.Node) ParseFailure!*ast.Node {
    var result = condition;
    if (isNegativeConditionJosi(result.josi)) {
        result = try builder.unary(self, "not", result, self.peekPrevious());
    }
    try clearConditionalJosi(self.allocator, result);
    return result;
}

pub fn parseIf(self: *Parser) ParseFailure!*ast.Node {
    const start = self.advance();
    self.skipCommas();
    const condition = try self.parseIfCondition();
    return self.parseIfThen(start, condition);
}

/// 公式`yIfThen`相当。条件式を受けて真節・偽節を解析する。公式は「もし」を
/// 伴わない条件文（`Aが5と等しいならば`）も同じ`yIfThen`へ入る。
pub fn parseIfThen(self: *Parser, start: Token, condition: *ast.Node) ParseFailure!*ast.Node {
    var multiline = false;
    var true_block: *ast.Node = undefined;
    if (self.at(.eol)) {
        multiline = true;
        self.skipEols();
        true_block = try self.parseBlock(.{ .end = true, .else_branch = true });
    } else {
        true_block = try builder.wrapSingle(self, try self.parseStatement());
        // 公式`yIfThen`は真節のあとの改行を読み飛ばしてから『違えば』を
        // 調べる。lnakoのASTは改行を保持するため、直後に『違えば』がある
        // 場合だけ読み飛ばし、単文の真節でも偽節を繋げられるようにする
        // （`もし、A=1ならば、「OK」と表示。` の次行の `違えば、…`）。
        const after_true = self.index;
        self.skipEols();
        if (!self.at(.keyword_else)) self.index = after_true;
    }

    var false_block = try builder.emptyBlock(self, self.peek());
    if (self.at(.keyword_else)) {
        _ = self.advance();
        self.skipCommas();
        if (self.at(.eol)) {
            self.skipEols();
            false_block = try self.parseBlock(.{ .end = true });
        } else {
            // 公式parserは、複数行の真節でも違えば節が同じ行から
            // 始まる場合を「短文」として扱い、外側のここまでを要求しない。
            // これにより「そうでなくもし」を、内側のもし文だけが
            // インライン分岐として閉じる公式のASTに合わせる。
            multiline = false;
            false_block = try builder.wrapSingle(self, try self.parseStatement());
        }
    }
    if (multiline) try self.requireEnd("『もし』文");
    const result = try builder.makeNodeWithChildren(self, .if_statement, start, try builder.copyChildren(self, &.{ condition, true_block, false_block }));
    // 公式`yIfThen`の`if`ノードは助詞を持たない。「もし」省略形では開始
    // トークンが条件式の先頭語（`Aが…`）になるため、助詞を落とす。
    result.josi = "";
    result.raw_josi = "";
    return result;
}

pub fn parseSwitch(self: *Parser, start: Token, condition: *ast.Node) ParseFailure!*ast.Node {
    self.skipEols();
    var default_block = try builder.emptyBlock(self, start);
    var cases: std.ArrayList(*ast.Node) = .empty;
    var default_done = false;
    while (!self.at(.keyword_here_end) and !self.at(.eof)) {
        if (self.at(.keyword_else)) {
            _ = self.advance();
            self.skipCommas();
            default_block = try self.parseBlock(.{ .end = true });
            // 公式`ySwitch`は『違えば』とペアの『ここまで』を消費し、続けて
            // 『条件分岐』本体の『ここまで』も消費する。節を同じ行で閉じる形
            // （`違えば、…。ここまで。`）と、本体の終端を1つだけ書く形の
            // 両方を受理し、本体の終端を二重に要求しない。
            if (self.at(.keyword_here_end)) _ = self.advance();
            self.skipEols();
            if (self.at(.keyword_here_end)) _ = self.advance();
            default_done = true;
            break;
        }
        const case_value = try expressions.parseExpression(self, 0);
        if (!isConditionalJosi(case_value.josi)) return self.fail(.invalid_control_statement, "条件分岐の値に『ならば』が必要です", self.peekPrevious());
        try clearConditionalJosi(self.allocator, case_value);
        self.skipEols();
        const case_body = try self.parseBlock(.{ .end = true });
        try self.requireEnd("『条件分岐』の節");
        try cases.append(self.allocator, case_value);
        try cases.append(self.allocator, case_body);
        self.skipEols();
    }
    if (!default_done) try self.requireEnd("『条件分岐』文");
    var children: std.ArrayList(*ast.Node) = .empty;
    try children.append(self.allocator, condition);
    try children.append(self.allocator, default_block);
    try children.appendSlice(self.allocator, cases.items);
    const result = try builder.makeNodeWithChildren(self, .switch_statement, start, try children.toOwnedSlice(self.allocator));
    result.josi = "";
    return result;
}
