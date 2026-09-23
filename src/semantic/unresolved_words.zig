const std = @import("std");
const ast = @import("../frontend/ast.zig");
const builtin_catalog = @import("builtin_catalog.zig");
const argument_completion = @import("argument_completion.zig");
const parser_helpers = @import("../frontend/parser/helpers.zig");
const low_level_foundation = @import("../runtime/low_level_foundation.zig");
const analyzer_mod = @import("analyzer.zig");

const Analyzer = analyzer_mod.Analyzer;
const ScopeId = analyzer_mod.ScopeId;

/// 助詞不一致引数の未解決語報告を子の解決後まで遅らせるための記録。
pub const DeferredUnresolved = struct {
    module_index: u32,
    scope: ScopeId,
    node: *ast.Node,
    slots: []const argument_completion.Slot,
    variable_final: bool,
};

/// 未解決語報告を呼出しの子解決が終わるまで遅延させる。公式は
/// 引数側の呼出し（func token）を先に処理するため、`置換して表示`
/// の『置換』の引数不足診断が外側『表示』の残り引数報告より先に出る。
pub fn deferUnresolvedArguments(self: *Analyzer, module_index: u32, scope: ScopeId, node: *ast.Node, slots: []const argument_completion.Slot, variable_final: bool) !void {
    try self.deferred_unresolved.append(self.allocator, .{
        .module_index = module_index,
        .scope = scope,
        .node = node,
        .slots = slots,
        .variable_final = variable_final,
    });
}

/// この呼出しへ遅延登録された未解決語報告を、子の解決が終わった
/// タイミングで発行する。
pub fn drainDeferredUnresolved(self: *Analyzer, node: *ast.Node) !void {
    var index: usize = 0;
    while (index < self.deferred_unresolved.items.len) : (index += 1) {
        if (self.deferred_unresolved.items[index].node == node) {
            const deferred = self.deferred_unresolved.orderedRemove(index);
            try reportUnresolvedArguments(self, deferred.module_index, deferred.scope, deferred.node, deferred.slots, deferred.variable_final);
            return;
        }
    }
}

/// 助詞スロットへ割り当てられなかった引数を、公式の
/// 『未解決の単語があります: [...]』相当の文法エラーとして報告する。
/// 連文・コールバック構文が挿入した暗黙マーカーは実引数ではないため
/// 報告対象から除く。診断位置は公式が検出する行末（eol）の行、
/// すなわち呼出しのある行の次の行に揃える。
fn reportUnresolvedArguments(self: *Analyzer, module_index: u32, scope: ScopeId, node: *ast.Node, slots: []const argument_completion.Slot, variable_final: bool) !void {
    const unmatched = try argument_completion.unresolvedArguments(self.allocator, slots, node.children, variable_final);
    var message: std.ArrayList(u8) = .empty;
    try message.appendSlice(self.allocator, "未解決の単語があります: [");
    var count: usize = 0;
    for (unmatched) |index| {
        const argument = node.children[index];
        if (argument.is_implicit_it) continue;
        if (isChainCallArgument(self, module_index, scope, argument)) continue;
        if (count > 0) try message.appendSlice(self.allocator, ",");
        try message.appendSlice(self.allocator, try unresolvedWordDescription(self, module_index, scope, argument));
        count += 1;
    }
    if (count == 0) return;
    try message.appendSlice(self.allocator, "]");
    var span = node.end_span;
    span.line = statementTerminatorLine(self, module_index, node);
    try self.addDiagnostic(.unresolved_word, span, self.modules.items[module_index].path, message.items);
}

/// `XしてY`の連文で引数列へ残った連鎖呼出しかどうか。func tokenは
/// 公式`yCallFunc`がその場で解決するため外側呼出しの未解決語にしない。
/// 引数側の表現は2形態ある：`command_call`済みのfunction_callノードと、
/// 命令へ解決される`.word`（`空白除去して`など）。変数・特殊変数の
/// `.word`はfunc tokenではないため残り語として報告する。
fn isChainCallArgument(self: *Analyzer, module_index: u32, scope: ScopeId, argument: *ast.Node) bool {
    if (parser_helpers.isChainedCallResult(argument)) return true;
    if (argument.kind != .word or !parser_helpers.isSequenceJosi(argument.josi)) return false;
    if (self.resolveSymbol(module_index, scope, argument.value, argument.span)) |symbol|
        return symbol.kind == .function or symbol.kind == .test_function;
    for (builtin_catalog.function_names) |name|
        if (std.mem.eql(u8, name, argument.value)) return true;
    for (low_level_foundation.extension_command_names) |name|
        if (std.mem.eql(u8, name, argument.value)) return true;
    return false;
}

