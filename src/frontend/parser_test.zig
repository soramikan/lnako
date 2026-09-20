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
    var result = try parse(std.testing.allocator, "「abc」の要素数を表示\n", "chain-disabled.nako3");
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
