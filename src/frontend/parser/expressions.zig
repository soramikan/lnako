const std = @import("std");
const ast = @import("../ast.zig");
const token_mod = @import("../token.zig");
const parser_mod = @import("../parser.zig");
const builder = @import("builder.zig");
const helpers = @import("helpers.zig");

const Parser = parser_mod.Parser;
const ParseFailure = parser_mod.ParseFailure;
const Token = token_mod.Token;

pub fn parseExpression(self: *Parser, minimum_precedence: u8) ParseFailure!*ast.Node {
    return parseExpressionWithContext(self, minimum_precedence, false);
}

pub fn parseExpressionWithContext(self: *Parser, minimum_precedence: u8, allow_negative_number_literal: bool) ParseFailure!*ast.Node {
    // 演算子の優先順位による再帰も含め、式の入れ子はここで数える。
    try self.enterNesting();
    defer self.leaveNesting();
    const left = try parseUnary(self, allow_negative_number_literal);
    return parseOperatorTail(self, left, minimum_precedence);
}

/// 式の先頭`left`に続く演算子と右辺を、優先順位に従って読む。
/// `parseDelimitedSequence`が命令呼出しの直後に続く演算子を取り込むためにも使う
/// （公式`yCall`が呼出し結果へ`yGetArgOperator`を適用するのに相当）。
fn parseOperatorTail(self: *Parser, left: *ast.Node, minimum_precedence: u8) ParseFailure!*ast.Node {
    var result = left;
    while (helpers.operatorInfo(self.peek().kind)) |info| {
        if (info.precedence < minimum_precedence) break;
        const operator_token = self.advance();
        const next_precedence = info.precedence + @intFromBool(!info.right_associative);
        const right = try parseExpressionWithContext(self, next_precedence, true);
        if (operator_token.kind == .range) {
            const range = try builder.makeNodeWithChildren(self, .function_call, operator_token, try builder.copyChildren(self, &.{ result, right }));
            range.name = "範囲";
            range.josi = right.josi;
            result = range;
        } else {
            const binary = try builder.makeNodeWithChildren(self, .binary_operator, operator_token, try builder.copyChildren(self, &.{ result, right }));
            binary.operator = info.name;
            binary.josi = right.josi;
            binary.raw_josi = right.raw_josi;
            result = binary;
        }
    }
    if (minimum_precedence == 0 and result.kind == .binary_operator) helpers.propagateOperatorJosi(result, result.josi);
    return result;
}

/// 区切り式（括弧・C風呼出し引数・添字・配列/辞書リテラルの要素）の内側で、
/// 公式`yCalc`1回分に相当する値の並びを読む。先頭の値が助詞を持てば
/// `collectJosiSequence`で命令呼出しまで読み、解決後に残ったノード列を
/// そのまま返す（公式でスタックに残る値に相当）。助詞を持たない値は
/// 単独で返す（公式`yCalcMain`の早期return相当）。末尾の値に続く演算子は
/// 式の一部として取り込む（`1を2で割+3`＝`割(1,2)+3`）。
pub fn parseDelimitedSequence(self: *Parser) ParseFailure![]*ast.Node {
    const first = try parseExpression(self, 0);
    if (first.josi.len == 0) {
        const single = try self.allocator.alloc(*ast.Node, 1);
        single[0] = first;
        return single;
    }
    const items = try self.collectJosiSequence(first);
    items[items.len - 1] = try parseOperatorTail(self, items[items.len - 1], 0);
    return items;
}