/// 公式`yEOL`が残り語を検出する行末トークンの行（0始まり）。呼出しに
/// 続く文区切りが `;`（句点 `。` の正規化形）なら同じ行、改行なら
/// 次の行、入力末尾なら同じ行を返す。文字列・コメント内の区切り
/// らしき文字は読み飛ばす。
fn statementTerminatorLine(self: *Analyzer, module_index: u32, node: *ast.Node) usize {
    const source = self.inputs[module_index].normalized_source;
    const base_line = node.end_span.line;
    var i: usize = node.end_span.source_end;
    scan: while (i < source.len) {
        switch (source[i]) {
            ';' => return base_line,
            '\n' => return base_line + 1,
            '#' => {
                while (i < source.len and source[i] != '\n') i += 1;
            },
            else => {
                for ([_][]const u8{ "※", "／／" }) |marker| {
                    if (std.mem.startsWith(u8, source[i..], marker)) {
                        while (i < source.len and source[i] != '\n') i += 1;
                        continue :scan;
                    }
                }
                for ([_][]const u8{ "「", "『", "🌴", "🌿", "\"", "'" }, [_][]const u8{ "」", "』", "🌴", "🌿", "\"", "'" }) |open, close| {
                    if (std.mem.startsWith(u8, source[i..], open)) {
                        i += open.len;
                        while (i < source.len and !std.mem.startsWith(u8, source[i..], close)) i += 1;
                        if (i < source.len) i += close.len;
                        continue :scan;
                    }
                }
                if (std.mem.startsWith(u8, source[i..], "/*")) {
                    i += 2;
                    while (i + 1 < source.len and !std.mem.startsWith(u8, source[i..], "*/")) i += 1;
                    if (i + 1 < source.len) i += 2;
                    continue :scan;
                }
                i += 1;
            },
        }
    }
    return base_line;
}

/// 公式`nodeToStr({depth:1})`相当の未解決語の説明を返す。単語は
/// モジュール修飾名（`main__A`）、関数・命令の参照は『関数』、
/// 特殊変数は修飾なしで表し、末尾へ助詞を付ける。
fn unresolvedWordDescription(self: *Analyzer, module_index: u32, scope: ScopeId, node: *ast.Node) ![]const u8 {
    const base: []const u8 = switch (node.kind) {
        .number, .bigint => if (node.number_value) |number|
            try std.fmt.allocPrint(self.allocator, "数値{d}", .{number})
        else
            try std.fmt.allocPrint(self.allocator, "数値{s}", .{node.value}),
        .string, .string_template => try std.fmt.allocPrint(self.allocator, "文字列『{s}』", .{node.value}),
        .word, .boolean, .null_value => try unresolvedWordName(self, module_index, scope, node),
        .function_call => try std.fmt.allocPrint(self.allocator, "関数『{s}』", .{try unresolvedFunctionName(self, module_index, scope, node.name)}),
        .call_value => "『call_value』",
        .array_reference, .array_value_reference, .property_reference => try std.fmt.allocPrint(self.allocator, "『{s}』", .{parser_helpers.referenceTypeName(node)}),
        .array_literal => "『json_array』",
        .object_literal => "『json_obj』",
        else => "式",
    };
    return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, node.josi });
}

/// 未解決の単語の表示。解決できる場合は公式`nodeToStr`と同じく
/// モジュール修飾名を返す。関数シンボルや組み込み命令は『関数』、
/// 未定義の語は`モジュール名__語`として表示する。
fn unresolvedWordName(self: *Analyzer, module_index: u32, scope: ScopeId, node: *ast.Node) ![]const u8 {
    if (node.kind == .word and node.value.len > 0) {
        // 公式の特殊変数はシンボル解決より先に畳む（『そう』は『それ』）。
        if (std.mem.eql(u8, node.value, "そう")) return "単語『それ』";
        for ([_][]const u8{ "それ", "回数", "対象" }) |special|
            if (std.mem.eql(u8, node.value, special)) return try std.fmt.allocPrint(self.allocator, "単語『{s}』", .{special});
        if (self.resolveSymbol(module_index, scope, node.value, node.span)) |symbol| {
            if (symbol.kind == .function or symbol.kind == .test_function)
                return try std.fmt.allocPrint(self.allocator, "関数『{s}』", .{symbol.qualified_name});
            return try std.fmt.allocPrint(self.allocator, "単語『{s}』", .{variableDisplayName(symbol.qualified_name)});
        }
        if (self.builtins.get(node.value) != null)
            return try std.fmt.allocPrint(self.allocator, "関数『{s}』", .{node.value});
        return try std.fmt.allocPrint(self.allocator, "単語『{s}__{s}』", .{ self.modules.items[module_index].name, node.value });
    }
    return try std.fmt.allocPrint(self.allocator, "単語『{s}』", .{node.value});
}

/// 未解決の関数呼出しの表示名。ユーザー定義関数はモジュール修飾名、
/// 組み込み命令・未解決の名前はそのまま表示する。
fn unresolvedFunctionName(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8) ![]const u8 {
    if (self.resolveSymbol(module_index, scope, name, .{ .start = 0, .end = 0, .source_start = 0, .source_end = 0, .line = 0, .column = 0 })) |symbol| return symbol.qualified_name;
    if (std.mem.indexOf(u8, name, "__") != null or self.builtins.get(name) != null) return name;
    return try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ self.modules.items[module_index].name, name });
}

/// 未解決語の変数名表示。『それ』『そう』『回数』『対象』は公式が
/// モジュール接頭辞を付けない特殊変数（『そう』は『それ』へ畳む）。
fn variableDisplayName(qualified_name: []const u8) []const u8 {
    const bare = if (std.mem.lastIndexOf(u8, qualified_name, "__")) |index| qualified_name[index + 2 ..] else qualified_name;
    if (std.mem.eql(u8, bare, "それ") or std.mem.eql(u8, bare, "そう")) return "それ";
    for ([_][]const u8{ "回数", "対象" }) |special|
        if (std.mem.eql(u8, bare, special)) return special;
    return qualified_name;
}
