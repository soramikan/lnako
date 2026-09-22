const std = @import("std");
const ast = @import("../ast.zig");
const token_mod = @import("../token.zig");

const Token = token_mod.Token;
const Kind = token_mod.Kind;

const OperatorInfo = struct { precedence: u8, right_associative: bool = false, name: []const u8 };

pub fn operatorInfo(kind: Kind) ?OperatorInfo {
    return switch (kind) {
        .logical_or => .{ .precedence = 10, .name = "or" },
        .logical_and => .{ .precedence = 10, .name = "and" },
        .equal => .{ .precedence = 20, .name = "eq" },
        .strict_equal => .{ .precedence = 20, .name = "===" },
        .not_equal => .{ .precedence = 20, .name = "noteq" },
        .strict_not_equal => .{ .precedence = 20, .name = "!==" },
        .greater => .{ .precedence = 20, .name = "gt" },
        .greater_equal => .{ .precedence = 20, .name = "gteq" },
        .less => .{ .precedence = 20, .name = "lt" },
        .less_equal => .{ .precedence = 20, .name = "lteq" },
        .range => .{ .precedence = 25, .name = "…" },
        .bit_and => .{ .precedence = 30, .name = "&" },
        .bit_xor => .{ .precedence = 60, .name = "**" },
        .plus => .{ .precedence = 40, .name = "+" },
        .minus => .{ .precedence = 40, .name = "-" },
        .shift_left => .{ .precedence = 40, .name = "shift_l" },
        .shift_right => .{ .precedence = 40, .name = "shift_r" },
        .shift_right_unsigned => .{ .precedence = 40, .name = "shift_r0" },
        .multiply => .{ .precedence = 50, .name = "*" },
        .divide => .{ .precedence = 50, .name = "÷" },
        .integer_divide => .{ .precedence = 50, .name = "÷÷" },
        .modulo => .{ .precedence = 50, .name = "%" },
        .power => .{ .precedence = 60, .name = "**" },
        else => null,
    };
}

pub fn canStartExpression(kind: Kind) bool {
    return switch (kind) {
        // 公式`yValue`は`def_func`（匿名関数）も値として読むため、
        // `F(1 関数() 2で戻る ここまで)`のようなカンマ無し引数でも開始できる。
        .number, .bigint, .string, .string_template, .identifier, .function_ref, .left_paren, .left_bracket, .left_brace, .not, .minus, .def_func => true,
        else => false,
    };
}

pub fn operatorName(kind: Kind) []const u8 {
    return switch (kind) {
        .not => "not",
        .minus => "-",
        .plus => "+",
        else => "",
    };
}

pub fn isConditionalJosi(josi: []const u8) bool {
    return std.mem.eql(u8, josi, "ならば") or std.mem.eql(u8, josi, "なら") or
        std.mem.eql(u8, josi, "たら") or std.mem.eql(u8, josi, "れば") or
        std.mem.eql(u8, josi, "でなければ") or std.mem.eql(u8, josi, "なければ");
}

/// 否定の条件助詞かどうか。公式の字句解析は「でなければ」「しなければ」
/// 「なければ」をすべて否定の条件助詞へ正規化するため、条件式はnotで包む。
pub fn isNegativeConditionJosi(josi: []const u8) bool {
    return std.mem.eql(u8, josi, "でなければ") or std.mem.eql(u8, josi, "なければ");
}

pub fn isSequenceJosi(josi: []const u8) bool {
    const values = [_][]const u8{ "いて", "えて", "きて", "けて", "して", "って", "にて", "みて", "めて", "ねて", "には", "んで" };
    for (values) |value| if (std.mem.eql(u8, josi, value)) return true;
    return false;
}

pub fn isTargetJosi(josi: []const u8) bool {
    return std.mem.eql(u8, josi, "に") or std.mem.eql(u8, josi, "へ");
}

pub fn isValueJosi(josi: []const u8) bool {
    return std.mem.eql(u8, josi, "を") or std.mem.eql(u8, josi, "から");
}

/// 公式ySadameruが定義対象に取る助詞（`popStack(['を'])`）。
pub fn isDefineTargetJosi(josi: []const u8) bool {
    return std.mem.eql(u8, josi, "を");
}

/// 公式ySadameruが値に取る助詞（`popStack(['へ', 'に', 'と'])`）。
/// `代入`の対象助詞（`へ`/`に`）と違い`と`も値として扱う。
pub fn isDefineValueJosi(josi: []const u8) bool {
    return isTargetJosi(josi) or std.mem.eql(u8, josi, "と");
}

pub fn isImplicitCallbackJosi(josi: []const u8) bool {
    return std.mem.eql(u8, josi, "には");
}