pub fn parseUnary(self: *Parser, allow_negative_number_literal: bool) ParseFailure!*ast.Node {
    if (self.at(.plus)) return self.fail(.unexpected_token, "単項『+』は使用できません", self.peek());
    if (self.delimited_expression_depth > 0 and !allow_negative_number_literal and self.at(.minus) and self.peekAhead(1).kind == .bigint) {
        return self.fail(.unexpected_token, "括弧・配列・辞書の内側では負のBigIntリテラルを直接使用できません", self.peek());
    }
    if (self.at(.not) or self.at(.minus)) {
        // 単項演算子の連鎖は`parseUnary`自身が再帰するため、ここでも数える。
        try self.enterNesting();
        defer self.leaveNesting();
        const operator_token = self.advance();
        const operand = try parseUnary(self, allow_negative_number_literal);
        if (operator_token.kind == .minus) {
            const can_fold_number = self.delimited_expression_depth == 0 or allow_negative_number_literal;
            if (((operand.kind == .number and can_fold_number) or operand.kind == .bigint) and !operand.grouped) {
                operand.value = if (std.mem.startsWith(u8, operand.value, "-"))
                    try self.allocator.dupe(u8, operand.value[1..])
                else
                    try std.fmt.allocPrint(self.allocator, "-{s}", .{operand.value});
                if (operand.kind == .number) operand.number_value = -(operand.number_value orelse 0);
                operand.span = operator_token.span;
                return operand;
            }
            const minus_one = try builder.makeNode(self, .number, operator_token);
            minus_one.value = "-1";
            minus_one.number_value = -1;
            const binary = try builder.makeNodeWithChildren(self, .binary_operator, operator_token, try builder.copyChildren(self, &.{ minus_one, operand }));
            binary.operator = "*";
            binary.josi = operand.josi;
            return binary;
        }
        return builder.unary(self, helpers.operatorName(operator_token.kind), operand, operator_token);
    }
    return parsePostfix(
        self,
    );
}

pub fn parsePostfix(self: *Parser) ParseFailure!*ast.Node {
    var value = try parsePrimary(
        self,
    );
    while (true) {
        if (self.at(.left_paren) and value.kind == .word and value.josi.len == 0) {
            const open = self.advance();
            self.delimited_expression_depth += 1;
            defer self.delimited_expression_depth -= 1;
            var arguments: std.ArrayList(*ast.Node) = .empty;
            // 公式`yGetArgParen`相当: 各引数を`yCalc`相当の区切り式単位で読み、
            // 助詞付きの命令呼出しも引数として受理する（`割(1を2で)`）。
            // カンマが無くても値が続く限り引数として読む（`加算(1 2)`）。
            while (!self.at(.right_paren) and !self.at(.eof)) {
                try arguments.appendSlice(self.allocator, try parseDelimitedSequence(self));
                if (self.at(.comma)) {
                    _ = self.advance();
                    continue;
                }
                if (!helpers.canStartExpression(self.peek().kind)) break;
            }
            const close = try self.require(.right_paren, "C風関数呼び出しを閉じる『)』が必要です");
            const call = try builder.makeNodeWithChildren(self, .function_call, open, try arguments.toOwnedSlice(self.allocator));
            call.name = value.value;
            call.josi = close.josi;
            call.raw_josi = close.raw_josi;
            call.is_c_style_call = true;
            value = call;
            continue;
        }
        if (self.at(.left_paren) and value.kind == .function_call) {
            const open = self.advance();
            self.delimited_expression_depth += 1;
            defer self.delimited_expression_depth -= 1;
            var arguments: std.ArrayList(*ast.Node) = .empty;
            try arguments.append(self.allocator, value);
            while (!self.at(.right_paren) and !self.at(.eof)) {
                try arguments.appendSlice(self.allocator, try parseDelimitedSequence(self));
                if (self.at(.comma)) {
                    _ = self.advance();
                    continue;
                }
                if (!helpers.canStartExpression(self.peek().kind)) break;
            }
            const close = try self.require(.right_paren, "関数値呼び出しを閉じる『)』が必要です");
            value = try builder.makeNodeWithChildren(self, .call_value, open, try arguments.toOwnedSlice(self.allocator));
            value.josi = close.josi;
            continue;
        }
        if (self.at(.at)) {
            const token = self.advance();
            // 公式はprop[i]形（プロパティ参照への添字適用）を受理しない
            if (value.kind == .property_reference) return self.fail(.invalid_array_access, "配列アクセスで指定ミス", token);
            // 公式のcheckArrayIndexはレシーバの種類を問わず添字へ適用される
            const index = try builder.dnclArrayIndex(self, try parsePrimary(
                self,
            ));
            const reference_kind: ast.Kind = if (helpers.isVariableReference(value.kind)) .array_reference else .array_value_reference;
            value = try builder.reference(self, reference_kind, value, &.{index}, token);
            continue;
        }
        if (self.at(.left_bracket) and value.josi.len == 0) {
            const open = self.advance();
            if (value.kind == .property_reference) return self.fail(.invalid_array_access, "配列アクセスで指定ミス", open);
            self.delimited_expression_depth += 1;
            defer self.delimited_expression_depth -= 1;
            var indexes: std.ArrayList(*ast.Node) = .empty;
            while (!self.at(.right_bracket) and !self.at(.eof)) {
                const items = try parseDelimitedSequence(self);
                // 添字は単一の値に解決される必要がある（公式`yCalc`の結果相当）。
                if (items.len != 1) return self.fail(.unexpected_token, "命令呼び出しを構成できません", self.peek());
                const index = items[0];
                // 公式のfunc tokenはカンマ直前では値として受理されない。
                // 関数名への解決は意味解析で行うため、ここでは裸の単語だけ記録する。
                if (index.kind == .word and index.josi.len == 0 and !index.grouped and self.at(.comma)) index.bare_index_word = true;
                try indexes.append(self.allocator, try builder.dnclArrayIndex(self, index));
                if (indexes.items.len > 3) return self.fail(.invalid_array_access, "配列アクセスで指定ミス", open);
                if (!self.at(.comma)) break;
                _ = self.advance();
            }
            const close = try self.require(.right_bracket, "配列参照を閉じる『]』が必要です");
            // 公式のcheckArrayIndex/checkArrayReverseはレシーバの種類を問わず適用される
            builder.dnclReverseIndexes(self, indexes.items);
            const reference_kind: ast.Kind = if (helpers.isVariableReference(value.kind)) .array_reference else .array_value_reference;
            value = try builder.reference(self, reference_kind, value, try indexes.toOwnedSlice(self.allocator), open);
            value.josi = close.josi;
            value.raw_josi = close.raw_josi;
            continue;
        }
        if (self.at(.property)) {
            const token = self.advance();
            const property_token = self.advance();
            if (property_token.kind != .identifier and property_token.kind != .string) return self.fail(.expected_name, "『$』の後ろにプロパティ名が必要です", property_token);
            const property = try builder.valueNode(self, .string, property_token);
            const reference_kind: ast.Kind = if (helpers.isVariableReference(value.kind)) .property_reference else .array_value_reference;
            value = try builder.reference(self, reference_kind, value, &.{property}, token);
            value.josi = property_token.josi;
            continue;
        }
        break;
    }
    return value;
}

