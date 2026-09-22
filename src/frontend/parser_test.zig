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

test "公式同様に辞書リテラルの数値キーを拒否する" {
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
