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
    var left = try parseUnary(self, allow_negative_number_literal);
    while (helpers.operatorInfo(self.peek().kind)) |info| {
        if (info.precedence < minimum_precedence) break;
        const operator_token = self.advance();
        const next_precedence = info.precedence + @intFromBool(!info.right_associative);
        const right = try parseExpressionWithContext(self, next_precedence, true);
        if (operator_token.kind == .range) {
            const range = try builder.makeNodeWithChildren(self, .function_call, operator_token, try builder.copyChildren(self, &.{ left, right }));
            range.name = "範囲";
            range.josi = right.josi;
            left = range;
        } else {
            const binary = try builder.makeNodeWithChildren(self, .binary_operator, operator_token, try builder.copyChildren(self, &.{ left, right }));
            binary.operator = info.name;
            binary.josi = right.josi;
            binary.raw_josi = right.raw_josi;
            left = binary;
        }
    }
    if (minimum_precedence == 0 and left.kind == .binary_operator) helpers.propagateOperatorJosi(left, left.josi);
    return left;
}

pub fn parseUnary(self: *Parser, allow_negative_number_literal: bool) ParseFailure!*ast.Node {
    // 式の再帰下降はすべてここを通るため、入れ子の上限はここで数える。
    try self.enterNesting();
    defer self.leaveNesting();
    if (self.at(.plus)) return self.fail(.unexpected_token, "単項『+』は使用できません", self.peek());
    if (self.delimited_expression_depth > 0 and !allow_negative_number_literal and self.at(.minus) and self.peekAhead(1).kind == .bigint) {
        return self.fail(.unexpected_token, "括弧・配列・辞書の内側では負のBigIntリテラルを直接使用できません", self.peek());
    }
    if (self.at(.not) or self.at(.minus)) {
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
            while (!self.at(.right_paren) and !self.at(.eof)) {
                try arguments.append(self.allocator, try parseExpression(self, 0));
                if (!self.at(.comma)) break;
                _ = self.advance();
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
                try arguments.append(self.allocator, try parseExpression(self, 0));
                if (!self.at(.comma)) break;
                _ = self.advance();
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
                const index = try parseExpression(self, 0);
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
            const value = try parseExpression(self, 0);
            if (!self.at(.right_paren)) return self.fail(.expected_token, "式を閉じる『)』が必要です", token);
            const close = self.advance();
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
        try values.append(self.allocator, try parseExpression(self, 0));
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
            try values.append(self.allocator, try parseExpression(self, 0));
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