pub fn parsePrimary(self: *Parser) ParseFailure!*ast.Node {
    const token = self.advance();
    return switch (token.kind) {
        .number => builder.valueNode(self, .number, token),
        .bigint => builder.valueNode(self, .bigint, token),
        .string => builder.valueNode(self, .string, token),
        .string_template => builder.valueNode(self, .string_template, token),
        .identifier => parseIdentifierValue(self, token),
        .function_ref => blk: {
            const node = try builder.makeNode(self, .function_pointer, token);
            node.name = token.value;
            break :blk node;
        },
        .left_paren => blk: {
            self.delimited_expression_depth += 1;
            defer self.delimited_expression_depth -= 1;
            // 公式`yValueKakko`は括弧内を`yCalc`で解析し、スタックに残った
            // 末尾の値を括弧の値とする。助詞付きの命令呼出しも受理する
            // （`(Aが3以下)`、`(1を2で)`は末尾の`2`が値になる）。
            const items = try parseDelimitedSequence(self);
            if (!self.at(.right_paren)) return self.fail(.expected_token, "式を閉じる『)』が必要です", token);
            const close = self.advance();
            const value = items[items.len - 1];
            value.josi = close.josi;
            value.raw_josi = close.raw_josi;
            value.grouped = true;
            break :blk value;
        },
        .left_bracket => parseArrayAfterOpen(self, token),
        .left_brace => parseObjectAfterOpen(self, token),
        .def_func => blk: {
            self.index -= 1;
            break :blk self.parseAnonymousFunction();
        },
        else => self.fail(.expected_expression, "値または式が必要です", token),
    };
}

