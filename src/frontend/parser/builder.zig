const std = @import("std");
const ast = @import("../ast.zig");
const token_mod = @import("../token.zig");
const parser_mod = @import("../parser.zig");
const helpers = @import("helpers.zig");

const Parser = parser_mod.Parser;
const ParseFailure = parser_mod.ParseFailure;
const Token = token_mod.Token;

pub fn reference(self: *Parser, kind: ast.Kind, base: *ast.Node, indexes: []const *ast.Node, token: Token) ParseFailure!*ast.Node {
    var children: std.ArrayList(*ast.Node) = .empty;
    if (base.kind == kind) {
        try children.appendSlice(self.allocator, base.children);
    } else {
        try children.append(self.allocator, base);
    }
    try children.appendSlice(self.allocator, indexes);
    const node = try makeNodeWithChildren(self, kind, token, try children.toOwnedSlice(self.allocator));
    node.name = switch (kind) {
        .array_value_reference => if (token.kind == .property) "$" else "@",
        else => if (base.name.len > 0) base.name else base.value,
    };
    node.josi = if (indexes.len > 0) indexes[indexes.len - 1].josi else base.josi;
    return node;
}

pub fn assignmentPath(self: *Parser, target: *ast.Node) ParseFailure![]*ast.Node {
    var path: std.ArrayList(*ast.Node) = .empty;
    try helpers.appendAssignmentPath(&path, self.allocator, target);
    return path.toOwnedSlice(self.allocator);
}

pub fn sequence(self: *Parser, left: *ast.Node, right: *ast.Node, token: Token) ParseFailure!*ast.Node {
    const node = try makeNodeWithChildren(self, .sequence, token, try copyChildren(self, &.{ left, right }));
    node.operator = "renbun";
    node.josi = right.josi;
    return node;
}

pub fn unary(self: *Parser, operator: []const u8, operand: *ast.Node, token: Token) ParseFailure!*ast.Node {
    const node = try makeNodeWithChildren(self, .unary_operator, token, try copyChildren(self, &.{operand}));
    node.operator = operator;
    node.josi = operand.josi;
    return node;
}

pub fn numberOne(self: *Parser, token: Token) ParseFailure!*ast.Node {
    const node = try makeNode(self, .number, token);
    node.value = "1";
    node.number_value = 1;
    return node;
}

pub fn nop(self: *Parser, token: Token) ParseFailure!*ast.Node {
    return makeNode(self, .nop, token);
}

pub fn emptyBlock(self: *Parser, token: Token) ParseFailure!*ast.Node {
    return makeNodeWithChildren(self, .block, token, &.{});
}

pub fn wrapSingle(self: *Parser, child: *ast.Node) ParseFailure!*ast.Node {
    return makeNodeWithChildren(self, .block, self.peekPrevious(), try copyChildren(self, &.{child}));
}

pub fn valueNode(self: *Parser, kind: ast.Kind, token: Token) ParseFailure!*ast.Node {
    const node = try makeNode(self, kind, token);
    node.value = token.value;
    node.number_value = token.number_value;
    node.josi = token.josi;
    node.raw_josi = token.raw_josi;
    return node;
}

pub fn makeNode(self: *Parser, kind: ast.Kind, token: Token) ParseFailure!*ast.Node {
    const result = try self.allocator.create(ast.Node);
    result.* = .{
        .kind = kind,
        .span = token.span,
        .end_span = self.peekPrevious().span,
        .josi = token.josi,
        .raw_josi = token.raw_josi,
    };
    return result;
}

pub fn makeNodeWithChildren(self: *Parser, kind: ast.Kind, token: Token, children: []*ast.Node) ParseFailure!*ast.Node {
    const result = try makeNode(self, kind, token);
    result.children = children;
    if (children.len > 0) result.end_span = children[children.len - 1].end_span;
    return result;
}

pub fn copyChildren(self: *Parser, children: []const *ast.Node) ParseFailure![]*ast.Node {
    return self.allocator.dupe(*ast.Node, children);
}

/// DNCL(v1)の配列添字は1始まりなので、公式のcheckArrayIndexと同じく `添字-1` に包む。
/// DNCL2では0始まりのまま扱うため、そのまま返す。
pub fn dnclArrayIndex(self: *Parser, index: *ast.Node) ParseFailure!*ast.Node {
    if (!self.mode.dncl) return index;
    const one = try self.allocator.create(ast.Node);
    one.* = .{ .kind = .number, .span = index.span, .end_span = index.end_span, .number_value = 1 };
    one.value = "1";
    const wrapped = try makeNode(self, .binary_operator, .{ .kind = .minus, .span = index.span, .lexeme = "-", .value = "-" });
    wrapped.operator = "-";
    wrapped.end_span = index.end_span;
    wrapped.josi = index.josi;
    wrapped.raw_josi = index.raw_josi;
    wrapped.children = try copyChildren(self, &.{ index, one });
    index.josi = "";
    index.raw_josi = "";
    return wrapped;
}

/// DNCL(v1)の多次元配列は添字が逆順になる（公式checkArrayReverse相当）。
pub fn dnclReverseIndexes(self: *Parser, indexes: []*ast.Node) void {
    if (!self.mode.dncl or indexes.len < 2) return;
    std.mem.reverse(*ast.Node, indexes);
}

pub fn namesToArguments(self: *Parser, names: []const *ast.Node) ParseFailure![]ast.Argument {
    const result = try self.allocator.alloc(ast.Argument, names.len);
    for (names, 0..) |name, index| result[index] = .{
        .name = if (name.value.len > 0) name.value else name.name,
        .josi = name.josi,
        .span = name.span,
    };
    return result;
}

pub fn prepend(self: *Parser, first: *ast.Node, rest: []const *ast.Node) ParseFailure![]*ast.Node {
    const result = try self.allocator.alloc(*ast.Node, rest.len + 1);
    result[0] = first;
    @memcpy(result[1..], rest);
    return result;
}
