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
        .number, .bigint, .string, .string_template, .identifier, .function_ref, .left_paren, .left_bracket, .left_brace, .not, .minus => true,
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

pub fn isImplicitCallbackJosi(josi: []const u8) bool {
    return std.mem.eql(u8, josi, "には");
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
