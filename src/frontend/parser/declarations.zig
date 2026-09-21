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

const canStartExpression = helpers.canStartExpression;

/// 公式yLet/ySadameruの変数属性 `{公開}`/`{非公開}`/`{エクスポート}`。
pub const VariableAttribute = struct {
    /// `{` `word` `}` を属性として消費したか。公式は属性の後ろに『=』を
    /// 必須にするため、未知の属性名でも消費した事実だけは区別する。
    present: bool = false,
    /// `公開`/`非公開`/`エクスポート` なら公開設定。未知の属性名は null。
    is_export: ?bool = null,
};

pub fn parseDeclaration(self: *Parser, is_const: bool) ParseFailure!*ast.Node {
    const start = self.advance();
    if (self.at(.left_bracket)) {
        const names = try expressions.parseArrayLiteral(
            self,
        );
        _ = try self.require(.equal, "変数一覧の後ろに『=』が必要です");
        const value = try self.parseCallExpression();
        const node = try builder.makeNodeWithChildren(self, .variable_list_definition, start, try builder.copyChildren(self, &.{value}));
        node.arguments = try builder.namesToArguments(self, names.children);
        node.is_const = is_const;
        node.is_export = self.export_default;
        return node;
    }
    const name = try self.require(.identifier, "変数名が必要です");
    const has_attribute = self.at(.left_brace);
    const is_export = try self.parseVariableAttribute(self.export_default);
    // 公式は`変数 A`の初期値省略を許し、その値は0になる。属性付きの
    // 宣言と`定数`は`=`を必須にする。
    var value = try builder.omittedValue(self, name);
    if (self.at(.equal)) {
        _ = self.advance();
        // 公式は`定数 名=`の空の右辺をnop（=0）に落とす。属性付きの宣言と
        // `変数 名=`は式が必須（`yCalc() || yNop()`は定数の形だけ）。
        if (!is_const or has_attribute or canStartDeclarationValue(self)) {
            value = try self.parseCallExpression();
        }
    } else if (is_const or has_attribute) {
        return self.fail(.expected_token, "変数宣言に『=』が必要です", self.peek());
    }
    const node = try builder.makeNodeWithChildren(self, .variable_definition, start, try builder.copyChildren(self, &.{value}));
    node.name = name.value;
    node.is_const = is_const;
    node.is_export = is_export;
    return node;
}

/// 変数・定数の`{公開}`/`{非公開}`属性を読み、公開可否を返す。
/// 属性が無ければ`default`をそのまま返す。
pub fn parseVariableAttribute(self: *Parser, default: bool) ParseFailure!bool {
    if (!self.at(.left_brace)) return default;
    _ = self.advance();
    const attribute = try self.require(.identifier, "変数属性が必要です");
    _ = try self.require(.right_brace, "変数属性を閉じる『}』が必要です");
    if (std.mem.eql(u8, attribute.value, "非公開")) return false;
    if (std.mem.eql(u8, attribute.value, "公開") or std.mem.eql(u8, attribute.value, "エクスポート")) return true;
    return default;
}

/// 宣言の右辺を開始できるか。公式`yCalc()`は通常の式に加えて
/// 匿名関数（`関数()`）も右辺として受理するため、`parseCallExpression`
/// と同じく `.def_func` を式開始として扱う。
fn canStartDeclarationValue(self: *Parser) bool {
    return self.peek().kind == .def_func or canStartExpression(self.peek().kind);
}

/// `Aとは変数`/`Aとは定数`の宣言文。公式は初期値を省略できるため、
/// `=`の有無だけを見る`canStartAssignment`では判定できない。
pub fn isTowaDeclaration(self: *Parser) bool {
    const token = self.peek();
    if (token.kind != .identifier) return false;
    if (!std.mem.eql(u8, token.josi, "とは")) return false;
    const next = self.peekAhead(1);
    return next.kind == .keyword_let or next.kind == .keyword_const;
}

pub fn parseAssignment(self: *Parser) ParseFailure!*ast.Node {
    const start = self.peek();
    var targets: std.ArrayList(*ast.Node) = .empty;
    try targets.append(self.allocator, try self.parseLValue());
    while (self.at(.comma)) {
        _ = self.advance();
        try targets.append(self.allocator, try self.parseLValue());
    }
    // 公式は`Aとは変数`/`Aとは定数`を宣言として扱い、`{公開}`/`{非公開}`
    // 属性と`=`による初期値を任意にする。
    const declaration_from_towa = (self.at(.keyword_let) or self.at(.keyword_const)) and
        std.mem.eql(u8, targets.items[0].josi, "とは");
    var declaration_is_const = false;
    var declaration_is_export = true;
    if (declaration_from_towa) {
        declaration_is_const = self.peek().kind == .keyword_const;
        _ = self.advance();
        declaration_is_export = try self.parseVariableAttribute(self.export_default);
    }
    var value = if (declaration_from_towa) try builder.omittedValue(self, start) else undefined;
    if (self.at(.equal)) {
        _ = self.advance();
        // 公式は`yCalc() || value`で式の無い右辺をnopへ落とす。
        if (!declaration_from_towa or canStartDeclarationValue(self)) {
            value = try self.parseCallExpression();
        }
    } else if (!declaration_from_towa) {
        return self.fail(.expected_token, "代入文に『=』が必要です", self.peek());
    }
    // 公式は`名前1=値1, 名前2=値2`のために宣言直後のカンマを1つ読み飛ばす。
    if (declaration_from_towa and self.at(.comma)) _ = self.advance();
    if (targets.items.len > 1) {
        const result = try builder.makeNodeWithChildren(self, .variable_list_definition, start, try builder.copyChildren(self, &.{value}));
        result.arguments = try builder.namesToArguments(self, targets.items);
        result.is_export = self.export_default;
        return result;
    }
    const target = targets.items[0];
    const kind: ast.Kind = switch (target.kind) {
        .array_reference => .array_assignment,
        .property_reference => .property_assignment,
        else => if (declaration_from_towa) .variable_definition else .assignment,
    };
    const target_children = if (target.kind == .array_reference or target.kind == .property_reference)
        try builder.assignmentPath(self, target)
    else
        target.children;
    const children = if (target_children.len == 0)
        try builder.copyChildren(self, &.{value})
    else
        try builder.prepend(self, value, target_children);
    const node = try builder.makeNodeWithChildren(self, kind, start, children);
    node.name = if (target.name.len > 0) target.name else target.value;
    node.josi = "";
    if (declaration_from_towa) {
        node.is_const = declaration_is_const;
        node.is_export = declaration_is_export;
    }
    // DNCLでは未初期化変数への配列要素代入で30要素配列を自動初期化する（公式flagCheckArrayInit相当）
    node.check_array_init = kind == .array_assignment and (self.mode.dncl or self.mode.dncl2);
    return node;
}