pub fn parseIdentifierValue(self: *Parser, token: Token) ParseFailure!*ast.Node {
    if (std.mem.eql(u8, token.value, "真") or std.mem.eql(u8, token.value, "はい") or std.mem.eql(u8, token.value, "オン")) {
        const node = try builder.valueNode(self, .boolean, token);
        node.number_value = 1;
        return node;
    }
    if (std.mem.eql(u8, token.value, "偽") or std.mem.eql(u8, token.value, "いいえ") or std.mem.eql(u8, token.value, "オフ")) {
        const node = try builder.valueNode(self, .boolean, token);
        node.number_value = 0;
        return node;
    }
    if (std.ascii.eqlIgnoreCase(token.value, "null")) return builder.valueNode(self, .null_value, token);
    return builder.valueNode(self, .word, token);
}

pub fn parseArrayLiteral(self: *Parser) ParseFailure!*ast.Node {
    return parseArrayAfterOpen(self, self.advance());
}

pub fn parseArrayAfterOpen(self: *Parser, open: Token) ParseFailure!*ast.Node {
    self.delimited_expression_depth += 1;
    defer self.delimited_expression_depth -= 1;
    var values: std.ArrayList(*ast.Node) = .empty;
    while (!self.at(.right_bracket) and !self.at(.eof)) {
        if (self.at(.eol) or self.at(.comma)) {
            _ = self.advance();
            continue;
        }
        // 公式`yJSONArrayValue`は各要素を`yCalc`で読むため、助詞付きの
        // 命令呼出しも要素として受理する（`[Aの要素数]`）。
        const items = try parseDelimitedSequence(self);
        if (items.len != 1) return self.fail(.unexpected_token, "命令呼び出しを構成できません", self.peek());
        try values.append(self.allocator, items[0]);
        if (self.at(.comma)) _ = self.advance();
    }
    if (!self.at(.right_bracket)) return self.fail(.expected_token, "配列リテラルを閉じる『]』が必要です", open);
    const close = self.advance();
    const node = try builder.makeNodeWithChildren(self, .array_literal, open, try values.toOwnedSlice(self.allocator));
    node.josi = close.josi;
    node.raw_josi = close.raw_josi;
    return node;
}

pub fn parseObjectAfterOpen(self: *Parser, open: Token) ParseFailure!*ast.Node {
    self.delimited_expression_depth += 1;
    defer self.delimited_expression_depth -= 1;
    var values: std.ArrayList(*ast.Node) = .empty;
    while (!self.at(.right_brace) and !self.at(.eof)) {
        if (self.at(.eol) or self.at(.comma)) {
            _ = self.advance();
            continue;
        }
        const key_token = self.advance();
        if (key_token.kind != .identifier and key_token.kind != .string) {
            return self.fail(.expected_name, "辞書のキーが必要です", key_token);
        }
        const key = try builder.valueNode(self, .string, key_token);
        try values.append(self.allocator, key);
        if (self.at(.colon)) {
            _ = self.advance();
            // 公式`yJSONObjectValue`は値を`yCalc`で読むため、助詞付きの
            // 命令呼出しも値として受理する（`{a: Aの要素数}`）。
            const items = try parseDelimitedSequence(self);
            if (items.len != 1) return self.fail(.unexpected_token, "命令呼び出しを構成できません", self.peek());
            try values.append(self.allocator, items[0]);
        } else {
            const value_kind: ast.Kind = if (key_token.kind == .string) .string else .word;
            try values.append(self.allocator, try builder.valueNode(self, value_kind, key_token));
        }
        if (self.at(.comma)) _ = self.advance();
    }
    if (!self.at(.right_brace)) return self.fail(.expected_token, "辞書リテラルを閉じる『}』が必要です", open);
    const close = self.advance();
    const node = try builder.makeNodeWithChildren(self, .object_literal, open, try values.toOwnedSlice(self.allocator));
    node.josi = close.josi;
    node.raw_josi = close.raw_josi;
    return node;
}
