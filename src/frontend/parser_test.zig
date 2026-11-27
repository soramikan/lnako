const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const parser_mod = @import("parser.zig");
const source_mod = @import("source.zig");

const parse = parser_mod.parse;

test "代入・演算子優先順位・命令呼び出しを構文解析する" {
    var result = try parse(std.testing.allocator, "A=1\nB=2\nA+Bを表示\n", "main.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqual(ast.Kind.block, result.root.?.kind);
    try std.testing.expectEqual(ast.Kind.assignment, result.root.?.children[0].kind);
    const call = result.root.?.children[4];
    try std.testing.expectEqual(ast.Kind.function_call, call.kind);
    try std.testing.expectEqualStrings("表示", call.name);
    try std.testing.expectEqual(ast.Kind.binary_operator, call.children[0].kind);
    try std.testing.expectEqualStrings("+", call.children[0].operator);
}

test "C風呼び出しを助詞付き命令呼び出しと区別する" {
    var result = try parse(std.testing.allocator, "表示(1)\nAを表示\n", "call-form.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expect(result.root.?.children[0].is_c_style_call);
    try std.testing.expect(!result.root.?.children[2].is_c_style_call);
}

test "識別子変数を途中の命令と誤認せず複数引数を構文解析する" {
    var result = try parse(std.testing.allocator, "201でHを簡易HTTPサーバヘッダ出力\n", "http-server.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const call = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, call.kind);
    try std.testing.expectEqualStrings("簡易HTTPサーバヘッダ出力", call.name);
    try std.testing.expectEqual(@as(usize, 2), call.children.len);
    try std.testing.expectEqual(ast.Kind.number, call.children[0].kind);
    try std.testing.expectEqualStrings("で", call.children[0].josi);
    try std.testing.expectEqual(ast.Kind.word, call.children[1].kind);
    try std.testing.expectEqualStrings("H", call.children[1].value);
    try std.testing.expectEqualStrings("を", call.children[1].josi);
}

test "助詞付きの変数を命令名と誤認せず文字検索の3引数を構文解析する" {
    // 公式はfunclistにない`C`を値として扱う。`Cから`を未定義関数の呼出しに
    // すると、`「ん」を`が別の呼出しになって文字検索の引数が不足する。
    var result = try parse(std.testing.allocator, "C=1\n「しんぶんし」でCから「ん」を文字検索。\n", "search.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    var call: ?*ast.Node = null;
    for (result.root.?.children) |child| {
        if (child.kind == .function_call and std.mem.eql(u8, child.name, "文字検索")) {
            call = child;
            break;
        }
    }
    const search = call orelse return error.MissingSearchCall;
    try std.testing.expectEqual(@as(usize, 3), search.children.len);
    try std.testing.expectEqual(ast.Kind.word, search.children[1].kind);
    try std.testing.expectEqualStrings("C", search.children[1].value);
    try std.testing.expectEqualStrings("から", search.children[1].josi);
}

test "引数定義の『|』区切り助詞候補を1引数へまとめる" {
    // 公式の`preDefineFunc`は`(Sが|Sの|Sを)`を1引数Sの助詞リスト
    // [が,の,を]として登録する。lnakoはASTの1引数へ『|』区切りで保持する。
    var result = try parse(std.testing.allocator, "●全角判定(Sが|Sの|Sを)\nSで戻る\nここまで。\n", "josi-alternatives.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    var definition: ?*ast.Node = null;
    for (result.root.?.children) |child| {
        if (child.kind == .function_definition) {
            definition = child;
            break;
        }
    }
    const function = definition orelse return error.MissingFunctionDefinition;
    try std.testing.expectEqual(@as(usize, 1), function.arguments.len);
    try std.testing.expectEqualStrings("S", function.arguments[0].name);
    try std.testing.expectEqualStrings("が|の|を", function.arguments[0].josi);
}

test "引数定義の『|』区切り同名候補を初出順の名前ごとに集約する" {
    // 公式`preDefineFunc`は`(Aに|Bを|Aへ)`をA[に,へ]・B[を]の2引数にし、
    // Aを2スロットとして扱わない。現行lnakoは名前が変わるたびに確定して
    // いたため、Aの重複定義になっていた。
    var result = try parse(std.testing.allocator, "●試験(Aに|Bを|Aへ)\n[A,B]で戻る\nここまで。\n", "josi-interleaved.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const function = try firstFunctionDefinition(result.root.?);
    try std.testing.expectEqual(@as(usize, 2), function.arguments.len);
    try std.testing.expectEqualStrings("A", function.arguments[0].name);
    try std.testing.expectEqualStrings("に|へ", function.arguments[0].josi);
    try std.testing.expectEqualStrings("B", function.arguments[1].name);
    try std.testing.expectEqualStrings("を", function.arguments[1].josi);
}

test "引数定義のカンマ・空白区切りでも同名候補を集約する" {
    const cases = [_]struct { source: []const u8, josi: []const u8 }{
        .{ .source = "●試験(Aに|Bを,Aへ)\n[A,B]で戻る\nここまで。\n", .josi = "に|へ" },
        .{ .source = "●試験(Aに|Aへ Bを)\n[A,B]で戻る\nここまで。\n", .josi = "に|へ" },
    };
    for (cases) |case| {
        var result = try parse(std.testing.allocator, case.source, "josi-separators.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        const function = try firstFunctionDefinition(result.root.?);
        try std.testing.expectEqual(@as(usize, 2), function.arguments.len);
        try std.testing.expectEqualStrings("A", function.arguments[0].name);
        try std.testing.expectEqualStrings(case.josi, function.arguments[0].josi);
        try std.testing.expectEqualStrings("B", function.arguments[1].name);
        try std.testing.expectEqualStrings("を", function.arguments[1].josi);
    }
}

test "助詞なしの出現も同じスロットの候補として集約する" {
    var result = try parse(std.testing.allocator, "●試験(A,Aを)\nAで戻る\nここまで。\n", "josi-empty-candidate.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const function = try firstFunctionDefinition(result.root.?);
    try std.testing.expectEqual(@as(usize, 1), function.arguments.len);
    try std.testing.expectEqualStrings("A", function.arguments[0].name);
    try std.testing.expectEqualStrings("|を", function.arguments[0].josi);
}

test "引数定義の重複した助詞候補を保持する" {
    // 公式は重複した候補もそのまま助詞リストへ積むため、lnakoも脱落させない。
    var result = try parse(std.testing.allocator, "●試験(Aを|Aを)\nAで戻る\nここまで。\n", "josi-duplicate.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const function = try firstFunctionDefinition(result.root.?);
    try std.testing.expectEqual(@as(usize, 1), function.arguments.len);
    try std.testing.expectEqualStrings("A", function.arguments[0].name);
    try std.testing.expectEqualStrings("を|を", function.arguments[0].josi);
}

test "助詞はを代入演算子として構文解析する" {
    var result = try parse(std.testing.allocator, "Fはそれ\n", "assignment.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const assignment = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.assignment, assignment.kind);
    try std.testing.expectEqualStrings("F", assignment.name);
    try std.testing.expectEqual(ast.Kind.word, assignment.children[0].kind);
    try std.testing.expectEqualStrings("それ", assignment.children[0].value);
}

test "行頭の等価比較を代入文と誤認しない" {
    var result = try parse(std.testing.allocator, "1n==1を表示\n", "equality.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const call = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, call.kind);
    try std.testing.expectEqual(ast.Kind.binary_operator, call.children[0].kind);
    try std.testing.expectEqualStrings("eq", call.children[0].operator);
}

test "冪乗演算子を公式同様に左結合として構文解析する" {
    var result = try parse(std.testing.allocator, "2^3^2を表示\n2**3**2を表示\n", "power.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const outer = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, outer.kind);
    try std.testing.expectEqualStrings("**", outer.operator);
    try std.testing.expectEqual(ast.Kind.binary_operator, outer.children[0].kind);
    try std.testing.expectEqualStrings("**", outer.children[0].operator);
    const stars = result.root.?.children[2].children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, stars.children[0].kind);
    try std.testing.expectEqualStrings("**", stars.children[0].operator);
}

test "もし文とソース位置を構文解析する" {
    var result = try parse(std.testing.allocator, "もしA=1ならば\nB=1\n違えば\nB=2\nここまで\n", "条件.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.if_statement, statement.kind);
    try std.testing.expectEqual(@as(usize, 3), statement.children.len);
    try std.testing.expectEqual(@as(usize, 0), statement.span.line);
    try std.testing.expectEqual(@as(usize, 1), statement.span.column);
}

test "DNCLの「でないならば」を条件否定へ変換する" {
    var result = try parse(std.testing.allocator, "!DNCLモード\nもしA=1でないならば\n|B=2\nを実行する\n", "dncl-not.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[2];
    const condition = statement.children[0];
    try std.testing.expectEqual(ast.Kind.unary_operator, condition.kind);
    try std.testing.expectEqualStrings("not", condition.operator);
    try std.testing.expectEqual(ast.Kind.binary_operator, condition.children[0].kind);
    try std.testing.expectEqualStrings("eq", condition.children[0].operator);
}

test "公式同様にインラインの「そうでなくもし」を入れ子の条件分岐にする" {
    var result = try parse(std.testing.allocator, "!DNCL2\nもしC=0ならば:\n　1を表示\nそうでなくもし、C=1ならば:\n　2を表示\n", "dncl2-else-if.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const outer = result.root.?.children[2];
    try std.testing.expectEqual(ast.Kind.if_statement, outer.kind);
    try std.testing.expectEqual(@as(usize, 1), outer.children[2].children.len);
    try std.testing.expectEqual(ast.Kind.if_statement, outer.children[2].children[0].kind);
}

test "もし直後の読点を許可する" {
    var result = try parse(std.testing.allocator, "もし、A=1ならば\nB=1\nここまで\n", "条件.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqual(ast.Kind.if_statement, result.root.?.children[0].kind);
}

test "間と繰り返すの間の読点を許可する" {
    var result = try parse(std.testing.allocator, "(N>0)の間、繰り返す\nN=N-1\nここまで\n", "反復.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqual(ast.Kind.while_statement, result.root.?.children[0].kind);
}

test "「AがBならば」を等価比較の条件式へ変換する" {
    var result = try parse(std.testing.allocator, "もし、Aが5ならば\nB=1\nここまで\n", "josi-eq.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, condition.kind);
    try std.testing.expectEqualStrings("eq", condition.operator);
    try std.testing.expectEqual(@as(usize, 2), condition.children.len);
    try std.testing.expectEqualStrings("A", condition.children[0].value);
    try std.testing.expectEqualStrings("が", condition.children[0].josi);
    try std.testing.expectEqualStrings("5", condition.children[1].value);
    try std.testing.expectEqualStrings("ならば", condition.children[1].josi);
}

test "「AがBでなければ」を不等価比較の条件式へ変換する" {
    var result = try parse(std.testing.allocator, "もし、Aが3でなければ\nB=1\nここまで\n", "josi-noteq.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, condition.kind);
    try std.testing.expectEqualStrings("noteq", condition.operator);
    try std.testing.expectEqualStrings("でなければ", condition.children[1].josi);
}

test "「Aが3以下ならば」を助詞呼出しの条件式へ変換する" {
    var result = try parse(std.testing.allocator, "もし、Aが3以下ならば\nB=1\nここまで\n", "josi-call.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
    try std.testing.expectEqualStrings("以下", condition.name);
    try std.testing.expectEqualStrings("", condition.josi);
    try std.testing.expectEqual(@as(usize, 2), condition.children.len);
    try std.testing.expectEqualStrings("A", condition.children[0].value);
    try std.testing.expectEqualStrings("が", condition.children[0].josi);
    try std.testing.expectEqualStrings("3", condition.children[1].value);
    try std.testing.expectEqualStrings("", condition.children[1].josi);
}

test "「AがBからCの範囲内ならば」の同行真節を条件式へ取り込まない" {
    // Issue #297: 条件末尾の`ならば`を呼出し列の継続として扱うと、同じ行の
    // 真節（`「30は範囲内」と表示。`）が範囲内の第4引数として吸収され、
    // `invalid_control_statement`になっていた。条件助詞で呼出しを切る。
    var result = try parse(std.testing.allocator, "もし、30が30から50の範囲内ならば、「30は範囲内」と表示。\nもし、50が30から50の範囲内ならば、「50は範囲内」と表示。\n", "josi-range-inline.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    var statements: [2]*ast.Node = undefined;
    var statement_count: usize = 0;
    for (result.root.?.children) |child| {
        if (child.kind != .if_statement) continue;
        if (statement_count < statements.len) statements[statement_count] = child;
        statement_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), statement_count);
    const expected_values = [_][]const u8{ "30", "50" };
    const expected_messages = [_][]const u8{ "30は範囲内", "50は範囲内" };
    for (statements, expected_values, expected_messages) |statement, expected_value, expected_message| {
        try std.testing.expectEqual(ast.Kind.if_statement, statement.kind);
        const condition = statement.children[0];
        try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
        try std.testing.expectEqualStrings("範囲内", condition.name);
        try std.testing.expectEqualStrings("", condition.josi);
        try std.testing.expectEqual(@as(usize, 3), condition.children.len);
        try std.testing.expectEqualStrings(expected_value, condition.children[0].value);
        try std.testing.expectEqualStrings("30", condition.children[1].value);
        try std.testing.expectEqualStrings("50", condition.children[2].value);
        const true_block = statement.children[1];
        try std.testing.expectEqual(ast.Kind.block, true_block.kind);
        try std.testing.expectEqual(@as(usize, 1), true_block.children.len);
        const display = true_block.children[0];
        try std.testing.expectEqual(ast.Kind.function_call, display.kind);
        try std.testing.expectEqualStrings("表示", display.name);
        try std.testing.expectEqual(@as(usize, 1), display.children.len);
        try std.testing.expectEqualStrings(expected_message, display.children[0].value);
    }
}

test "条件助詞付き呼出しの同行真節を引数へ続けない" {
    // 範囲内に限らず、`ならば`付きの呼出し条件は同じ行の真節を吸収しない。
    var result = try parse(std.testing.allocator, "もし、Aが3以下ならば、「OK」と表示。\n", "josi-call-inline.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.if_statement, statement.kind);
    const condition = statement.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
    try std.testing.expectEqualStrings("以下", condition.name);
    try std.testing.expectEqual(@as(usize, 2), condition.children.len);
    const true_block = statement.children[1];
    try std.testing.expectEqual(ast.Kind.block, true_block.kind);
    try std.testing.expectEqual(@as(usize, 1), true_block.children.len);
    try std.testing.expectEqualStrings("表示", true_block.children[0].name);
}

test "「AがBと等しいならば」を助詞呼出しの条件式へ変換する" {
    var result = try parse(std.testing.allocator, "もし、AがBと等しいならば\nC=1\nここまで\n", "josi-equal-call.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
    try std.testing.expectEqualStrings("等", condition.name);
    try std.testing.expectEqual(@as(usize, 2), condition.children.len);
    try std.testing.expectEqualStrings("B", condition.children[1].value);
    try std.testing.expectEqualStrings("と", condition.children[1].josi);
}

test "がの比較条件の右辺で既知命令のC風呼出しを読む" {
    for ([_][]const u8{ "ならば", "でなければ" }, [_][]const u8{ "eq", "noteq" }) |josi, operator| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "もし、AがINT(3){s}、B=1\n", .{josi});
        defer std.testing.allocator.free(source);
        var result = try parse(std.testing.allocator, source, "main.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        const condition = result.root.?.children[0].children[0];
        try std.testing.expectEqual(ast.Kind.binary_operator, condition.kind);
        try std.testing.expectEqualStrings(operator, condition.operator);
        const rhs = condition.children[1];
        try std.testing.expect(rhs.is_c_style_call);
        try std.testing.expectEqualStrings("INT", rhs.name);
        try std.testing.expectEqualStrings("3", rhs.children[0].value);
    }
}

test "「Aが奇数ならば」を既知命令の条件呼出しへ変換する" {
    // 公式`yIFCond`は`A`の直後が`func`トークンなら`奇数(A)`を作る。
    // `A=奇数`の等価比較へ落とすと条件が常に偽になるため、呼出し形状を固定する。
    var result = try parse(std.testing.allocator, "もし、Aが奇数ならば\nB=1\nここまで\n", "josi-predicate-odd.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
    try std.testing.expectEqualStrings("奇数", condition.name);
    try std.testing.expectEqualStrings("", condition.josi);
    try std.testing.expectEqual(@as(usize, 1), condition.children.len);
    try std.testing.expectEqualStrings("A", condition.children[0].value);
    try std.testing.expectEqualStrings("が", condition.children[0].josi);
}

test "「Aが偶数ならば」を既知命令の条件呼出しへ変換する" {
    var result = try parse(std.testing.allocator, "もし、Aが偶数ならば\nB=1\nここまで\n", "josi-predicate-even.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
    try std.testing.expectEqualStrings("偶数", condition.name);
    try std.testing.expectEqual(@as(usize, 1), condition.children.len);
    try std.testing.expectEqualStrings("A", condition.children[0].value);
}

test "「Aが数列か判定ならば」を正規化済み命令の条件呼出しへ変換する" {
    var result = try parse(std.testing.allocator, "もし、対象が数列か判定ならば\nB=1\nここまで\n", "josi-predicate-suretu.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
    // 公式の関数名は`数列判定`で、`数列か判定`は字句変換で同じ名前に解決する。
    try std.testing.expectEqualStrings("数列判定", condition.name);
    try std.testing.expectEqual(@as(usize, 1), condition.children.len);
    try std.testing.expectEqualStrings("対象", condition.children[0].value);
}

test "「Aが奇数でなければ」を既知命令の条件否定へ変換する" {
    var result = try parse(std.testing.allocator, "もし、Aが奇数でなければ\nB=1\nここまで\n", "josi-predicate-odd-not.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.unary_operator, condition.kind);
    try std.testing.expectEqualStrings("not", condition.operator);
    try std.testing.expectEqual(ast.Kind.function_call, condition.children[0].kind);
    try std.testing.expectEqualStrings("奇数", condition.children[0].name);
    try std.testing.expectEqualStrings("A", condition.children[0].children[0].value);
}

test "「DにAが辞書キー存在するならば」を助詞呼出しの条件式へ変換する" {
    var result = try parse(std.testing.allocator, "もし、Dに\"a\"が辞書キー存在するならば\nB=1\nここまで\n", "josi-dict.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
    try std.testing.expectEqualStrings("辞書キー存在", condition.name);
    try std.testing.expectEqualStrings("D", condition.children[0].value);
    try std.testing.expectEqualStrings("に", condition.children[0].josi);
    try std.testing.expectEqualStrings("a", condition.children[1].value);
    try std.testing.expectEqualStrings("が", condition.children[1].josi);
}

test "「存在しなければ」を助詞呼出しの条件否定へ変換する" {
    var result = try parse(std.testing.allocator, "もし、Dに\"a\"が辞書キー存在しなければ\nB=1\nここまで\n", "josi-dict-not.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.unary_operator, condition.kind);
    try std.testing.expectEqualStrings("not", condition.operator);
    try std.testing.expectEqual(ast.Kind.function_call, condition.children[0].kind);
    try std.testing.expectEqualStrings("辞書キー存在", condition.children[0].name);
}

test "「もし」省略形の「AがBと等しいならば」を条件文にする" {
    var result = try parse(std.testing.allocator, "Aが5と等しいならば\nB=1\n違えば\nB=2\nここまで\n", "implicit-if.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.if_statement, statement.kind);
    try std.testing.expectEqual(ast.Kind.function_call, statement.children[0].kind);
    try std.testing.expectEqualStrings("等", statement.children[0].name);
}

test "括弧付きの助詞呼出し条件式を受理する" {
    var result = try parse(std.testing.allocator, "もし、(Aが3以下)ならば\nB=1\nここまで\n", "grouped-josi-call.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
    try std.testing.expectEqualStrings("以下", condition.name);
    try std.testing.expectEqualStrings("", condition.josi);
}

test "「Aが5以下の間」を助詞呼出しの条件式にする" {
    var result = try parse(std.testing.allocator, "Aが5以下の間\nA=A+1\nここまで\n", "josi-while.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.while_statement, statement.kind);
    const condition = statement.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
    try std.testing.expectEqualStrings("以下", condition.name);
    try std.testing.expectEqualStrings("の", condition.josi);
    try std.testing.expectEqual(@as(usize, 2), condition.children.len);
}

test "後判定の括弧付き助詞呼出し条件式を受理する" {
    var result = try parse(std.testing.allocator, "後判定\nA=A+1\nここまで,(Aが3以下)の間\n", "josi-post-test.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.post_test_loop, statement.kind);
    const condition = statement.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
    try std.testing.expectEqualStrings("以下", condition.name);
    try std.testing.expectEqualStrings("の", condition.josi);
}

test "助詞付き命令呼出しの直後の「戻る」は呼出し結果を戻り値にする" {
    // 公式`yCall`は助詞付きの関数呼出しをスタックに積んだまま`yReturn`へ渡し、
    // `yReturn`は『で』『を』助詞の要素を戻り値として取り出す。
    // lnakoでは助詞付き変数と同じく、呼出しを『戻る』の直前の引数として保持する。
    const cases = [_]struct { source: []const u8, filename: []const u8, name: []const u8, josi: []const u8 }{
        .{ .source = "●Fとは\n「abc」の要素数で戻る\nここまで\n", .filename = "return-josi-de.nako3", .name = "要素数", .josi = "で" },
        .{ .source = "●Fとは\n「abc」の要素数を戻る\nここまで\n", .filename = "return-josi-wo.nako3", .name = "要素数", .josi = "を" },
        .{ .source = "●Fとは\n1と2を足すで戻る\nここまで\n", .filename = "return-josi-tasu.nako3", .name = "足", .josi = "で" },
        .{ .source = "●Fとは\n「abc」の大文字変換で戻る\nここまで\n", .filename = "return-josi-case.nako3", .name = "大文字変換", .josi = "で" },
        // 連文助詞でも公式は`return それ`で同じ値を返すため、呼出しを戻り値にする。
        .{ .source = "●Fとは\n「abc」の要素数して戻る\nここまで\n", .filename = "return-josi-shite.nako3", .name = "要素数", .josi = "して" },
    };
    for (cases) |case| {
        var result = try parse(std.testing.allocator, case.source, case.filename);
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        const definition = result.root.?.children[0];
        try std.testing.expectEqual(ast.Kind.function_definition, definition.kind);
        const body = definition.children[0];
        const statement = body.children[0];
        try std.testing.expectEqual(ast.Kind.return_statement, statement.kind);
        const value = statement.children[0];
        try std.testing.expectEqual(ast.Kind.function_call, value.kind);
        try std.testing.expectEqualStrings(case.name, value.name);
        // 命令呼出し自身の助詞は保持される。
        try std.testing.expectEqualStrings(case.josi, value.josi);
    }
}

test "取り込み先の関数呼出し候補を『戻る』の直前で実引数付きの語として保持する" {
    // Issue #297: 取り込み先の関数はこのファイルの解析時点ではfunclistに
    // 無い。`2を倍算で戻る`の`倍算`を値として固定すると実引数`2`が失われ、
    // 取り込み後に呼出しへ解決できない。公式`yReturn`の直前呼出しと同じく、
    // 実引数を子に持つ語として残し、意味解析で関数か変数を決める。
    var result = try parse(
        std.testing.allocator,
        "●呼出とは\n2を倍算で戻る。\nここまで\n",
        "imported-return-candidate.nako3",
    );
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const body = result.root.?.children[0].children[0];
    const statement = body.children[0];
    try std.testing.expectEqual(ast.Kind.return_statement, statement.kind);
    const value = statement.children[0];
    try std.testing.expectEqual(ast.Kind.word, value.kind);
    try std.testing.expectEqualStrings("倍算", value.value);
    try std.testing.expectEqualStrings("で", value.josi);
    try std.testing.expectEqual(@as(usize, 1), value.children.len);
    try std.testing.expectEqual(ast.Kind.number, value.children[0].kind);
    try std.testing.expectEqualStrings("2", value.children[0].value);
    try std.testing.expectEqualStrings("を", value.children[0].josi);

    // 変数なら従来どおり語として戻り値になる（子は持たない）。
    var variable = try parse(
        std.testing.allocator,
        "●Fとは\nA=2\nAで戻る\nここまで\n",
        "variable-return-candidate.nako3",
    );
    defer variable.deinit();
    try std.testing.expect(variable.succeeded());
    const variable_body = variable.root.?.children[0].children[0];
    var variable_return: ?*ast.Node = null;
    for (variable_body.children) |child| {
        if (child.kind == .return_statement) variable_return = child;
    }
    const fallback = variable_return orelse return error.MissingReturn;
    try std.testing.expectEqual(ast.Kind.word, fallback.children[0].kind);
    try std.testing.expectEqualStrings("A", fallback.children[0].value);
    try std.testing.expectEqual(@as(usize, 0), fallback.children[0].children.len);
}

test "組み込みの範囲に一致する助詞がなければ外側の引数を全て残す" {
    var result = try parse(std.testing.allocator, "1と範囲を表示\n", "main.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    try std.testing.expectEqualStrings("表示", display.name);
    try std.testing.expectEqual(@as(usize, 2), display.children.len);
    try std.testing.expectEqualStrings("1", display.children[0].value);
    const range = display.children[1];
    try std.testing.expectEqualStrings("範囲", range.name);
    try std.testing.expectEqual(@as(usize, 0), range.children.len);
}

test "利用者が定義した範囲を連鎖とC風呼出しの引数で組み込み扱いしない" {
    const definition = "●(XからYを)範囲とは\nXで戻る\nここまで\n";
    const cases = [_][]const u8{ "2から3を範囲を表示\n", "表示(2から3を範囲)\n" };
    for (cases) |line| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ line, definition });
        defer std.testing.allocator.free(source);
        var result = try parse(std.testing.allocator, source, "main.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        const display = result.root.?.children[0];
        try std.testing.expectEqualStrings("表示", display.name);
        try std.testing.expectEqual(@as(usize, 1), display.children.len);
        const range = display.children[0];
        try std.testing.expectEqualStrings("範囲", range.name);
        try std.testing.expectEqual(@as(usize, 2), range.children.len);
        try std.testing.expectEqualStrings("3", range.children[1].value);
        try std.testing.expectEqualStrings("を", range.children[1].josi);
    }
}

test "同名の仮引数に束縛される範囲は連鎖内で実引数を全て保持する" {
    const source =
        "●(範囲を)確認とは\n" ++
        "2から3を範囲を表示\n" ++
        "JSONエンコード(2から3を範囲)を表示\n" ++
        "ここまで\n";
    var parsed = try parse(std.testing.allocator, source, "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    const body = parsed.root.?.children[0].children[0];
    const statement_range = body.children[0].children[0];
    const expression_range = body.children[2].children[0].children[0];
    for ([_]*ast.Node{ statement_range, expression_range }) |call| {
        try std.testing.expectEqualStrings("範囲", call.name);
        try std.testing.expectEqual(@as(usize, 2), call.children.len);
        try std.testing.expectEqualStrings("から", call.children[0].josi);
        try std.testing.expectEqualStrings("を", call.children[1].josi);
    }
}

test "片端省略の範囲を『それ』で補完し外側の引数を参照へ残す" {
    // Issue #297: 公式`yCallFunc`は範囲の助詞スロットに一致する引数だけを
    // 消費する。`Aの4まで`では`Aの`が外側の参照の第1引数として残り、
    // 欠けた開始位置は『それ』で補完される。
    var missing_start = try parse(
        std.testing.allocator,
        "A=[0,1,2,3,4,5]\nそれ=2\nAの4までの範囲を参照してJSONエンコードして表示。\n",
        "range-missing-start.nako3",
    );
    defer missing_start.deinit();
    try std.testing.expect(missing_start.succeeded());
    const start_reference = findCallNamed(missing_start.root.?, "参照") orelse return error.MissingReferenceCall;
    try std.testing.expectEqual(@as(usize, 2), start_reference.children.len);
    try std.testing.expectEqualStrings("A", start_reference.children[0].value);
    try std.testing.expectEqualStrings("の", start_reference.children[0].josi);
    const start_range = start_reference.children[1];
    try std.testing.expectEqualStrings("範囲", start_range.name);
    try std.testing.expectEqual(@as(usize, 2), start_range.children.len);
    try std.testing.expectEqual(ast.Kind.word, start_range.children[0].kind);
    try std.testing.expectEqualStrings("それ", start_range.children[0].value);
    try std.testing.expectEqualStrings("4", start_range.children[1].value);
    try std.testing.expectEqualStrings("までの", start_range.children[1].josi);

    // `Aから2から範囲`では2番目の『から』が開始位置、外側の`Aから`が残る。
    var missing_end = try parse(
        std.testing.allocator,
        "A=[0,1,2,3,4,5]\nそれ=4\nAから2から範囲を参照してJSONエンコードして表示。\n",
        "range-missing-end.nako3",
    );
    defer missing_end.deinit();
    try std.testing.expect(missing_end.succeeded());
    const end_reference = findCallNamed(missing_end.root.?, "参照") orelse return error.MissingReferenceCall;
    try std.testing.expectEqual(@as(usize, 2), end_reference.children.len);
    try std.testing.expectEqualStrings("A", end_reference.children[0].value);
    try std.testing.expectEqualStrings("から", end_reference.children[0].josi);
    const end_range = end_reference.children[1];
    try std.testing.expectEqualStrings("範囲", end_range.name);
    try std.testing.expectEqual(@as(usize, 2), end_range.children.len);
    try std.testing.expectEqualStrings("2", end_range.children[0].value);
    try std.testing.expectEqualStrings("から", end_range.children[0].josi);
    try std.testing.expectEqual(ast.Kind.word, end_range.children[1].kind);
    try std.testing.expectEqualStrings("それ", end_range.children[1].value);

    // 括弧内の式でも同じスロット選択を行い、`Aの`を外側へ残す。
    var parenthesized = try parse(
        std.testing.allocator,
        "JSONエンコード(Aの2から4までの範囲を参照)を表示。\n",
        "range-parenthesized.nako3",
    );
    defer parenthesized.deinit();
    try std.testing.expect(parenthesized.succeeded());
    const paren_reference = findCallNamed(parenthesized.root.?, "参照") orelse return error.MissingReferenceCall;
    try std.testing.expectEqual(@as(usize, 2), paren_reference.children.len);
    try std.testing.expectEqualStrings("A", paren_reference.children[0].value);
    try std.testing.expectEqualStrings("の", paren_reference.children[0].josi);
    const paren_range = paren_reference.children[1];
    try std.testing.expectEqualStrings("範囲", paren_range.name);
    try std.testing.expectEqual(@as(usize, 2), paren_range.children.len);
    try std.testing.expectEqualStrings("2", paren_range.children[0].value);
    try std.testing.expectEqualStrings("から", paren_range.children[0].josi);
    try std.testing.expectEqualStrings("4", paren_range.children[1].value);
    try std.testing.expectEqualStrings("までの", paren_range.children[1].josi);
}

test "連文の途中でも「戻る」は直前の呼出し・値を戻り値にする" {
    // 公式は『して』で文が切れるため、続く助詞付き呼出しや値は新しい文として
    // `yReturn`の対象になる。lnakoは先行する連文を保持したまま、最後の
    // 呼出し・値を戻り値にしたブロックを組み立てる。
    var call = try parse(std.testing.allocator, "●Fとは\n「x」と表示して「abc」の要素数で戻る\nここまで\n", "return-chained-call.nako3");
    defer call.deinit();
    try std.testing.expect(call.succeeded());
    const call_body = call.root.?.children[0].children[0];
    const call_block = call_body.children[0];
    try std.testing.expectEqual(ast.Kind.block, call_block.kind);
    try std.testing.expectEqual(@as(usize, 2), call_block.children.len);
    try std.testing.expectEqual(ast.Kind.function_call, call_block.children[0].kind);
    try std.testing.expectEqualStrings("表示", call_block.children[0].name);
    const call_return = call_block.children[1];
    try std.testing.expectEqual(ast.Kind.return_statement, call_return.kind);
    try std.testing.expectEqual(ast.Kind.function_call, call_return.children[0].kind);
    try std.testing.expectEqualStrings("要素数", call_return.children[0].name);

    // 連文のあとの助詞付き変数も先行呼出しを実行してから戻り値になる。
    var variable = try parse(std.testing.allocator, "●Fとは\n「x」と表示して「abc」を戻る\nここまで\n", "return-chained-var.nako3");
    defer variable.deinit();
    try std.testing.expect(variable.succeeded());
    const variable_body = variable.root.?.children[0].children[0];
    const variable_block = variable_body.children[0];
    try std.testing.expectEqual(ast.Kind.block, variable_block.kind);
    try std.testing.expectEqual(@as(usize, 2), variable_block.children.len);
    try std.testing.expectEqual(ast.Kind.return_statement, variable_block.children[1].kind);

    // 連文助詞『して』の直後の「戻る」は呼出し自体が戻り値になる。
    // 公式は『して』で文が切れて`return それ`（＝直前呼出しの結果）になるので同じ値。
    var direct = try parse(std.testing.allocator, "●Fとは\n「x」と表示して戻る\nここまで\n", "return-chained-direct.nako3");
    defer direct.deinit();
    try std.testing.expect(direct.succeeded());
    const direct_body = direct.root.?.children[0].children[0];
    const direct_statement = direct_body.children[0];
    try std.testing.expectEqual(ast.Kind.return_statement, direct_statement.kind);
    try std.testing.expectEqual(ast.Kind.function_call, direct_statement.children[0].kind);
    try std.testing.expectEqualStrings("表示", direct_statement.children[0].name);

    // 連文ブロックの末尾にある裸の「戻る」も先行呼出しを落とさない。
    var bare = try parse(std.testing.allocator, "●Fとは\n「x」と表示して「a」と表示して戻る\nここまで\n", "return-chained-bare.nako3");
    defer bare.deinit();
    try std.testing.expect(bare.succeeded());
    const bare_body = bare.root.?.children[0].children[0];
    const bare_block = bare_body.children[0];
    try std.testing.expectEqual(ast.Kind.block, bare_block.kind);
    try std.testing.expectEqual(ast.Kind.return_statement, bare_block.children[bare_block.children.len - 1].kind);
}

test "「戻る」の戻り値は助詞付き命令呼出しの有無で切り替わる" {
    // 助詞付き変数は従来どおり直前の引数として戻り値になる。
    var variable = try parse(std.testing.allocator, "●Fとは\nそれは5\nそれを戻る\nここまで\n", "return-sore.nako3");
    defer variable.deinit();
    try std.testing.expect(variable.succeeded());
    const variable_body = variable.root.?.children[0].children[0];
    var variable_statement: ?*ast.Node = null;
    for (variable_body.children) |child| {
        if (child.kind == .return_statement) variable_statement = child;
    }
    try std.testing.expect(variable_statement != null);
    try std.testing.expect(variable_statement.?.children[0].kind != .nop);

    // 直前に引数が無い「戻る」は暗黙の『それ』を返す。
    var bare = try parse(std.testing.allocator, "●Fとは\n戻る\nここまで\n", "return-bare.nako3");
    defer bare.deinit();
    try std.testing.expect(bare.succeeded());
    const bare_body = bare.root.?.children[0].children[0];
    var bare_statement: ?*ast.Node = null;
    for (bare_body.children) |child| {
        if (child.kind == .return_statement) bare_statement = child;
    }
    try std.testing.expect(bare_statement != null);
    try std.testing.expectEqual(ast.Kind.word, bare_statement.?.children[0].kind);
    try std.testing.expectEqualStrings("それ", bare_statement.?.children[0].value);
}

test "条件助詞付き呼出しの直後の「戻る」は条件文の分岐になる" {
    // `Aが1と等しいならば戻る`は『もし』省略形の条件文。条件呼出しを『戻る』の
    // 戻り値にすると、条件が偽でも無条件に真偽値を返してしまうため、
    // 呼出しは条件式として`parseIfThen`へ委ねる。
    var result = try parse(std.testing.allocator, "●Fとは\nAが1と等しいならば戻る\n9で戻る\nここまで\n", "return-cond-naraba.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const body = result.root.?.children[0].children[0];
    const if_node = body.children[0];
    try std.testing.expectEqual(ast.Kind.if_statement, if_node.kind);
    const condition = if_node.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, condition.kind);
    try std.testing.expectEqualStrings("等", condition.name);
    const true_block = if_node.children[1];
    try std.testing.expectEqual(ast.Kind.return_statement, true_block.children[0].kind);
    // 条件が偽のときの『9で戻る』は別の文として残る。
    var fallback: ?*ast.Node = null;
    for (body.children) |child| {
        if (child.kind == .return_statement) fallback = child;
    }
    try std.testing.expect(fallback != null);
    try std.testing.expectEqual(ast.Kind.number, fallback.?.children[0].kind);

    // 否定条件助詞も同じく条件文へ昇格させる（条件式はnotで包まれる）。
    var negative = try parse(std.testing.allocator, "●Fとは\nAが1と等しいでなければ戻る\nここまで\n", "return-cond-denakereba.nako3");
    defer negative.deinit();
    try std.testing.expect(negative.succeeded());
    const negative_if = negative.root.?.children[0].children[0].children[0];
    try std.testing.expectEqual(ast.Kind.if_statement, negative_if.kind);
    try std.testing.expectEqual(ast.Kind.unary_operator, negative_if.children[0].kind);
}

test "条件助詞付き呼出しのあとに値が続いても条件文になる" {
    // `Aが1と等しいならばAを戻る`は『もし』省略形。語が続く場合に呼出しを
    // 引数チェーンへ入れると条件文を構成できず実行時エラーになるため、
    // 条件助詞は引数継続の対象にしない。
    var result = try parse(std.testing.allocator, "●(Aの)Fとは\nAが1と等しいならばAを戻る\nここまで\n", "return-cond-arg.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const body = result.root.?.children[0].children[0];
    const if_node = body.children[0];
    try std.testing.expectEqual(ast.Kind.if_statement, if_node.kind);
    const true_block = if_node.children[1];
    try std.testing.expectEqual(ast.Kind.return_statement, true_block.children[0].kind);
    try std.testing.expectEqual(ast.Kind.word, true_block.children[0].children[0].kind);

    // `XしてYならばZ`は連文の末尾の呼出しを条件文へ昇格させる。
    var chained = try parse(std.testing.allocator, "●Fとは\n「x」と表示してAが1と等しいならば戻る\nここまで\n", "return-cond-chained.nako3");
    defer chained.deinit();
    try std.testing.expect(chained.succeeded());
    const chained_body = chained.root.?.children[0].children[0];
    const chained_block = chained_body.children[0];
    try std.testing.expectEqual(ast.Kind.block, chained_block.kind);
    try std.testing.expectEqual(@as(usize, 2), chained_block.children.len);
    try std.testing.expectEqual(ast.Kind.function_call, chained_block.children[0].kind);
    try std.testing.expectEqualStrings("表示", chained_block.children[0].name);
    const chained_if = chained_block.children[1];
    try std.testing.expectEqual(ast.Kind.if_statement, chained_if.kind);
    try std.testing.expectEqual(ast.Kind.function_call, chained_if.children[0].kind);
    try std.testing.expectEqualStrings("等", chained_if.children[0].name);
}

test "「もし」省略形は命令呼出しのときだけ条件文にする" {
    // 公式`ySentence`は`yCall`が命令呼出しで確定した場合だけ`yIfThen`へ入る。
    // 演算式や数値は公式と同じく『不完全な文です』で拒否する。
    var number = try parse(std.testing.allocator, "1ならば\n", "implicit-if-number.nako3");
    defer number.deinit();
    try std.testing.expect(!number.succeeded());

    // 単独語は変数参照と区別できないため、既知の命令名でなければ条件文にしない。
    var word = try parse(std.testing.allocator, "Aならば\n", "implicit-if-word.nako3");
    defer word.deinit();
    try std.testing.expect(word.succeeded());
    try std.testing.expectEqual(ast.Kind.function_call, word.root.?.children[0].kind);
    try std.testing.expect(!word.root.?.children[0].is_c_style_call);

    // 未定義語の助詞付き呼出しは公式も未解決語として拒否するため条件文にしない。
    var undefined_call = try parse(std.testing.allocator, "1を未定義Fならば\n", "implicit-if-undefined.nako3");
    defer undefined_call.deinit();
    try std.testing.expect(undefined_call.succeeded());
    try std.testing.expectEqual(ast.Kind.function_call, undefined_call.root.?.children[0].kind);

    // 既知の命令名（公式の`func token`）の0引数呼出しは命令呼出しなので条件文になる。
    var command = try parse(std.testing.allocator, "今ならば\n「x」と表示\nここまで\n", "implicit-if-command.nako3");
    defer command.deinit();
    try std.testing.expect(command.succeeded());
    try std.testing.expectEqual(ast.Kind.if_statement, command.root.?.children[0].kind);
    try std.testing.expectEqual(ast.Kind.function_call, command.root.?.children[0].children[0].kind);
    try std.testing.expectEqualStrings("今", command.root.?.children[0].children[0].name);
}

test "命令呼出しを構成しない裸の式文は不完全な文として拒否する" {
    // 公式`ySentence`は文の末尾に残った値を『不完全な文です』で拒否する。
    // 式文として実行系へ流すと`1+1`のような演算式が動的実行へ変換されて
    // 再解析を繰り返し実行上限超過になるため、構文解析時点で拒否する。
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "1+1\n", .message = "不完全な文です。演算子『+』が解決していません" },
        .{ .source = "１＋１\n", .message = "不完全な文です。演算子『+』が解決していません" },
        .{ .source = "A+1\n", .message = "不完全な文です。演算子『+』が解決していません" },
        .{ .source = "1\n", .message = "不完全な文です。数値1が解決していません" },
        .{ .source = "1.5\n", .message = "不完全な文です。数値1.5が解決していません" },
        .{ .source = "「あ」\n", .message = "不完全な文です。文字列『あ』が解決していません" },
        .{ .source = "「1+2を表示」\n", .message = "不完全な文です。文字列『1+2を表示』が解決していません" },
        .{ .source = "[1,2]\n", .message = "不完全な文です。『json_array』が解決していません" },
        .{ .source = "{「a」:1}\n", .message = "不完全な文です。『json_obj』が解決していません" },
        .{ .source = "A[0]\n", .message = "不完全な文です。『ref_array』が解決していません" },
        .{ .source = "A.B\n", .message = "不完全な文です。『ref_prop』が解決していません" },
        // 公式のref_array/ref_propは裸のword起点だけ。括弧済み・値への
        // 後置アクセスはref_array_value（`『@』`/`『$』`）、`A[0].B`は
        // 公式では同一ref_arrayへ吸収される。
        .{ .source = "[1,2][0]\n", .message = "不完全な文です。『@』が解決していません" },
        .{ .source = "[{x:1}].x\n", .message = "不完全な文です。『$』が解決していません" },
        .{ .source = "(A)[0]\n", .message = "不完全な文です。『@』が解決していません" },
        .{ .source = "(A).x\n", .message = "不完全な文です。『$』が解決していません" },
        .{ .source = "A[0].B\n", .message = "不完全な文です。『ref_array』が解決していません" },
        .{ .source = "!A\n", .message = "不完全な文です。演算子『not』が解決していません" },
        .{ .source = "「a」と「b」\n", .message = "不完全な文です。文字列『a』、文字列『b』が解決していません" },
        .{ .source = "1 2\n", .message = "不完全な文です。数値1、数値2が解決していません" },
        .{ .source = "F(1)+1\n", .message = "不完全な文です。演算子『+』が解決していません" },
        .{ .source = "F(1)(2)\n", .message = "不完全な文です。『call_value』が解決していません" },
    };
    for (cases) |case| {
        var result = try parse(std.testing.allocator, case.source, "bare-expression.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqual(diagnostic.Code.incomplete_statement, result.diagnostics[0].code);
        try std.testing.expectEqualStrings(case.message, result.diagnostics[0].message);
    }

    // 範囲演算子の疑似呼出しも命令呼出しではないため『不完全な文です』で拒否する。
    var range = try parse(std.testing.allocator, "1…5\n", "bare-range.nako3");
    defer range.deinit();
    try std.testing.expect(!range.succeeded());
    try std.testing.expectEqualStrings("不完全な文です。関数『範囲』が解決していません", range.diagnostics[0].message);

    // 単独語は変数参照と区別できないため従来どおり命令呼出しとして扱う。
    var word = try parse(std.testing.allocator, "A\n", "bare-word.nako3");
    defer word.deinit();
    try std.testing.expect(word.succeeded());
    try std.testing.expectEqual(ast.Kind.function_call, word.root.?.children[0].kind);
}

test "無名関数の本体先頭語を関数名として登録しない" {
    // 無名関数の`関数`キーワードも`def_func`になるため、定義の直後の識別子は
    // 本体の先頭語（この例では「それ」）であって関数名ではない。
    var result = try parse(std.testing.allocator, "F=関数(A)\nそれはA+1\nここまで\nそれならば\n「x」と表示\nここまで\n", "anonymous-func-body.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
}

test "条件分岐の「違えば」節を同じ行で閉じる形を受理する" {
    // 公式`ySwitch`は『違えば』とペアの『ここまで』を消費し、続けて
    // 『条件分岐』本体の『ここまで』も消費する。
    const cases = [_]struct { source: []const u8, filename: []const u8 }{
        .{ .source = "Nで条件分岐\n1ならば、「1」と表示。ここまで。\n2ならば、「2」と表示。ここまで。\n違えば、「@」と表示。ここまで。\nここまで。\n", .filename = "switch-else-inline.nako3" },
        // 『違えば』節が本体の終端を兼ねる形（本体の『ここまで』が1つだけ）。
        .{ .source = "Nで条件分岐\n1ならば、「1」と表示。ここまで。\n違えば、「@」と表示。\nここまで。\n", .filename = "switch-else-shared-end.nako3" },
        // 節を複数行で書く形。
        .{ .source = "Nで条件分岐\n1ならば\n「1」と表示\nここまで\n違えば\n「@」と表示\nここまで\nここまで\n", .filename = "switch-else-multiline.nako3" },
        // 『違えば』のあとに読点が続く形。
        .{ .source = "Nで条件分岐\n1ならば、「1」と表示。ここまで。\n違えば、\n「@」と表示\nここまで\nここまで\n", .filename = "switch-else-comma.nako3" },
    };
    for (cases) |case| {
        var result = try parse(std.testing.allocator, case.source, case.filename);
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        try std.testing.expectEqual(ast.Kind.switch_statement, result.root.?.children[0].kind);
    }
}

test "単文の「もし〜ならば」に次行の「違えば」を繋げる" {
    // 公式`yIfThen`は真節のあとの改行を読み飛ばしてから『違えば』を調べる。
    // ドキュメント自身が v3.2.27 以前の記法として注記する形だが公式は受理する。
    const cases = [_]struct { source: []const u8, filename: []const u8 }{
        .{ .source = "もし、A=1ならば、「OK」と表示。\n違えば、「NG」と表示。\n", .filename = "single-statement-else.nako3" },
        .{ .source = "もし、A=1ならば、「OK」と表示。\n違えば\n「NG」と表示\n", .filename = "single-statement-else-multiline.nako3" },
        .{ .source = "もし、A=1ならば、「OK」と表示。\n\n違えば、「NG」と表示。\n", .filename = "single-statement-else-blank.nako3" },
    };
    for (cases) |case| {
        var result = try parse(std.testing.allocator, case.source, case.filename);
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        const statement = result.root.?.children[0];
        try std.testing.expectEqual(ast.Kind.if_statement, statement.kind);
        try std.testing.expectEqual(@as(usize, 3), statement.children.len);
    }
}

test "単文の「もし〜ならば」の「違えば」に続けて文を書ける" {
    var result = try parse(std.testing.allocator, "もし、A=1ならば、「OK」と表示。\n違えば、「NG」と表示。\n「あと」と表示。\n", "single-statement-else-next.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqual(ast.Kind.if_statement, result.root.?.children[0].kind);
}

test "単文の「もし〜ならば」に終端の「ここまで」は不要" {
    // 公式`yIfThen`は真節が単文のとき`ここまで`を要求しないため、
    // 末尾に`ここまで`を書くと公式も『『ここまで』の使い方が間違っています』で拒否する。
    var result = try parse(std.testing.allocator, "もし、A=1ならば、「OK」と表示。\n違えば、「NG」と表示。\nここまで\n", "single-statement-else-end.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
}

test "範囲演算式を「もし」省略形の条件文へ昇格しない" {
    // 公式は範囲を`func`ノードにするが、`yCall`のスタックが残るため
    // `1…2ならば`は『不完全な文です』で拒否する。
    var result = try parse(std.testing.allocator, "1…2ならば\n「x」と表示\nここまで\n", "range-if.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
}

test "ユーザー定義関数を単独語の条件として命令呼出しにする" {
    // 公式`preDefineFunc`と同じくトークンを先読みするため、後方定義でも解決する。
    const cases = [_]struct { source: []const u8, filename: []const u8, name: []const u8 }{
        .{ .source = "Fならば\n「x」と表示\nここまで\n●Fとは\nはいで戻る\nここまで\n", .filename = "user-func-if.nako3", .name = "F" },
        // 属性付き・名前の前後に引数宣言が来る定義形も関数名として集める。
        .{ .source = "●{公開}Fとは\nはいで戻る\nここまで\nFならば\n「x」と表示\nここまで\n", .filename = "user-func-attr-if.nako3", .name = "F" },
        .{ .source = "●(Aを)Gとは\nAで戻る\nここまで\nGならば\n「x」と表示\nここまで\n", .filename = "user-func-leading-args-if.nako3", .name = "G" },
        // 助詞付きの引数でも、ユーザー定義関数を条件式の命令呼出しへ解決する。
        .{ .source = "もし、1をFならば\n「x」と表示\nここまで\n●(Aを)Fとは\nAで戻る\nここまで\n", .filename = "user-func-josi-call-if.nako3", .name = "F" },
    };
    for (cases) |case| {
        var result = try parse(std.testing.allocator, case.source, case.filename);
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        var promoted = false;
        for (result.root.?.children) |child| {
            if (child.kind != .if_statement) continue;
            promoted = true;
            try std.testing.expectEqual(ast.Kind.function_call, child.children[0].kind);
            try std.testing.expectEqualStrings(case.name, child.children[0].name);
        }
        try std.testing.expect(promoted);
    }
}

test "「なければ」を条件の否定として扱う" {
    var result = try parse(std.testing.allocator, "もし、Aなければ\nB=1\nここまで\n", "josi-nakereba.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const condition = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.unary_operator, condition.kind);
    try std.testing.expectEqualStrings("not", condition.operator);
    try std.testing.expectEqualStrings("A", condition.children[0].value);
    try std.testing.expectEqualStrings("", condition.children[0].josi);
}

test "括弧付き演算子の助詞を内部式へ伝播しない" {
    var result = try parse(std.testing.allocator, "(-1>\"\")を反復\n対象を表示\nここまで\n", "grouped-josi.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const collection = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, collection.kind);
    try std.testing.expectEqualStrings("gt", collection.operator);
    try std.testing.expectEqualStrings("を", collection.josi);
    try std.testing.expectEqual(ast.Kind.binary_operator, collection.children[0].kind);
    try std.testing.expectEqualStrings("", collection.children[0].josi);
    try std.testing.expectEqualStrings("", collection.children[0].children[0].josi);
}

test "回だけの繰り返しは公式同様に暗黙のそれを回数へ使う" {
    var result = try parse(std.testing.allocator, "回\nここまで\n", "implicit-repeat-count.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const repeat = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.repeat_times, repeat.kind);
    try std.testing.expectEqual(ast.Kind.word, repeat.children[0].kind);
    try std.testing.expectEqualStrings("それ", repeat.children[0].value);
}

test "それは構文を暗黙戻り値への代入として扱う" {
    var result = try parse(std.testing.allocator, "F=関数(A)それはA+1\nここまで\n", "関数.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const function = result.root.?.children[0].children[0];
    const assignment = function.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.assignment, assignment.kind);
    try std.testing.expectEqualStrings("それ", assignment.name);
}

test "には構文をコールバック先頭の命令呼び出しとして扱う" {
    var timer = try parse(std.testing.allocator, "0.01秒後には\n対象を表示\nここまで\n", "timer.nako3");
    defer timer.deinit();
    try std.testing.expect(timer.succeeded());
    const timer_call = timer.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, timer_call.kind);
    try std.testing.expectEqualStrings("秒後", timer_call.name);
    try std.testing.expectEqualStrings("して", timer_call.josi);
    try std.testing.expectEqual(@as(usize, 2), timer_call.children.len);
    try std.testing.expectEqual(ast.Kind.anonymous_function, timer_call.children[0].kind);
    try std.testing.expectEqual(ast.Kind.number, timer_call.children[1].kind);

    var promise = try parse(std.testing.allocator, "動いた時には(成功,失敗)\n成功(9)\nここまで\n", "promise.nako3");
    defer promise.deinit();
    try std.testing.expect(promise.succeeded());
    const promise_call = promise.root.?.children[0];
    try std.testing.expectEqualStrings("動時", promise_call.name);
    try std.testing.expectEqual(ast.Kind.anonymous_function, promise_call.children[0].kind);
    try std.testing.expectEqual(@as(usize, 2), promise_call.children[0].arguments.len);
    try std.testing.expectEqualStrings("成功", promise_call.children[0].arguments[0].name);
    try std.testing.expectEqualStrings("失敗", promise_call.children[0].arguments[1].name);
}

test "配列・辞書・添字代入を構文解析する" {
    var result = try parse(std.testing.allocator, "A={a:1,b:2}\nB=[[0]]\nB[0,1]=A$a\n", "collection.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqual(ast.Kind.object_literal, result.root.?.children[0].children[0].kind);
    try std.testing.expectEqual(ast.Kind.array_assignment, result.root.?.children[4].kind);
}

test "辞書の引用符付き省略値を文字列として構文解析する" {
    var result = try parse(std.testing.allocator, "A={\"a\",\"b\"}\n", "quoted-object.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const object = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.object_literal, object.kind);
    try std.testing.expectEqual(ast.Kind.string, object.children[0].kind);
    try std.testing.expectEqual(ast.Kind.string, object.children[1].kind);
    try std.testing.expectEqual(ast.Kind.string, object.children[2].kind);
    try std.testing.expectEqual(ast.Kind.string, object.children[3].kind);
}

test "数値だけの辞書要素を正規化した数値キーと数値値へ構文解析する" {
    var result = try parse(std.testing.allocator, "A={10,20,001,1.50,1e3,１０}\n", "numeric-shorthand.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const object = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.object_literal, object.kind);
    try std.testing.expectEqual(@as(usize, 12), object.children.len);
    const expected = [_]struct { key: []const u8, value: f64 }{
        .{ .key = "10", .value = 10 },
        .{ .key = "20", .value = 20 },
        .{ .key = "1", .value = 1 },
        .{ .key = "1.5", .value = 1.5 },
        .{ .key = "1000", .value = 1000 },
        .{ .key = "10", .value = 10 },
    };
    for (expected, 0..) |item, index| {
        const key = object.children[index * 2];
        const value = object.children[index * 2 + 1];
        try std.testing.expectEqual(ast.Kind.string, key.kind);
        try std.testing.expectEqualStrings(item.key, key.value);
        try std.testing.expectEqual(ast.Kind.number, value.kind);
        try std.testing.expectEqual(item.value, value.number_value.?);
    }
}

test "u64を超える16進の数値だけの辞書要素を公式のキーへ正規化する" {
    var result = try parse(std.testing.allocator, "A={0x10000000000000000}\n", "numeric-overflow.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const object = result.root.?.children[0].children[0];
    try std.testing.expectEqual(@as(usize, 2), object.children.len);
    try std.testing.expectEqualStrings("18446744073709552000", object.children[0].value);
    try std.testing.expectEqual(@as(f64, 18446744073709551616), object.children[1].number_value.?);
}

test "巨大な基数リテラルは有効桁数からInfinityへ短絡する" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { prefix: []const u8, digit: u8, count: usize }{
        .{ .prefix = "0x", .digit = 'f', .count = 250_000 },
        .{ .prefix = "0x", .digit = 'f', .count = 500_000 },
        .{ .prefix = "0b", .digit = '1', .count = 500_000 },
        .{ .prefix = "0o", .digit = '7', .count = 500_000 },
    };
    for (cases) |case| {
        const digits = try allocator.alloc(u8, case.count);
        defer allocator.free(digits);
        @memset(digits, case.digit);
        const source = try std.fmt.allocPrint(allocator, "{s}{s}を表示\n", .{ case.prefix, digits });
        defer allocator.free(source);
        var result = try parse(allocator, source, "huge-radix.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        const call = result.root.?.children[0];
        try std.testing.expectEqual(ast.Kind.function_call, call.kind);
        try std.testing.expect(std.math.isInf(call.children[0].number_value.?));
    }
}

test "基数リテラルのbinary64境界を正確に丸める" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { prefix: []const u8, digit: u8, count: usize, expected: ?f64 }{
        .{ .prefix = "0x", .digit = 'f', .count = 255, .expected = @exp2(@as(f64, 1020)) },
        .{ .prefix = "0x", .digit = 'f', .count = 256, .expected = null },
        .{ .prefix = "0x1", .digit = '0', .count = 255, .expected = @exp2(@as(f64, 1020)) },
        .{ .prefix = "0x1", .digit = '0', .count = 256, .expected = null },
        .{ .prefix = "0b1", .digit = '0', .count = 1023, .expected = @exp2(@as(f64, 1023)) },
        .{ .prefix = "0b1", .digit = '0', .count = 1024, .expected = null },
        .{ .prefix = "0o1", .digit = '0', .count = 341, .expected = @exp2(@as(f64, 1023)) },
        .{ .prefix = "0o1", .digit = '0', .count = 342, .expected = null },
    };
    for (cases) |case| {
        const digits = try allocator.alloc(u8, case.count);
        defer allocator.free(digits);
        @memset(digits, case.digit);
        const source = try std.fmt.allocPrint(allocator, "{s}{s}を表示\n", .{ case.prefix, digits });
        defer allocator.free(source);
        var result = try parse(allocator, source, "radix-boundary.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        const value = result.root.?.children[0].children[0].number_value.?;
        if (case.expected) |expected| {
            try std.testing.expectEqual(expected, value);
        } else {
            try std.testing.expect(std.math.isInf(value));
        }
    }
}

test "基数リテラルの先頭ゼロを除いて変換する" {
    const allocator = std.testing.allocator;
    const zeros = try allocator.alloc(u8, 500_000);
    defer allocator.free(zeros);
    @memset(zeros, '0');
    const source = try std.fmt.allocPrint(allocator, "0x{s}1を表示\n", .{zeros});
    defer allocator.free(source);
    var result = try parse(allocator, source, "radix-leading-zeros.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqual(@as(f64, 1), result.root.?.children[0].children[0].number_value.?);
}

test "基数リテラルの不正な桁と区切りを従来どおり拒否する" {
    const invalid = [_][]const u8{ "0x\n", "0b2\n", "0o8\n", "0x_\n", "0b_\n" };
    for (invalid) |source| {
        try std.testing.expectError(error.InvalidNumber, parse(std.testing.allocator, source, "invalid-radix.nako3"));
    }
}

test "基数リテラルの区切りを従来どおり除去する" {
    var result = try parse(std.testing.allocator, "0x1_2を表示\n0b1_0を表示\n0o1_0を表示\n", "radix-separator.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const expected = [_]f64{ 18, 2, 8 };
    for (expected, 0..) |value, index| {
        try std.testing.expectEqual(value, result.root.?.children[index * 2].children[0].number_value.?);
    }
}

test "数値だけの辞書要素を明示キーと両順序で混在させ末尾コンマを受理する" {
    var result = try parse(std.testing.allocator, "A={10,a:1}\nB={b:2,20}\nC={30,}\n", "numeric-mixed.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const first = result.root.?.children[0].children[0];
    try std.testing.expectEqualStrings("10", first.children[0].value);
    try std.testing.expectEqual(ast.Kind.number, first.children[1].kind);
    try std.testing.expectEqualStrings("a", first.children[2].value);
    try std.testing.expectEqual(ast.Kind.number, first.children[3].kind);
    const second = result.root.?.children[2].children[0];
    try std.testing.expectEqualStrings("b", second.children[0].value);
    try std.testing.expectEqual(ast.Kind.number, second.children[1].kind);
    try std.testing.expectEqualStrings("20", second.children[2].value);
    try std.testing.expectEqual(ast.Kind.number, second.children[3].kind);
    const third = result.root.?.children[4].children[0];
    try std.testing.expectEqualStrings("30", third.children[0].value);
    try std.testing.expectEqual(ast.Kind.number, third.children[1].kind);
}

test "辞書リテラルの先頭・連続コンマを拒否し末尾コンマを受理する" {
    const invalid = [_][]const u8{ "A={,10}\n", "A={10,,20}\n", "A={,\n10}\n", "A={10,\n,20}\n" };
    for (invalid) |source| {
        var result = try parse(std.testing.allocator, source, "numeric-comma-invalid.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqualStrings("辞書のキーが必要です", result.diagnostics[0].message);
    }

    const valid = [_][]const u8{ "A={10,}\n", "A={10,\n20,}\n", "A={a:1,b:2,}\n", "A={\"a\":1,\"b\":2,}\n" };
    for (valid) |source| {
        var result = try parse(std.testing.allocator, source, "numeric-comma-valid.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
    }
}

test "符号付き・式・数値キーへの値指定を辞書リテラルで拒否する" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "A={-10}\n", .message = "辞書のキーが必要です" },
        .{ .source = "A={+10}\n", .message = "辞書のキーが必要です" },
        .{ .source = "A={1+2}\n", .message = "辞書のキーが必要です" },
        .{ .source = "A={1:2}\n", .message = "数値の辞書キーに値を指定できません" },
    };
    for (cases) |case| {
        var result = try parse(std.testing.allocator, case.source, "numeric-invalid.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqualStrings(case.message, result.diagnostics[0].message);
    }
}

test "公式同様に辞書リテラルの数値キーへの値指定を拒否する" {
    var result = try parse(std.testing.allocator, "A={1:2}\n", "numeric-key.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(diagnostic.Code.expected_name, result.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics[0].span.line);
}

test "公式同様に単項プラスを拒否する" {
    const cases = [_][]const u8{ "(+1)を表示\n", "A=1\n(+A)を表示\n", "(+\"1\")を表示\n" };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "unary-plus.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqual(diagnostic.Code.unexpected_token, result.diagnostics[0].code);
        try std.testing.expectEqualStrings("単項『+』は使用できません", result.diagnostics[0].message);
    }
}

test "変数と定数の角括弧分割宣言を構文解析する" {
    var result = try parse(std.testing.allocator, "変数[A,B]=[1,2]\n定数[C,D]=[3,4]\n", "分割.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const variable_declaration = result.root.?.children[0];
    const constant_declaration = result.root.?.children[2];
    try std.testing.expectEqual(ast.Kind.variable_list_definition, variable_declaration.kind);
    try std.testing.expectEqual(@as(usize, 2), variable_declaration.arguments.len);
    try std.testing.expect(!variable_declaration.is_const);
    try std.testing.expectEqual(ast.Kind.variable_list_definition, constant_declaration.kind);
    try std.testing.expectEqual(@as(usize, 2), constant_declaration.arguments.len);
    try std.testing.expect(constant_declaration.is_const);
}

test "初期値省略と公開属性の宣言を公式同様に構文解析する" {
    // 公式は`変数 A`・`Aとは変数`・`Aとは定数`の初期値を省略でき、その値を0に
    // する。属性は`変数 A{公開}=1`と`Aとは変数{非公開}=3`の両形で受理する。
    const source = "変数 A\nBとは変数\nCとは定数\nDとは定数=50\n" ++
        "変数 E{非公開}=1\n定数 F{公開}=2\nGとは変数{非公開}=3\n";
    var result = try parse(std.testing.allocator, source, "宣言.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const expected = [_]struct { name: []const u8, is_const: bool, is_export: bool, number: ?f64 }{
        .{ .name = "A", .is_const = false, .is_export = true, .number = null },
        .{ .name = "B", .is_const = false, .is_export = true, .number = null },
        .{ .name = "C", .is_const = true, .is_export = true, .number = null },
        .{ .name = "D", .is_const = true, .is_export = true, .number = 50 },
        .{ .name = "E", .is_const = false, .is_export = false, .number = 1 },
        .{ .name = "F", .is_const = true, .is_export = true, .number = 2 },
        .{ .name = "G", .is_const = false, .is_export = false, .number = 3 },
    };
    for (expected, 0..) |declaration, index| {
        const node = result.root.?.children[index * 2];
        try std.testing.expectEqual(ast.Kind.variable_definition, node.kind);
        try std.testing.expectEqualStrings(declaration.name, node.name);
        try std.testing.expectEqual(declaration.is_const, node.is_const);
        try std.testing.expectEqual(declaration.is_export, node.is_export);
        const value = node.children[0];
        if (declaration.number) |number| {
            try std.testing.expectEqual(ast.Kind.number, value.kind);
            try std.testing.expectEqual(number, value.number_value.?);
        } else {
            // 公式は初期値省略をnopブロックにし、コード生成で0にする。
            try std.testing.expectEqual(ast.Kind.nop, value.kind);
        }
    }
}

test "日本語命令形式の宣言もモジュール変数として既定公開する" {
    // `Aを1に定める`は公式でもモジュール変数を定義する。ASTのis_exportは
    // 既定falseなので、意味解析が非公開と解釈しないよう宣言時に明示する。
    var result = try parse(std.testing.allocator, "Aを1に定める\n", "宣言.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const node = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.variable_definition, node.kind);
    try std.testing.expectEqualStrings("A", node.name);
    try std.testing.expect(node.is_export);
}

test "属性付きの変数宣言と初期値なしの定数宣言を公式同様に拒否する" {
    const cases = [_][]const u8{ "変数 A{非公開}\n", "定数 C\n" };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "宣言.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqual(diagnostic.Code.expected_token, result.diagnostics[0].code);
        try std.testing.expectEqualStrings("変数宣言に『=』が必要です", result.diagnostics[0].message);
    }
}

test "公式同様に宣言なしの角括弧分割代入を拒否する" {
    var result = try parse(std.testing.allocator, "[A,B]=[1,2]\n", "分割.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(diagnostic.Code.expected_token, result.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics[0].span.line);
}

test "負のBigIntリテラルと変数への単項マイナスを区別する" {
    var result = try parse(std.testing.allocator, "A=-5n\nB=-A\n", "bigint-minus.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const literal = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.bigint, literal.kind);
    try std.testing.expectEqualStrings("-5n", literal.value);
    const variable_negation = result.root.?.children[2].children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, variable_negation.kind);
    try std.testing.expectEqualStrings("*", variable_negation.operator);
    try std.testing.expectEqualStrings("-1", variable_negation.children[0].value);
    try std.testing.expectEqualStrings("A", variable_negation.children[1].value);
}

test "負の数値リテラルを公式と同じ単一ノードへ畳み込む" {
    var result = try parse(std.testing.allocator, "A=-1.5\nB=A/-1\nF(1/-1)\n", "negative-number.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const literal = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.number, literal.kind);
    try std.testing.expectEqualStrings("-1.5", literal.value);
    try std.testing.expectEqual(@as(?f64, -1.5), literal.number_value);
    const division = result.root.?.children[2].children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, division.kind);
    try std.testing.expectEqual(ast.Kind.number, division.children[1].kind);
    try std.testing.expectEqualStrings("-1", division.children[1].value);
    const c_call = result.root.?.children[4];
    try std.testing.expectEqual(ast.Kind.function_call, c_call.kind);
    try std.testing.expectEqual(ast.Kind.number, c_call.children[0].children[1].kind);
    try std.testing.expectEqualStrings("-1", c_call.children[0].children[1].value);
}

test "公式同様に区切り内の負のBigInt直接指定を拒否する" {
    const rejected = [_][]const u8{
        "A=(-1n)\n",
        "HEX(-1n)\n",
        "A=[-1n]\n",
        "A={x:-1n}\n",
        "A[-1n]=5\n",
    };
    for (rejected) |source| {
        var result = try parse(std.testing.allocator, source, "negative-bigint.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqual(diagnostic.Code.unexpected_token, result.diagnostics[0].code);
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics[0].span.line);
    }
    var workaround = try parse(std.testing.allocator, "A=-1n\nB=(0n-1n)\nC=1/-1n\nD=[1/-1n]\n", "negative-bigint.nako3");
    defer workaround.deinit();
    try std.testing.expect(workaround.succeeded());
}

test "閉じていないブロックを位置付き診断にする" {
    var result = try parse(std.testing.allocator, "もし1=1ならば\nA=1\n", "broken.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(diagnostic.Code.missing_block_end, result.diagnostics[0].code);
    try std.testing.expectEqualStrings("broken.nako3", result.diagnostics[0].file);
}

test "先頭のUTF-8 BOMを本文から構文解析する" {
    var result = try parse(std.testing.allocator, source_mod.utf8_bom ++ "「こんにちは」を表示\n", "bom.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const call = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, call.kind);
    try std.testing.expectEqualStrings("表示", call.name);
}

test "BOM付きソースの診断位置を本文先頭から数える" {
    const bom = source_mod.utf8_bom;
    var result = try parse(std.testing.allocator, bom ++ "A=1\r\nB=\r\n", "bom.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(diagnostic.Code.expected_expression, result.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics[0].span.line);
    try std.testing.expectEqual(@as(usize, 3), result.diagnostics[0].span.column);
    try std.testing.expectEqual(bom.len + "A=1\r\nB=".len, result.diagnostics[0].span.source_start);
}

test "相対nako3取り込みをASTに保持する" {
    var result = try parse(std.testing.allocator, "!「./lib.nako3」を取り込む\n", "main.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const import_node = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.import, import_node.kind);
    try std.testing.expectEqualStrings("./lib.nako3", import_node.value);
}

test "文頭取込と後置を取り込むの両形式をimportノードにする" {
    const cases = [_][]const u8{
        "取込「./lib.nako3」\n",
        "「./lib.nako3」を取り込む\n",
    };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "main.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        const import_node = result.root.?.children[0];
        try std.testing.expectEqual(ast.Kind.import, import_node.kind);
        try std.testing.expectEqualStrings("./lib.nako3", import_node.value);
        try std.testing.expectEqual(@as(usize, 1), result.import_modes.len);
    }
}

test "公式同様に廃止された非同期構文を診断付き空文として継続する" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "逐次実行\n1を表示\n",
            .message = "『逐次実行』構文は廃止されました(https://nadesi.com/v3/doc/go.php?944)。",
        },
        .{
            .source = "!非同期モード\n1を表示\n",
            .message = "『非同期モード』構文は廃止されました(https://nadesi.com/v3/doc/go.php?1028)。",
        },
    };
    for (cases) |item| {
        var result = try parse(std.testing.allocator, item.source, "legacy-async.nako3");
        defer result.deinit();
        try std.testing.expect(result.root != null);
        try std.testing.expect(result.succeeded());
        try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
        try std.testing.expectEqual(diagnostic.Code.legacy_deprecated, result.diagnostics[0].code);
        try std.testing.expectEqual(diagnostic.Severity.error_severity, result.diagnostics[0].severity);
        try std.testing.expectEqualStrings(item.message, result.diagnostics[0].message);
        try std.testing.expect(result.root.?.children.len >= 2);
        try std.testing.expectEqual(ast.Kind.function_call, result.root.?.children[result.root.?.children.len - 2].kind);
    }
}

test "連文の結果を和文代入で受ける" {
    var result = try parse(std.testing.allocator, "「名前は？」と尋ねて名前に代入。\n", "ask.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const block = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, block.kind);
    try std.testing.expectEqual(@as(usize, 2), block.children.len);
    try std.testing.expectEqual(ast.Kind.function_call, block.children[0].kind);
    try std.testing.expectEqualStrings("尋", block.children[0].name);
    try std.testing.expectEqual(ast.Kind.assignment, block.children[1].kind);
    try std.testing.expectEqualStrings("名前", block.children[1].name);
    try std.testing.expectEqual(ast.Kind.word, block.children[1].children[0].kind);
    try std.testing.expectEqualStrings("それ", block.children[1].children[0].value);
}

test "連文の結果を値を先に指定して和文代入" {
    var result = try parse(std.testing.allocator, "Aを計算してBに代入。\n", "calc-assign.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const block = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, block.kind);
    try std.testing.expectEqual(ast.Kind.assignment, block.children[1].kind);
    try std.testing.expectEqualStrings("B", block.children[1].name);
    try std.testing.expectEqual(ast.Kind.word, block.children[1].children[0].kind);
    try std.testing.expectEqualStrings("それ", block.children[1].children[0].value);
}

test "値を先に指定した和文代入" {
    var result = try parse(std.testing.allocator, "1をAに代入。\n", "assign-value-first.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const assignment = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.assignment, assignment.kind);
    try std.testing.expectEqualStrings("A", assignment.name);
    try std.testing.expectEqual(ast.Kind.number, assignment.children[0].kind);
    try std.testing.expectEqualStrings("1", assignment.children[0].value);
}

test "単独の和文代入" {
    var result = try parse(std.testing.allocator, "Aに代入。\n", "assign-lone.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const assignment = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.assignment, assignment.kind);
    try std.testing.expectEqualStrings("A", assignment.name);
    try std.testing.expectEqual(ast.Kind.word, assignment.children[0].kind);
    try std.testing.expectEqualStrings("それ", assignment.children[0].value);
}

test "連文で後続の命令に引数を渡す" {
    var result = try parse(std.testing.allocator, "1を表示して2を表示。\n", "chain-display.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const block = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, block.kind);
    try std.testing.expectEqual(@as(usize, 2), block.children.len);
    try std.testing.expectEqual(ast.Kind.function_call, block.children[0].kind);
    try std.testing.expectEqualStrings("表示", block.children[0].name);
    try std.testing.expectEqual(ast.Kind.number, block.children[0].children[0].kind);
    try std.testing.expectEqualStrings("1", block.children[0].children[0].value);
    try std.testing.expectEqual(ast.Kind.function_call, block.children[1].kind);
    try std.testing.expectEqualStrings("表示", block.children[1].name);
    try std.testing.expectEqual(ast.Kind.number, block.children[1].children[1].kind);
    try std.testing.expectEqualStrings("2", block.children[1].children[1].value);
}

test "連文のあとに続く戻す文をblockへまとめる" {
    var result = try parse(std.testing.allocator, "AにBを足してそれを戻す\n", "chain-return.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const block = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, block.kind);
    try std.testing.expectEqual(@as(usize, 2), block.children.len);
    try std.testing.expectEqual(ast.Kind.function_call, block.children[0].kind);
    try std.testing.expectEqualStrings("足", block.children[0].name);
    try std.testing.expectEqual(ast.Kind.return_statement, block.children[1].kind);
    try std.testing.expectEqual(ast.Kind.word, block.children[1].children[0].kind);
    try std.testing.expectEqualStrings("それ", block.children[1].children[0].value);
}

test "連文のあとに続く制御構文をblockへまとめる" {
    var result = try parse(std.testing.allocator, "AにBを足して3回\n「x」を表示\nここまで\n", "chain-repeat.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const block = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, block.kind);
    try std.testing.expectEqual(@as(usize, 2), block.children.len);
    try std.testing.expectEqual(ast.Kind.function_call, block.children[0].kind);
    try std.testing.expectEqualStrings("足", block.children[0].name);
    try std.testing.expectEqual(ast.Kind.repeat_times, block.children[1].kind);
}

test "連文のあとに続く範囲繰り返しをblockへまとめる" {
    var result = try parse(std.testing.allocator, "1を表示してIを1から3まで繰り返す\nIを表示\nここまで\n", "chain-range.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const block = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, block.kind);
    try std.testing.expectEqual(@as(usize, 2), block.children.len);
    try std.testing.expectEqual(ast.Kind.function_call, block.children[0].kind);
    try std.testing.expectEqualStrings("表示", block.children[0].name);
    const repeat = block.children[1];
    try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
    try std.testing.expectEqualStrings("I", repeat.name);
    try std.testing.expectEqual(ast.Kind.number, repeat.children[0].kind);
    try std.testing.expectEqualStrings("1", repeat.children[0].value);
    try std.testing.expectEqual(ast.Kind.number, repeat.children[1].kind);
    try std.testing.expectEqualStrings("3", repeat.children[1].value);
}

test "連文のあとの変数なし範囲繰り返しは暗黙のそれを範囲引数から除く" {
    var result = try parse(std.testing.allocator, "1を表示して1から3まで繰り返す\nそれを表示\nここまで\n", "chain-range-novar.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const block = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, block.kind);
    try std.testing.expectEqual(@as(usize, 2), block.children.len);
    const repeat = block.children[1];
    try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
    try std.testing.expectEqualStrings("それ", repeat.name);
    try std.testing.expectEqual(ast.Kind.number, repeat.children[0].kind);
    try std.testing.expectEqualStrings("1", repeat.children[0].value);
    try std.testing.expectEqual(ast.Kind.number, repeat.children[1].kind);
    try std.testing.expectEqualStrings("3", repeat.children[1].value);
}

test "連文のあとの範囲繰り返しでユーザー記述の『それを』は除外しない" {
    var result = try parse(std.testing.allocator, "1を表示してそれを1から3まで繰り返す\nそれを表示\nここまで\n", "chain-range-sore.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const block = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, block.kind);
    const repeat = block.children[1];
    try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
    try std.testing.expectEqualStrings("それ", repeat.name);
    try std.testing.expectEqual(ast.Kind.number, repeat.children[0].kind);
    try std.testing.expectEqualStrings("1", repeat.children[0].value);
    try std.testing.expectEqual(ast.Kind.number, repeat.children[1].kind);
    try std.testing.expectEqualStrings("3", repeat.children[1].value);
}

test "『で』助詞の繰り返し変数を前置で受理する" {
    var result = try parse(std.testing.allocator, "Nで1から3まで繰り返す\nNを表示\nここまで\n", "for-de-prefix.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const repeat = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
    try std.testing.expectEqualStrings("N", repeat.name);
    try std.testing.expectEqual(ast.Kind.number, repeat.children[0].kind);
    try std.testing.expectEqualStrings("1", repeat.children[0].value);
    try std.testing.expectEqual(ast.Kind.number, repeat.children[1].kind);
    try std.testing.expectEqualStrings("3", repeat.children[1].value);
}

test "『で』助詞の繰り返し変数を後置で受理する" {
    var result = try parse(std.testing.allocator, "3から5までNで繰り返す\nNを表示\nここまで\n", "for-de-suffix.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const repeat = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
    try std.testing.expectEqualStrings("N", repeat.name);
    try std.testing.expectEqual(ast.Kind.number, repeat.children[0].kind);
    try std.testing.expectEqualStrings("3", repeat.children[0].value);
    try std.testing.expectEqual(ast.Kind.number, repeat.children[1].kind);
    try std.testing.expectEqualStrings("5", repeat.children[1].value);
}

test "範囲オブジェクトの繰り返しは一時変数の先頭/末尾参照を開始値・終了値に展開する" {
    var result = try parse(std.testing.allocator, "Nで1から5の範囲を繰り返す\nNを表示\nここまで\n", "for-range-object.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    // 公式convForは範囲オブジェクトを一度だけ評価するため、先立つ一時変数への
    // 代入文とその『先頭』『末尾』参照のfor_statementへ展開する。
    const sequence = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, sequence.kind);
    const assign = sequence.children[0];
    try std.testing.expectEqual(ast.Kind.assignment, assign.kind);
    try std.testing.expectEqualStrings("繰り返し範囲$一時値}》", assign.name);
    try std.testing.expectEqual(ast.Kind.function_call, assign.children[0].kind);
    try std.testing.expectEqualStrings("範囲", assign.children[0].name);
    try std.testing.expectEqual(@as(usize, 2), assign.children[0].children.len);
    const repeat = sequence.children[1];
    try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
    try std.testing.expectEqualStrings("N", repeat.name);
    const edge_keys = [_][]const u8{ "先頭", "末尾" };
    for (edge_keys, 0..) |key, i| {
        const edge = repeat.children[i];
        try std.testing.expectEqual(ast.Kind.array_value_reference, edge.kind);
        try std.testing.expectEqual(ast.Kind.word, edge.children[0].kind);
        try std.testing.expectEqualStrings("繰り返し範囲$一時値}》", edge.children[0].value);
        try std.testing.expectEqualStrings(key, edge.children[1].value);
    }
}

test "範囲オブジェクトの前の外側引数を参照の第1引数へ残す" {
    // Issue #297: 公式yCallFuncは`範囲`の助詞スロット（から/まで）に一致する
    // 2引数だけをポップする。`Aの`は範囲の引数ではなく、外側の`参照`の
    // 第1引数として残る（マニュアル範囲.txt:30）。
    var result = try parse(
        std.testing.allocator,
        "A = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]\nAの2から5までの範囲を参照してJSONエンコードして表示\n",
        "range-reference.nako3",
    );
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    var reference: ?*ast.Node = null;
    for (result.root.?.children) |child| {
        if (child.kind == .block) {
            for (child.children) |item| {
                if (item.kind == .function_call and std.mem.eql(u8, item.name, "参照")) reference = item;
            }
        }
    }
    const call = reference orelse return error.MissingReferenceCall;
    try std.testing.expectEqual(@as(usize, 2), call.children.len);
    try std.testing.expectEqual(ast.Kind.word, call.children[0].kind);
    try std.testing.expectEqualStrings("A", call.children[0].value);
    try std.testing.expectEqualStrings("の", call.children[0].josi);
    const range = call.children[1];
    try std.testing.expectEqual(ast.Kind.function_call, range.kind);
    try std.testing.expectEqualStrings("範囲", range.name);
    try std.testing.expectEqualStrings("を", range.josi);
    try std.testing.expectEqual(@as(usize, 2), range.children.len);
    try std.testing.expectEqualStrings("2", range.children[0].value);
    try std.testing.expectEqualStrings("から", range.children[0].josi);
    try std.testing.expectEqualStrings("5", range.children[1].value);
    try std.testing.expectEqualStrings("までの", range.children[1].josi);
}

test "『…』範囲式の繰り返しも一時変数へ展開し変数省略時は『それ』にする" {
    // Issue #117の形: `1…3を繰り返す`・`A…Bを繰り返す`。`…`演算子の範囲
    // function_callも`AからBの範囲`と同じ一時変数展開を受け、ループ変数の
    // 省略は『それ』になる。
    for ([_][]const u8{ "1…3を繰り返す\nそれを表示\nここまで\n", "A=1\nB=3\nA…Bを繰り返す\nそれを表示\nここまで\n" }) |source| {
        var result = try parse(std.testing.allocator, source, "for-range-dots.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        var sequence: ?*ast.Node = null;
        for (result.root.?.children) |child| {
            if (child.kind == .block and child.children.len > 1 and child.children[1].kind == .for_statement) sequence = child;
        }
        try std.testing.expect(sequence != null);
        const assign = sequence.?.children[0];
        try std.testing.expectEqual(ast.Kind.assignment, assign.kind);
        try std.testing.expectEqualStrings("繰り返し範囲$一時値}》", assign.name);
        try std.testing.expectEqual(ast.Kind.function_call, assign.children[0].kind);
        try std.testing.expectEqualStrings("範囲", assign.children[0].name);
        const repeat = sequence.?.children[1];
        try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
        try std.testing.expectEqualStrings("それ", repeat.name);
        for ([_][]const u8{ "先頭", "末尾" }, 0..) |key, i| {
            const edge = repeat.children[i];
            try std.testing.expectEqual(ast.Kind.array_value_reference, edge.kind);
            try std.testing.expectEqualStrings("繰り返し範囲$一時値}》", edge.children[0].value);
            try std.testing.expectEqualStrings(key, edge.children[1].value);
        }
    }
}

test "範囲オブジェクトの繰り返しは増分『ずつ』も受理する" {
    var result = try parse(std.testing.allocator, "Iで1から4の範囲を2ずつ増繰返す\nIを表示\nここまで\n", "for-range-inc.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const sequence = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, sequence.kind);
    const repeat = sequence.children[1];
    try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
    try std.testing.expectEqualStrings("I", repeat.name);
    try std.testing.expectEqual(ast.LoopDirection.up, repeat.loop_direction);
    try std.testing.expectEqual(ast.Kind.number, repeat.children[2].kind);
    try std.testing.expectEqualStrings("2", repeat.children[2].value);
}

test "範囲オブジェクトの繰り返しは括弧付き増分式も受理する" {
    // 公式は`(1+1)ずつ`のような括弧付き式も増分引数として読むため、
    // 先読みは対応する閉じ区切りまで式を読み飛ばす。
    var result = try parse(std.testing.allocator, "Iで1から4の範囲を(1+1)ずつ増繰返す\nIを表示\nここまで\n", "for-range-paren-inc.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const sequence = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, sequence.kind);
    const repeat = sequence.children[1];
    try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
    try std.testing.expectEqualStrings("I", repeat.name);
    try std.testing.expectEqual(ast.Kind.binary_operator, repeat.children[2].kind);
}

test "範囲オブジェクトの繰り返しはC風呼出しの増分式も受理する" {
    // 公式yCallFuncの括弧呼出しは直前のスタックを消費しないため、
    // `範囲をF(1)ずつ`の範囲呼出しは繰り返しの引数になる。
    var result = try parse(std.testing.allocator, "●(Aを)Fとは\n　それはA+1\nここまで\nIで1から4の範囲をF(1)ずつ増繰返す\nIを表示\nここまで\n", "for-range-call-inc.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    var sequence: ?*ast.Node = null;
    for (result.root.?.children) |child| {
        if (child.kind == .block and child.children.len > 1 and child.children[1].kind == .for_statement) sequence = child;
    }
    try std.testing.expect(sequence != null);
    const repeat = sequence.?.children[1];
    try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
    try std.testing.expectEqualStrings("I", repeat.name);
    const increment = repeat.children[2];
    try std.testing.expectEqual(ast.Kind.function_call, increment.kind);
    try std.testing.expectEqualStrings("F", increment.name);
}

test "先行引数を残したC風呼出しは未解決引数として構文エラー" {
    // 公式は`5をF(1)`の『5を』を未解決の単語として文法エラーにする。
    // C風呼出しを式解析へ委ねても、保留中の引数は破棄せず通常の
    // 未解決引数判定へ通す（`範囲をF(1)ずつ増繰返す`の増分式は
    // ループ引数として保持されるため影響しない）。
    var result = try parse(std.testing.allocator, "●(Aを)Fとは\n　それはA+1\nここまで\n5をF(1)\n", "c-call-stray-arg.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(diagnostic.Code.incomplete_statement, result.diagnostics[0].code);
    try std.testing.expectEqualStrings("不完全な文です。数値5が解決していません", result.diagnostics[0].message);
}

test "連文のあとのC風呼出しは独立した呼出しとして実行する" {
    // 公式は`して`で文を区切るため、`1を表示してF(1)`は表示とF(1)を
    // 順に実行する。連文が挿入した暗黙の『それ』はF(1)へ渡さない。
    var result = try parse(std.testing.allocator, "●(Aを)Fとは\n　それはA+1\nここまで\n1を表示してF(1)\n", "chain-c-call.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    var block: ?*ast.Node = null;
    for (result.root.?.children) |child| {
        if (child.kind == .block) block = child;
    }
    try std.testing.expect(block != null);
    try std.testing.expectEqual(ast.Kind.block, block.?.kind);
    try std.testing.expectEqual(@as(usize, 2), block.?.children.len);
    try std.testing.expectEqualStrings("表示", block.?.children[0].name);
    try std.testing.expectEqualStrings("F", block.?.children[1].name);
    try std.testing.expectEqual(@as(usize, 1), block.?.children[1].children.len);
    try std.testing.expectEqualStrings("1", block.?.children[1].children[0].value);
}

test "連文で残った実引数とC風呼出しは未解決引数として構文エラー" {
    // `5を`と同様に、括弧付きで明示した`(それ)`も実引数として残る。
    // 連文が挿入する暗黙『それ』マーカーとは生成元フラグで区別する。
    const cases = [_][]const u8{
        "●(Aを)Fとは\n　それはA+1\nここまで\n1を表示して5をF(1)\n",
        "●(Aを)Fとは\n　それはA+1\nここまで\n1を表示して(それ) F(1)\n",
    };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "chain-c-call-stray.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqual(diagnostic.Code.incomplete_statement, result.diagnostics[0].code);
    }
}

test "『ずつ』引数は増減繰返以外では構文エラー" {
    var result = try parse(std.testing.allocator, "1から5まで2ずつ繰り返す\nそれを表示\nここまで\n", "for-stray-inc.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
}

test "繰り返し変数位置が単語でなければ構文エラー" {
    var result = try parse(std.testing.allocator, "5で1から3まで繰り返す\nそれを表示\nここまで\n", "for-nonword-var.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
}

test "末尾側の『を』助詞が終了値より後なら未解決引数として構文エラー" {
    var result = try parse(std.testing.allocator, "3から5までNを繰り返す\nそれを表示\nここまで\n", "for-stray-wo.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
}

test "繰り返し引数は助詞で照合し引数の並び順を問わない" {
    // Issue #118: 公式yForは助詞でスタックから取り出すため、繰り返し変数が
    // 開始値・終了値の間に挟まる`1からNで3まで`や、『を』変数が先頭の
    // `Nを3まで1から`も同じ意味になる。未知の識別子はループの語の手前まで
    // 引数として読む。
    const cases = [_][]const u8{
        "Nを3まで1から繰り返す\nNを表示\nここまで\n",
        "1からNで3まで繰り返す\nNを表示\nここまで\n",
        "3まで1からNで繰り返す\nNを表示\nここまで\n",
        "Nで3まで1から繰り返す\nNを表示\nここまで\n",
    };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "for-josi-order.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        const repeat = result.root.?.children[0];
        try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
        try std.testing.expectEqualStrings("N", repeat.name);
        try std.testing.expectEqual(ast.Kind.number, repeat.children[0].kind);
        try std.testing.expectEqualStrings("1", repeat.children[0].value);
        try std.testing.expectEqual(ast.Kind.number, repeat.children[1].kind);
        try std.testing.expectEqualStrings("3", repeat.children[1].value);
    }
}

test "末尾側の『を』助詞は終了値として取り出し途中の『まで』は未解決引数" {
    // 公式yForは末尾側から『まで|を』を終了値として取り出すため、
    // `3までNを1から`はNをが終了値・残った3までが未解決の単語になる。
    // 診断位置は公式が検出する行末（この文の次の行）に揃える。
    var result = try parse(std.testing.allocator, "3までNを1から繰り返す\nNを表示\nここまで\n", "for-stray-made.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(diagnostic.Code.unresolved_word, result.diagnostics[0].code);
    try std.testing.expectEqualStrings("未解決の単語があります: [数値3まで]", result.diagnostics[0].message);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics[0].span.line);
}

test "繰り返しの境界値は演算子を含む式を受理する" {
    // Issue #118: 公式はスタックの式をそのまま境界値にするため、
    // `AからA+2まで`のような式も開始値・終了値になる。助詞なし識別子に
    // 二項演算子が続く場合は式の一部として扱う。
    const cases = [_][]const u8{
        "A=1\nNでAからA+2まで繰り返す\nNを表示\nここまで\n",
        "A=1\n1からA+2まで繰り返す\nそれを表示\nここまで\n",
        "A=1\nB=5\nNでAからB-2まで繰り返す\nNを表示\nここまで\n",
    };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "for-expr-bound.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        var repeat: ?*ast.Node = null;
        for (result.root.?.children) |child| {
            if (child.kind == .for_statement) repeat = child;
        }
        try std.testing.expect(repeat != null);
        try std.testing.expectEqual(ast.Kind.binary_operator, repeat.?.children[1].kind);
    }
}

test "『で』『を』変数の増減繰返も助詞で引数を照合する" {
    // `1までNで5から減繰返す`のように完全に並べ替えた形も受理する。
    var result = try parse(std.testing.allocator, "1までNで5から減繰返す\nNを表示\nここまで\n", "for-dec-josi-order.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const repeat = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.for_statement, repeat.kind);
    try std.testing.expectEqualStrings("N", repeat.name);
    try std.testing.expectEqual(ast.LoopDirection.down, repeat.loop_direction);
    try std.testing.expectEqualStrings("5", repeat.children[0].value);
    try std.testing.expectEqualStrings("1", repeat.children[1].value);
}

test "回数・条件繰り返しの残り引数は公式同様に構文エラー" {
    // 公式はループ引数として取り出せなかった語を未解決の単語として
    // 文法エラーにする。`5を3回`の『5を』や`Nで3回`の『Nで』、
    // `5をA>0の間`の『5を』が該当する。診断は行末位置＋
    // `未解決の単語があります: [...]`の公式形式で報告する。
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "5を3回繰り返す\nそれを表示\nここまで\n", .message = "未解決の単語があります: [数値5を]" },
        .{ .source = "Nで3回繰り返す\nそれを表示\nここまで\n", .message = "未解決の単語があります: [単語『loop-stray-arg__N』で]" },
        .{ .source = "5をA>0の間\nAを表示\nここまで\n", .message = "未解決の単語があります: [数値5を]" },
    };
    for (cases) |case| {
        var result = try parse(std.testing.allocator, case.source, "loop-stray-arg.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqual(diagnostic.Code.unresolved_word, result.diagnostics[0].code);
        try std.testing.expectEqualStrings(case.message, result.diagnostics[0].message);
        try std.testing.expectEqual(@as(usize, 1), result.diagnostics[0].span.line);
    }
}

test "引数のない戻すは暗黙の『それ』を返す" {
    var result = try parse(std.testing.allocator, "戻す\n", "return-it.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.return_statement, statement.kind);
    try std.testing.expectEqual(ast.Kind.word, statement.children[0].kind);
    try std.testing.expectEqualStrings("それ", statement.children[0].value);
}

test "和文代入で配列要素を更新する" {
    var result = try parse(std.testing.allocator, "1をA[0]に代入。\n", "array-assign.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const assignment = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.array_assignment, assignment.kind);
    try std.testing.expectEqualStrings("A", assignment.name);
    try std.testing.expectEqual(ast.Kind.number, assignment.children[0].kind);
    try std.testing.expectEqualStrings("1", assignment.children[0].value);
    try std.testing.expectEqual(ast.Kind.number, assignment.children[1].kind);
    try std.testing.expectEqualStrings("0", assignment.children[1].value);
}

test "和文代入でプロパティを更新する" {
    var result = try parse(std.testing.allocator, "1をA$fooに代入。\n", "property-assign.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const assignment = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.property_assignment, assignment.kind);
    try std.testing.expectEqualStrings("A", assignment.name);
    try std.testing.expectEqual(ast.Kind.number, assignment.children[0].kind);
    try std.testing.expectEqualStrings("1", assignment.children[0].value);
    try std.testing.expectEqual(ast.Kind.string, assignment.children[1].kind);
    try std.testing.expectEqualStrings("foo", assignment.children[1].value);
}

test "和文代入の値に式を許容する" {
    var result = try parse(std.testing.allocator, "(1+2)をAに代入。\n", "expr-assign.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const assignment = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.assignment, assignment.kind);
    try std.testing.expectEqualStrings("A", assignment.name);
    try std.testing.expectEqual(ast.Kind.binary_operator, assignment.children[0].kind);
}

test "助詞付きの既知命令名を連鎖呼出しとして解析する" {
    const names = [_][]const u8{ "要素数", "表示" };
    var result = try parser_mod.parseWithMode(std.testing.allocator, "「abc」の要素数を表示\n", "chain.nako3", .{
        .builtin_commands = &names,
    });
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, display.kind);
    try std.testing.expectEqualStrings("表示", display.name);
    try std.testing.expectEqual(@as(usize, 1), display.children.len);
    const count = display.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, count.kind);
    try std.testing.expectEqualStrings("要素数", count.name);
    try std.testing.expectEqualStrings("を", count.josi);
    try std.testing.expectEqual(@as(usize, 1), count.children.len);
    try std.testing.expectEqual(ast.Kind.string, count.children[0].kind);
    try std.testing.expectEqualStrings("abc", count.children[0].value);
    try std.testing.expectEqualStrings("の", count.children[0].josi);
}

test "既知命令名の一覧が空なら連鎖呼出しにしない" {
    var result = try parser_mod.parseWithMode(std.testing.allocator, "「abc」の要素数を表示\n", "chain-disabled.nako3", .{
        .builtin_commands = &.{},
    });
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, display.kind);
    try std.testing.expectEqualStrings("表示", display.name);
    try std.testing.expectEqual(@as(usize, 2), display.children.len);
    try std.testing.expectEqual(ast.Kind.word, display.children[1].kind);
    try std.testing.expectEqualStrings("要素数", display.children[1].value);
}

test "長い連鎖呼出しでもパーサは再帰せずに解析する" {
    const names = [_][]const u8{ "大文字変換", "表示" };
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "「a」の");
    var index: usize = 0;
    while (index < 2000) : (index += 1) try source.appendSlice(std.testing.allocator, "大文字変換を");
    try source.appendSlice(std.testing.allocator, "表示\n");
    var result = try parser_mod.parseWithMode(std.testing.allocator, source.items, "long-chain.nako3", .{
        .builtin_commands = &names,
    });
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, display.kind);
    try std.testing.expectEqualStrings("表示", display.name);
    // 連鎖の先頭は先頭値を受ける入れ子の呼出しになる。
    var current = display;
    var depth: usize = 0;
    while (current.children.len > 0) : (depth += 1) current = current.children[0];
    try std.testing.expectEqual(@as(usize, 2001), depth);
    try std.testing.expectEqual(ast.Kind.string, current.kind);
    try std.testing.expectEqualStrings("a", current.value);
}

test "代入右辺の連鎖呼出しが文位置と同じASTになる" {
    // 文位置の`「abc」の要素数を文字数`は`文字数(要素数("abc"))`になる。
    var statement = try parse(std.testing.allocator, "「abc」の要素数を文字数\n", "chain-statement.nako3");
    defer statement.deinit();
    try std.testing.expect(statement.succeeded());
    // 文位置も同じ入れ子の呼出しになる。
    try std.testing.expectEqual(ast.Kind.function_call, statement.root.?.children[0].kind);
    try std.testing.expectEqualStrings("文字数", statement.root.?.children[0].name);
    try std.testing.expectEqual(@as(usize, 1), statement.root.?.children[0].children.len);
    try std.testing.expectEqualStrings("要素数", statement.root.?.children[0].children[0].name);
    var assigned = try parse(std.testing.allocator, "A=「abc」の要素数を文字数\n", "chain-assign.nako3");
    defer assigned.deinit();
    try std.testing.expect(assigned.succeeded());
    const assignment = assigned.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.assignment, assignment.kind);
    try std.testing.expectEqualStrings("A", assignment.name);
    // 代入右辺も文位置と同じ入れ子の呼出しになり、位置引数へ分解されない。
    try std.testing.expectEqual(ast.Kind.function_call, assignment.children[0].kind);
    try std.testing.expectEqualStrings("文字数", assignment.children[0].name);
    try std.testing.expectEqual(@as(usize, 1), assignment.children[0].children.len);
    const count = assignment.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.function_call, count.kind);
    try std.testing.expectEqualStrings("要素数", count.name);
    try std.testing.expectEqualStrings("を", count.josi);
    try std.testing.expectEqualStrings("abc", count.children[0].value);
    try std.testing.expectEqualStrings("の", count.children[0].josi);
}

test "ASTの深さが上限を超えたら位置付き診断にする" {
    const names = [_][]const u8{ "大文字変換", "表示" };
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "「a」の");
    // 公式は2,000段の連鎖を受理し、3,000段を文法エラーにする（実測）。
    var index: usize = 0;
    while (index < parser_mod.max_ast_depth + 8) : (index += 1) try source.appendSlice(std.testing.allocator, "大文字変換を");
    try source.appendSlice(std.testing.allocator, "表示\n");
    var result = try parser_mod.parseWithMode(std.testing.allocator, source.items, "deep-chain.nako3", .{
        .builtin_commands = &names,
    });
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(@as(?*ast.Node, null), result.root);
    try std.testing.expectEqual(diagnostic.Code.nesting_too_deep, result.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics[0].span.line);
}

test "深い演算子の入れ子が上限を超えたら位置付き診断にする" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "それは1");
    var index: usize = 0;
    while (index < parser_mod.max_ast_depth + 8) : (index += 1) try source.appendSlice(std.testing.allocator, "+1");
    try source.appendSlice(std.testing.allocator, "\nそれを表示。\n");
    var result = try parse(std.testing.allocator, source.items, "deep-sum.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(@as(?*ast.Node, null), result.root);
    try std.testing.expectEqual(diagnostic.Code.nesting_too_deep, result.diagnostics[0].code);
}

test "深い括弧の入れ子が上限を超えたら位置付き診断にする" {
    const depth = parser_mod.max_parse_nesting_depth + 8;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "それは");
    var index: usize = 0;
    while (index < depth) : (index += 1) try source.appendSlice(std.testing.allocator, "(");
    try source.appendSlice(std.testing.allocator, "1");
    index = 0;
    while (index < depth) : (index += 1) try source.appendSlice(std.testing.allocator, ")");
    try source.appendSlice(std.testing.allocator, "\nそれを表示。\n");
    var result = try parse(std.testing.allocator, source.items, "deep-paren.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(@as(?*ast.Node, null), result.root);
    try std.testing.expectEqual(diagnostic.Code.nesting_too_deep, result.diagnostics[0].code);
}

test "同一行の制御構文の入れ子が上限を超えたら位置付き診断にする" {
    // `parseBlock`を通らない同一行の入れ子も`parseStatement`で数える。
    const depth = parser_mod.max_parse_nesting_depth + 8;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    var index: usize = 0;
    while (index < depth) : (index += 1) try source.appendSlice(std.testing.allocator, "もし1ならば");
    try source.appendSlice(std.testing.allocator, "1を表示\n");
    var result = try parse(std.testing.allocator, source.items, "deep-inline-if.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(@as(?*ast.Node, null), result.root);
    try std.testing.expectEqual(diagnostic.Code.nesting_too_deep, result.diagnostics[0].code);
}

test "深い単項演算子の入れ子が上限を超えたら位置付き診断にする" {
    const depth = parser_mod.max_parse_nesting_depth + 8;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "それは");
    var index: usize = 0;
    while (index < depth) : (index += 1) try source.appendSlice(std.testing.allocator, "-");
    try source.appendSlice(std.testing.allocator, "1\nそれを表示。\n");
    var result = try parse(std.testing.allocator, source.items, "deep-unary.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(@as(?*ast.Node, null), result.root);
    try std.testing.expectEqual(diagnostic.Code.nesting_too_deep, result.diagnostics[0].code);
}

test "公式同様に『定数 名』と属性付きの初期値なし宣言を拒否する" {
    const cases = [_][]const u8{ "定数 A\n", "定数 A{公開}\n", "変数 A{公開}\n" };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "宣言エラー.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqual(diagnostic.Code.expected_token, result.diagnostics[0].code);
    }
}

test "未知の属性名でも『変数 名{属性}』は『=』を必須にする" {
    // 公式は `変数 word { word } eq` を先に試すため、属性名が未知でも
    // 『=』が無ければ「変数宣言のみ」の形へは落ちない。
    var result = try parse(std.testing.allocator, "変数 A{未知}\nAを表示\n", "未知属性.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(diagnostic.Code.expected_token, result.diagnostics[0].code);

    var with_value = try parse(std.testing.allocator, "変数 A{未知}=1\nAを表示\n", "未知属性2.nako3");
    defer with_value.deinit();
    try std.testing.expect(with_value.succeeded());
    try std.testing.expect(with_value.root.?.children[0].is_export);
}

test "『!モジュール公開既定値』が無属性宣言の公開設定の既定値になる" {
    // 公式yExportDefault: 『公開』以外は非公開を既定にする。
    var result = try parse(std.testing.allocator, "!モジュール公開既定値=「非公開」\n変数 A=1\n変数 B{公開}=2\nAとは変数=3\n変数 [C]=[4]\n", "公開既定値.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const declarations = try variableDefinitions(std.testing.allocator, result.root.?);
    defer std.testing.allocator.free(declarations);
    try std.testing.expectEqual(@as(usize, 3), declarations.len);
    try std.testing.expect(!declarations[0].is_export);
    try std.testing.expect(declarations[1].is_export);
    try std.testing.expect(!declarations[2].is_export);
    try std.testing.expect(!result.root.?.children[6].is_export);

    var public_default = try parse(std.testing.allocator, "!モジュール公開既定値=「公開」\n変数 A=1\n変数 B{非公開}=2\n", "公開既定値2.nako3");
    defer public_default.deinit();
    const public_declarations = try variableDefinitions(std.testing.allocator, public_default.root.?);
    defer std.testing.allocator.free(public_declarations);
    try std.testing.expectEqual(@as(usize, 2), public_declarations.len);
    try std.testing.expect(public_declarations[0].is_export);
    try std.testing.expect(!public_declarations[1].is_export);
}

test "『〜とは 変数|定数=』の空の右辺と宣言直後のカンマを公式同様に受理する" {
    // 公式yLetは `yCalc() || value` で空の右辺をnopに落とし、
    // `名前1=値1, 名前2=値2` のために宣言直後のカンマを1つ読み飛ばす。
    var result = try parse(std.testing.allocator, "Aとは変数=\nBとは定数=\nCとは変数{公開}=\nDとは変数=1,E=2\n", "とは省略.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    for ([_]usize{ 0, 2, 4 }) |index| {
        const declaration = result.root.?.children[index];
        try std.testing.expectEqual(ast.Kind.variable_definition, declaration.kind);
        try std.testing.expectEqual(ast.Kind.nop, declaration.children[0].kind);
    }
    const assigned = result.root.?.children[6];
    try std.testing.expectEqual(@as(f64, 1), assigned.children[0].number_value.?);
}

test "『定数 名=』は空の右辺をnopにし『変数 名=』は拒否する" {
    var constant = try parse(std.testing.allocator, "定数 A=\nAを表示\n", "定数省略.nako3");
    defer constant.deinit();
    try std.testing.expect(constant.succeeded());
    try std.testing.expectEqual(ast.Kind.nop, constant.root.?.children[0].children[0].kind);

    const rejected = [_][]const u8{ "変数 A=\nAを表示\n", "変数 A{公開}=\nAを表示\n" };
    for (rejected) |source| {
        var result = try parse(std.testing.allocator, source, "変数省略.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
    }
}

test "『定める』の後置属性を公開設定として受理する" {
    var result = try parse(std.testing.allocator, "Aを1に定める{非公開}\nBを2に定める{公開}\nCを3に定める\n", "定める属性.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expect(!result.root.?.children[0].is_export);
    try std.testing.expect(result.root.?.children[2].is_export);
    try std.testing.expect(result.root.?.children[4].is_export);
}

/// ブロック直下の `variable_definition` を文順に集める。
fn variableDefinitions(allocator: std.mem.Allocator, root: *ast.Node) ![]const *ast.Node {
    var collected: std.ArrayList(*ast.Node) = .empty;
    for (root.children) |child| if (child.kind == .variable_definition) try collected.append(allocator, child);
    return collected.toOwnedSlice(allocator);
}

/// 指定した命令名の呼出しをAST全体から深さ優先で探す。
fn findCallNamed(node: *ast.Node, name: []const u8) ?*ast.Node {
    if (node.kind == .function_call and std.mem.eql(u8, node.name, name)) return node;
    for (node.children) |child| if (findCallNamed(child, name)) |found| return found;
    return null;
}

/// 最初の名前付き関数定義を返す（仮引数集約テスト用）。
fn firstFunctionDefinition(root: *ast.Node) !*ast.Node {
    for (root.children) |child| if (child.kind == .function_definition) return child;
    return error.MissingFunctionDefinition;
}

test "『定める』は定数を生成し匿名関数も右辺に取れる" {
    // 公式ySadameruは `createVar(word, true, ...)` で定数を作る。
    var result = try parse(std.testing.allocator, "リンゴ値段を320に定める。\n", "定める.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const declaration = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.variable_definition, declaration.kind);
    try std.testing.expectEqualStrings("リンゴ値段", declaration.name);
    try std.testing.expect(declaration.is_const);
    try std.testing.expectEqual(@as(f64, 320), declaration.children[0].number_value.?);
}

test "宣言の右辺は匿名関数も受理する" {
    // 公式`yCalc()`は匿名関数（`関数()`）を式として受理するため、
    // 空の右辺判定でも`.def_func`を式開始として扱う。
    const sources = [_][]const u8{
        "定数 F=関数()\n  1で戻る\nここまで\nF()を表示\n",
        "Aとは変数=関数()\n  2で戻る\nここまで\nA()を表示\n",
        "Aとは定数=関数()\n  3で戻る\nここまで\nA()を表示\n",
    };
    for (sources) |source| {
        var result = try parse(std.testing.allocator, source, "匿名関数右辺.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
        const declarations = try variableDefinitions(std.testing.allocator, result.root.?);
        defer std.testing.allocator.free(declarations);
        try std.testing.expectEqual(@as(usize, 1), declarations.len);
        try std.testing.expectEqual(ast.Kind.anonymous_function, declarations[0].children[0].kind);
    }
}

test "『定める』が『と』助詞を値として受理し値の省略をnopにする" {
    // 公式ySadameruは `popStack(['を'])` を定義対象、`popStack(['へ','に','と'])`
    // を値に取り、値が無ければnop（コード生成で0）にする。
    var result = try parse(std.testing.allocator, "Cを1と定める\nDを定める\n", "定めると.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const declarations = try variableDefinitions(std.testing.allocator, result.root.?);
    defer std.testing.allocator.free(declarations);
    try std.testing.expectEqual(@as(usize, 2), declarations.len);
    try std.testing.expectEqualStrings("C", declarations[0].name);
    try std.testing.expectEqual(@as(f64, 1), declarations[0].children[0].number_value.?);
    try std.testing.expectEqualStrings("D", declarations[1].name);
    try std.testing.expectEqual(ast.Kind.nop, declarations[1].children[0].kind);
}

test "『定める』は配列要素・プロパティを定義対象にしない" {
    // 公式ySadameruの定義対象は`word`に限る（配列要素・プロパティは
    // 『(定数名)を(値)に定める』の形ではないため文法エラーになる）。
    const cases = [_][]const u8{
        "A=[]\nA[0]を定める\n",
        "A=[0]\nA[0]を5に定める\n",
        "A={}\nA$xを定める\n",
        "A={\"x\":0}\nA$xを5に定める\n",
    };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "定める対象.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqual(diagnostic.Code.invalid_assignment, result.diagnostics[0].code);
        try std.testing.expectEqualStrings("『定める』文で定数が見当たりません。『(定数名)を(値)に定める』のように使います。", result.diagnostics[0].message);
    }

    // `代入`は従来どおり配列要素・プロパティを対象にできる。
    var assignment = try parse(std.testing.allocator, "A=[0]\nA[0]に5を代入\nA[0]を表示\n", "代入対象.nako3");
    defer assignment.deinit();
    try std.testing.expect(assignment.succeeded());
}

test "C風呼出しの引数に助詞付き命令呼出しを受理する" {
    // 公式`yGetArgParen`は各引数を`yCalc`で読むため、括弧内でも助詞呼出しが
    // 解決される（`割(1を2で)`）。
    var result = try parse(std.testing.allocator, "割(1を2で)を表示\n", "cstyle-josi.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, display.kind);
    try std.testing.expectEqualStrings("表示", display.name);
    const call = display.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, call.kind);
    try std.testing.expectEqualStrings("割", call.name);
    try std.testing.expect(call.is_c_style_call);
    try std.testing.expectEqual(@as(usize, 2), call.children.len);
    try std.testing.expectEqualStrings("を", call.children[0].josi);
    try std.testing.expectEqualStrings("で", call.children[1].josi);
}

test "C風呼出しの引数内で助詞呼出しを組み立てる" {
    // `表示(1を2で割)`の内側は命令呼出し`割(1を,2で)`になる。
    var result = try parse(std.testing.allocator, "表示(1を2で割)\n", "cstyle-inner-call.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    try std.testing.expectEqualStrings("表示", display.name);
    try std.testing.expect(display.is_c_style_call);
    try std.testing.expectEqual(@as(usize, 1), display.children.len);
    const inner = display.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, inner.kind);
    try std.testing.expectEqualStrings("割", inner.name);
    try std.testing.expect(!inner.is_c_style_call);
    try std.testing.expectEqual(@as(usize, 2), inner.children.len);
    try std.testing.expectEqualStrings("を", inner.children[0].josi);
    try std.testing.expectEqualStrings("で", inner.children[1].josi);
}

test "添字内の助詞付き命令呼出しを受理する" {
    var result = try parse(std.testing.allocator, "A[Aの要素数]を表示\n", "index-josi.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    const reference = display.children[0];
    try std.testing.expectEqual(ast.Kind.array_reference, reference.kind);
    const index = reference.children[1];
    try std.testing.expectEqual(ast.Kind.function_call, index.kind);
    try std.testing.expectEqualStrings("要素数", index.name);
    try std.testing.expectEqual(@as(usize, 1), index.children.len);
    try std.testing.expectEqualStrings("の", index.children[0].josi);
}

test "括弧内の助詞付き命令呼出しを受理する" {
    var result = try parse(std.testing.allocator, "(1を2で割)を表示\n", "paren-call.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    const call = display.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, call.kind);
    try std.testing.expectEqualStrings("割", call.name);
    try std.testing.expect(call.grouped);
    try std.testing.expectEqualStrings("を", call.josi);
}

test "助詞付き呼出しの直後の括弧は関数値呼出しではなく次の式として扱う" {
    // `(expr)助詞(expr)…` 形。助詞を持つ呼出しは引数として確定済みのため、
    // 直後の`(`はcall_valueではなく別の式の開始。公式は
    // `(「a」の「a」から「b」へ置換)と(「d」と連結)を連結して表示`を`bd`と評価する。
    var result = try parse(std.testing.allocator, "(「a」の「a」から「b」へ置換)と(「d」と連結)を連結して表示\n", "paren-josi-next-paren.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const block = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, block.kind);
    const concat = block.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, concat.kind);
    try std.testing.expectEqualStrings("連結", concat.name);
    try std.testing.expectEqual(@as(usize, 2), concat.children.len);
    try std.testing.expectEqual(ast.Kind.function_call, concat.children[0].kind);
    try std.testing.expectEqualStrings("置換", concat.children[0].name);
    try std.testing.expectEqualStrings("と", concat.children[0].josi);
    try std.testing.expectEqual(ast.Kind.function_call, concat.children[1].kind);
    try std.testing.expectEqualStrings("連結", concat.children[1].name);
    try std.testing.expectEqualStrings("を", concat.children[1].josi);
}

test "助詞を持たない呼出しの直後の括弧は従来どおり関数値呼出しになる" {
    // `(expr)(expr)` はlnako拡張のcall_value（公式は文法エラー）。
    var result = try parse(std.testing.allocator, "F(1)(2)を表示\n", "paren-call-value.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    const call = display.children[0];
    try std.testing.expectEqual(ast.Kind.call_value, call.kind);
    try std.testing.expectEqual(@as(usize, 2), call.children.len);
    try std.testing.expectEqual(ast.Kind.function_call, call.children[0].kind);
}

test "関数値呼出しは『(』の数だけ多段に連鎖する" {
    // 公式`yCallValue`は`(`の数だけ連鎖を読む。`G()()()`は
    // call_value(call_value(G(),...),...)の入れ子になる（#128）。
    var result = try parse(std.testing.allocator, "G()()()を表示\n", "call-value-chain3.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    const outer = display.children[0];
    try std.testing.expectEqual(ast.Kind.call_value, outer.kind);
    const inner = outer.children[0];
    try std.testing.expectEqual(ast.Kind.call_value, inner.kind);
    try std.testing.expectEqual(ast.Kind.function_call, inner.children[0].kind);
    try std.testing.expectEqualStrings("G", inner.children[0].name);
}

test "call_valueの直後の『@』『[』『.』はcall_value未解決の構文エラー" {
    // 公式`yCallValue`はcall_valueの結果へ添字・プロパティを続けず、
    // 『不完全な文です。『call_value』が解決していません』で拒否する。
    // 『@』『.』は式を開始できないため、助詞付きのcall_valueの直後でも
    // 公式は同じ診断で拒否する（`F()()と@0`・`F()()を.x`も同様）。
    // 条件助詞（なら・たら等）は公式では文レベルの条件構文でcall_valueが
    // その境界で先に失敗するため、直後の『[』も引数として読まれず拒否する。
    const cases = [_][]const u8{
        "F()()@0を表示\n",
        "F()()[0]を表示\n",
        "F()().xを表示\n",
        "F()()と@0を表示\n",
        "F()()と.xを表示\n",
        "F()()を@0を表示\n",
        "F()()を.xを表示\n",
        "F()()なら[0]を表示\n",
        "F()()ならば[0]を表示\n",
        "F()()たら[0]を表示\n",
        "F()()れば[0]を表示\n",
        "F()()でなければ[0]を表示\n",
        "F()()なければ[0]を表示\n",
    };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "call-value-postfix.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqual(diagnostic.Code.incomplete_statement, result.diagnostics[0].code);
        try std.testing.expectEqualStrings("不完全な文です。『call_value』が解決していません", result.diagnostics[0].message);
    }
}

test "助詞付きcall_valueの直後の『[』は配列リテラル引数の開始として読む" {
    // 公式`yCallValue`は助詞付きcall_valueを解決済みの実引数として扱うため、
    // 直後の`[`は新たな配列リテラル引数の開始になる（Issue #163:
    // `F()()と[1,2]を連結して表示`は`x1,2`を表示する）。
    var result = try parse(std.testing.allocator, "F()()と[1,2]を連結して表示\n", "call-value-josi-array.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const block = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, block.kind);
    const concat = block.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, concat.kind);
    try std.testing.expectEqualStrings("連結", concat.name);
    try std.testing.expectEqual(@as(usize, 2), concat.children.len);
    try std.testing.expectEqual(ast.Kind.call_value, concat.children[0].kind);
    try std.testing.expectEqualStrings("と", concat.children[0].josi);
    try std.testing.expectEqual(ast.Kind.array_literal, concat.children[1].kind);
    try std.testing.expectEqualStrings("を", concat.children[1].josi);

    // 『を』助詞でも同様（`F()()を[A]に追加`）。
    var append_result = try parse(std.testing.allocator, "A=[9]\nF()()を[A]に追加して表示\n", "call-value-josi-array-wo.nako3");
    defer append_result.deinit();
    try std.testing.expect(append_result.succeeded());
    const append_block = append_result.root.?.children[2];
    try std.testing.expectEqual(ast.Kind.block, append_block.kind);
    const append = append_block.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, append.kind);
    try std.testing.expectEqualStrings("追加", append.name);
    try std.testing.expectEqual(ast.Kind.call_value, append.children[0].kind);
    try std.testing.expectEqualStrings("を", append.children[0].josi);
    try std.testing.expectEqual(ast.Kind.array_literal, append.children[1].kind);
    try std.testing.expectEqualStrings("に", append.children[1].josi);
}

test "括弧で括ったcall_valueには添字・プロパティを適用できる" {
    // `(F()())`は括弧済みの通常の値なので、公式も`[0]`・`@0`・`.x`を受理する。
    const cases = [_][]const u8{
        "(F()())[0]を表示\n",
        "(F()())@0を表示\n",
        "(F()()).xを表示\n",
    };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "grouped-call-value-postfix.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
    }
}

test "括弧で括った呼出しの直後の括弧はcall_valueへ連鎖しない" {
    // `(F())`・`(F)`の直後の`(`は公式では次の括弧式になるため、
    // call_valueへ結合しない（`(F())()`は公式`(...)の解析エラー`）。
    var result = try parse(std.testing.allocator, "(F())()を表示\n", "grouped-call-paren.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
}

test "括弧内で呼出しに解決されなかった残りは末尾の値を使う" {
    // 公式`yCalc`は残スタックの末尾を返すため、`(1を2で)`は`2`になる。
    var result = try parse(std.testing.allocator, "(1を2で)を表示\n", "paren-leftover.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    const value = display.children[0];
    try std.testing.expectEqual(ast.Kind.number, value.kind);
    try std.testing.expectEqualStrings("2", value.value);
    try std.testing.expect(value.grouped);
}

test "配列・辞書リテラルの要素に助詞付き命令呼出しを受理する" {
    var result = try parse(std.testing.allocator, "A=[1,2,3]\nB=[Aの要素数]\nC={\"x\":Aの要素数}\n", "literal-josi.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const array_assign = result.root.?.children[2];
    const array_literal = array_assign.children[0];
    try std.testing.expectEqual(ast.Kind.array_literal, array_literal.kind);
    try std.testing.expectEqual(ast.Kind.function_call, array_literal.children[0].kind);
    try std.testing.expectEqualStrings("要素数", array_literal.children[0].name);
    const object_assign = result.root.?.children[4];
    const object_literal = object_assign.children[0];
    try std.testing.expectEqual(ast.Kind.object_literal, object_literal.kind);
    try std.testing.expectEqualStrings("x", object_literal.children[0].value);
    try std.testing.expectEqual(ast.Kind.function_call, object_literal.children[1].kind);
    try std.testing.expectEqualStrings("要素数", object_literal.children[1].name);
}

test "C風呼出しはカンマ無しの連続する値も引数として受理する" {
    // 公式`yGetArgParen`はカンマが無くても`yCalc`が値を返す限り引数を読む
    // （`加算(1 2)`＝`加算(1,2)`）。
    var result = try parse(std.testing.allocator, "加算(1 2)を表示\n", "cstyle-no-comma.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[0];
    const call = display.children[0];
    try std.testing.expect(call.is_c_style_call);
    try std.testing.expectEqual(@as(usize, 2), call.children.len);
    try std.testing.expectEqualStrings("1", call.children[0].value);
    try std.testing.expectEqualStrings("2", call.children[1].value);
}

test "添字・配列・辞書の内側で単一値に解決されない助詞列は文法エラーにする" {
    // 公式もスタックに残った値をエラーにするため、受理しない。
    const cases = [_][]const u8{
        "A=[0]\nA[1を2で]を表示\n",
        "A=[0]\nB=[1を2で]\n",
        "A={}\nB={\"x\":1を2で}\n",
    };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "unresolved-delimited.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
    }
}

test "演算子を挟む助詞呼出しは演算式全体を後続命令の引数にする" {
    // 公式`yCall`は言い切りの呼出し結果へ演算子を適用してシーケンスを続ける
    // ため、`Aの要素数+Aの要素数`は`要素数(要素数(A)+A)`になる。
    var result = try parse(std.testing.allocator, "A=[1,2]\nB=[Aの要素数+Aの要素数]\n", "operator-josi.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const assign = result.root.?.children[2];
    const array = assign.children[0];
    try std.testing.expectEqual(ast.Kind.array_literal, array.kind);
    try std.testing.expectEqual(@as(usize, 1), array.children.len);
    const outer = array.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, outer.kind);
    try std.testing.expectEqualStrings("要素数", outer.name);
    try std.testing.expectEqual(@as(usize, 1), outer.children.len);
    const op = outer.children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, op.kind);
    try std.testing.expectEqualStrings("+", op.operator);
    try std.testing.expectEqual(ast.Kind.function_call, op.children[0].kind);
    try std.testing.expectEqualStrings("要素数", op.children[0].name);
    try std.testing.expectEqual(ast.Kind.word, op.children[1].kind);
    try std.testing.expectEqualStrings("A", op.children[1].value);
}

test "添字内の演算子右辺の助詞呼出しを受理する" {
    var result = try parse(std.testing.allocator, "A=[1,2]\nA[Aの要素数+Aの要素数-4]を表示\n", "index-operator-josi.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const display = result.root.?.children[2];
    const reference = display.children[0];
    try std.testing.expectEqual(ast.Kind.array_reference, reference.kind);
    const index = reference.children[1];
    // `要素数(要素数(A)+A)-4`の形になる。
    try std.testing.expectEqual(ast.Kind.binary_operator, index.kind);
    try std.testing.expectEqualStrings("-", index.operator);
    const outer = index.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, outer.kind);
    try std.testing.expectEqualStrings("要素数", outer.name);
    try std.testing.expectEqual(ast.Kind.binary_operator, outer.children[0].kind);
    try std.testing.expectEqualStrings("+", outer.children[0].operator);
}

test "代入右辺の演算子を挟む助詞呼出しを受理する" {
    // 代入文の右辺（公式yCalc相当）でも同じシーケンス解決を行う。
    var result = try parse(std.testing.allocator, "A=[1,2]\nC=Aの要素数+Aの要素数\n", "assign-operator-josi.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const assign = result.root.?.children[2];
    const outer = assign.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, outer.kind);
    try std.testing.expectEqualStrings("要素数", outer.name);
    const op = outer.children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, op.kind);
    try std.testing.expectEqualStrings("+", op.operator);
    try std.testing.expectEqualStrings("要素数", op.children[0].name);
}

test "括弧・C風引数・辞書値の演算子を挟む助詞呼出しを受理する" {
    const cases = [_][]const u8{
        "A=[1,2]\n(Aの要素数+Aの要素数)を表示\n",
        "A=[1,2]\n表示(Aの要素数+Aの要素数)\n",
        "A=[1,2]\nD={\"x\":Aの要素数+Aの要素数}\n",
    };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "delimited-operator-josi.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
    }
}

test "カンマ無し引数に匿名関数を受理する" {
    // 公式`yValue`は`def_func`を値として読むため、カンマ無しの継続引数でも
    // 匿名関数を開始できる（`F(1 関数() 2で戻る ここまで)`）。
    const cases = [_][]const u8{
        "●(AとBを)Fとは\nAを表示\nここまで\nF(1 関数() 2で戻る ここまで)\n",
        "●(AとBを)Fとは\nAを表示\nここまで\nF(関数() 2で戻る ここまで 1)\n",
        "●(Aを)Fとは\nAを表示\nここまで\nG=F\nG(1 関数() 2で戻る ここまで)\n",
    };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "no-comma-anon-func.nako3");
        defer result.deinit();
        try std.testing.expect(result.succeeded());
    }
}

test "『{関数}名』をfunction_pointerとして解析する" {
    // 公式は字句後処理で`{関数}`直後の関数名をfunc_pointerへ変換する。
    // lnakoはパーサで結合し、関数名と助詞を直後の識別子から引き継ぐ。
    var result = try parse(std.testing.allocator, "F={関数}AAA\n{関数}AAAを実行\n", "func-ref.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const assign = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.assignment, assign.kind);
    const pointer = assign.children[0];
    try std.testing.expectEqual(ast.Kind.function_pointer, pointer.kind);
    try std.testing.expectEqualStrings("AAA", pointer.name);
    const call = result.root.?.children[2];
    try std.testing.expectEqual(ast.Kind.function_call, call.kind);
    try std.testing.expectEqualStrings("実行", call.name);
    const argument = call.children[0];
    try std.testing.expectEqual(ast.Kind.function_pointer, argument.kind);
    try std.testing.expectEqualStrings("AAA", argument.name);
    try std.testing.expectEqualStrings("を", argument.josi);
}

test "『{関数}』のカンマ形式と関数名欠落を拒否する" {
    // 公式は`{関数},名`・名前無しの`{関数}`を文法エラーにする。
    const cases = [_][]const u8{
        "F={関数},AAA\n",
        "F={関数}\n",
        "F={関数}123\n",
    };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "bad-func-ref.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
    }
}

test "『反復』の対象省略は「それ」を反復対象にする" {
    // 公式yForEachは`popStack(['を'])`が無いとき`yNop()`を対象とし、
    // convForeachが`それ`の値を反復データとして使う。lnakoは省略時に
    // 「それ」を参照するwordノードを生成する。
    var result = try parse(std.testing.allocator, "反復\n対象を表示\nここまで\n", "foreach-implicit.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.foreach_statement, statement.kind);
    try std.testing.expectEqualStrings("", statement.name);
    try std.testing.expectEqual(ast.Kind.word, statement.children[0].kind);
    try std.testing.expectEqualStrings("それ", statement.children[0].value);
}

test "『Aを反復』は助詞「を」の値を反復対象にする" {
    var result = try parse(std.testing.allocator, "Aを反復\n対象を表示\nここまで\n", "foreach-target.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.foreach_statement, statement.kind);
    try std.testing.expectEqualStrings("", statement.name);
    try std.testing.expectEqual(ast.Kind.word, statement.children[0].kind);
    try std.testing.expectEqualStrings("A", statement.children[0].value);
}

test "『AをBで反復』は指定変数を解析する" {
    // 公式yForEachは`popStack(['で'])`のwordをループ変数とする。
    // `B`は命令名ではなく変数名として扱われる。
    var result = try parse(std.testing.allocator, "AをBで反復\nBを表示\nここまで\n", "foreach-var.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.foreach_statement, statement.kind);
    try std.testing.expectEqualStrings("B", statement.name);
    try std.testing.expectEqual(ast.Kind.word, statement.children[0].kind);
    try std.testing.expectEqualStrings("A", statement.children[0].value);
}

test "『Nで配列を反復』は前置の指定変数を解析する" {
    var result = try parse(std.testing.allocator, "Nで[1,2,3]を反復\nNを表示\nここまで\n", "foreach-var-prefix.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.foreach_statement, statement.kind);
    try std.testing.expectEqualStrings("N", statement.name);
    try std.testing.expectEqual(ast.Kind.array_literal, statement.children[0].kind);
}

test "『Aを「,」で区切って反復』は連文の呼出しを先行文として評価する" {
    // 公式は「で区切っ」の呼出しがスタックに残り、先行文として実行されて
    // 結果が「それ」へ残る。反復対象は省略され「それ」を使う。
    var result = try parse(std.testing.allocator, "アンケートを「,」で区切って反復\n対象を表示\nここまで\n", "foreach-chained.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.block, statement.kind);
    try std.testing.expectEqual(ast.Kind.function_call, statement.children[0].kind);
    const foreach = statement.children[statement.children.len - 1];
    try std.testing.expectEqual(ast.Kind.foreach_statement, foreach.kind);
    try std.testing.expectEqualStrings("", foreach.name);
    try std.testing.expectEqual(ast.Kind.word, foreach.children[0].kind);
    try std.testing.expectEqualStrings("それ", foreach.children[0].value);
}

test "『反復』の指定変数はwordに限る" {
    // 公式は`popStack(['で'])`の結果がwordでない場合
    // 『(変数名)で(配列)を反復』で指定してください。の文法エラーにする。
    var result = try parse(std.testing.allocator, "Aを1で反復\nここまで\n", "foreach-var-number.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
}

/// 深い連鎖の回帰テスト用の項数。`propagateOperatorJosi`等のAST走査は連鎖の
/// 項数だけ再帰していたため、この経路はSIGSEGVになり得た（Debugビルドでは約30万項で
/// 再現）。ここでは同じ経路を短時間で通す規模に留め、継続行`_`で1行あたりの
/// 桁計算を一定に保つ。
const deep_chain_terms: usize = 60000;

test "極端に長い演算子連鎖は再帰ではなく位置付き診断で止まる" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "それは1+_\n");
    var index: usize = 0;
    while (index < deep_chain_terms) : (index += 1) try source.appendSlice(std.testing.allocator, "1+_\n");
    try source.appendSlice(std.testing.allocator, "1\nそれを表示。\n");
    var result = try parse(std.testing.allocator, source.items, "very-deep-sum.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(@as(?*ast.Node, null), result.root);
    try std.testing.expectEqual(diagnostic.Code.nesting_too_deep, result.diagnostics[0].code);
}

test "極端に長い連鎖を持つ条件式も位置付き診断で止まる" {
    // `もし`の条件はfinishConditionが演算子部分木を走査するため、
    // propagateOperatorJosiとは別経路の深さになる。
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "もし1+_\n");
    var index: usize = 0;
    while (index < deep_chain_terms - 1) : (index += 1) try source.appendSlice(std.testing.allocator, "1+_\n");
    try source.appendSlice(std.testing.allocator, "1ならば\n1を表示\nここまで\n");
    var result = try parse(std.testing.allocator, source.items, "very-deep-condition.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(@as(?*ast.Node, null), result.root);
    try std.testing.expectEqual(diagnostic.Code.nesting_too_deep, result.diagnostics[0].code);
}