/// `implicitIt`が連文継続用に挿入した暗黙の『それ』マーカーかどうか。
/// ユーザーが記述した`それ`はjosiかraw_josiの少なくとも一方を持つため、
/// 両方が空のword『それ』はマーカーとして区別できる。
pub fn isImplicitItMarker(node: *ast.Node) bool {
    return node.kind == .word and std.mem.eql(u8, node.value, "それ") and
        node.josi.len == 0 and node.raw_josi.len == 0;
}

pub fn isVariableReference(kind: ast.Kind) bool {
    return kind == .word or kind == .array_reference or kind == .property_reference;
}

pub fn clearConditionalJosi(node: *ast.Node) void {
    node.josi = "";
    node.raw_josi = "";
    if (node.kind == .binary_operator or node.kind == .unary_operator) {
        for (node.children) |child| clearConditionalJosi(child);
    }
}

pub fn propagateOperatorJosi(node: *ast.Node, josi: []const u8) void {
    // 公式の括弧式は閉じ括弧の助詞をrootへ設定するが、括弧内の
    // 演算子・リテラルへは伝播させない。grouped rootを境界にする。
    if (node.kind != .binary_operator or node.grouped) return;
    node.josi = josi;
    for (node.children) |child| if (!child.grouped) propagateOperatorJosi(child, josi);
}

pub fn tokenStem(token: Token) []const u8 {
    if (token.raw_josi.len > 0 and token.lexeme.len >= token.raw_josi.len) {
        return token.lexeme[0 .. token.lexeme.len - token.raw_josi.len];
    }
    return token.value;
}

/// 公式yIncDecの対象規則: 変数・配列参照・プロパティ参照で、最深部がword。
/// prop[i]形（プロパティ参照への添字適用）は公式が受理しないため拒否する。
pub fn isIncrementTargetPath(node: *ast.Node) bool {
    var current = node;
    while (true) switch (current.kind) {
        .word => return true,
        .property_reference => current = current.children[0],
        .array_reference => {
            if (current.children[0].kind == .property_reference) return false;
            current = current.children[0];
        },
        else => return false,
    };
}

pub fn appendAssignmentPath(path: *std.ArrayList(*ast.Node), allocator: std.mem.Allocator, node: *ast.Node) std.mem.Allocator.Error!void {
    if (node.kind != .array_reference and node.kind != .property_reference) {
        if (node.kind != .word) try path.append(allocator, node);
        return;
    }
    for (node.children, 0..) |child, index| {
        if (index == 0 and (child.kind == .word or child.kind == .array_reference or child.kind == .property_reference)) {
            try appendAssignmentPath(path, allocator, child);
        } else {
            try path.append(allocator, child);
        }
    }
}

pub fn emptyToken() Token {
    return .{
        .kind = .eof,
        .lexeme = "",
        .value = "",
        .span = ast.emptySpan(),
    };
}

/// 公式`NakoLexer.preDefineFunc`相当。解析前のトークン列を走査してソース内で
/// 定義された関数名を集める。公式は定義の位置に関わらず関数名を`func token`
/// にするため、後方定義の呼出し（前方参照）も命令呼出しとして解決できる。
pub fn collectUserFunctionNames(allocator: std.mem.Allocator, tokens: []const Token) std.mem.Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < tokens.len) : (index += 1) {
        if (tokens[index].kind != .def_func and tokens[index].kind != .def_test) continue;
        // 無名関数の`関数`キーワードも`def_func`になるが、名前を持たないため
        // 直後の識別子は本体の先頭語（`F=関数(A)それはA`の「それ」）であって
        // 関数名ではない。名前付き定義（`●`・`●テスト:`）だけを集める。
        if (std.mem.eql(u8, tokens[index].value, "関数")) continue;
        var cursor = index + 1;
        // `●{公開}Fとは` のような属性を読み飛ばす。
        if (cursor < tokens.len and tokens[cursor].kind == .left_brace) {
            cursor += 1;
            while (cursor < tokens.len and tokens[cursor].kind != .right_brace) cursor += 1;
            cursor += 1;
        }
        // `●(Aを)Fとは` のように名前の前に来る引数宣言を読み飛ばす。
        if (cursor < tokens.len and tokens[cursor].kind == .left_paren) {
            var depth: usize = 0;
            while (cursor < tokens.len) : (cursor += 1) {
                if (tokens[cursor].kind == .left_paren) {
                    depth += 1;
                } else if (tokens[cursor].kind == .right_paren) {
                    depth -= 1;
                    if (depth == 0) {
                        cursor += 1;
                        break;
                    }
                }
            }
        }
        if (cursor < tokens.len and tokens[cursor].kind == .identifier) {
            try names.append(allocator, tokens[cursor].value);
        }
    }
    return names.toOwnedSlice(allocator);
}
