const std = @import("std");
const diagnostic = @import("../frontend/diagnostic.zig");
const analyzer = @import("analyzer.zig");
const analyze = analyzer.analyze;
const analyzeModules = analyzer.analyzeModules;
const moduleName = analyzer.moduleName;
const SymbolKind = analyzer.SymbolKind;
const DynamicCommandAlias = analyzer.DynamicCommandAlias;

test "公式と同じファイル名をモジュール名に保つ" {
    const hyphenated = try moduleName(std.testing.allocator, "dir/system-runtime.nako3");
    defer std.testing.allocator.free(hyphenated);
    try std.testing.expectEqualStrings("system-runtime", hyphenated);

    const windows = try moduleName(std.testing.allocator, "C:\\dir\\a.b.nako");
    defer std.testing.allocator.free(windows);
    try std.testing.expectEqualStrings("a.b", windows);

    const unrelated_extension = try moduleName(std.testing.allocator, "sample.txt");
    defer std.testing.allocator.free(unrelated_extension);
    try std.testing.expectEqualStrings("sample.txt", unrelated_extension);
}

test ".dncl/.dncl2拡張子をモジュール名から除去する" {
    const dncl = try moduleName(std.testing.allocator, "dir/main.dncl");
    defer std.testing.allocator.free(dncl);
    try std.testing.expectEqualStrings("main", dncl);

    const dncl2 = try moduleName(std.testing.allocator, "dir/main.dncl2");
    defer std.testing.allocator.free(dncl2);
    try std.testing.expectEqualStrings("main", dncl2);

    const upper = try moduleName(std.testing.allocator, "dir/LIB.DNCL");
    defer std.testing.allocator.free(upper);
    try std.testing.expectEqualStrings("LIB", upper);
}

test "グローバル・引数・組み込み命令を解決する" {
    const parser = @import("../frontend/parser.zig");
    var parsed = try parser.parse(std.testing.allocator, "A=1\n●(Bを)Fとは\nA+Bを表示\nここまで\nF(2)\n", "main.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(program.findSymbol("main__A") != null);
    try std.testing.expect(program.findSymbol("main__F") != null);
    try std.testing.expect(program.findSymbol("main__B") == null);
    var found_builtin = false;
    for (program.bindings) |binding| if (binding.kind == .builtin and std.mem.eql(u8, binding.name, "表示")) {
        found_builtin = true;
    };
    try std.testing.expect(found_builtin);
}

test "関数内で定義した名前付き関数はモジュールスコープへ登録する" {
    // 公式は入れ子の名前付き関数もfunclistへ登録するため、外側関数の外から
    // 呼べる。本体の裸名は外側関数のローカル・仮引数ではなくモジュール変数
    // へ解決される（字句的な入れ子スコープを持たない）。
    const parser = @import("../frontend/parser.zig");
    const source = "A=1\n●外とは\nAとは変数＝10\n●内とは\nAを表示\nここまで\n内\nここまで\n外\n内\n";
    var parsed = try parser.parse(std.testing.allocator, source, "nested-scope.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "nested-scope.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    const inner = program.findSymbol("nested-scope__内") orelse return error.TestExpectedInnerFunction;
    try std.testing.expectEqual(SymbolKind.function, inner.kind);
    try std.testing.expectEqual(analyzer.ScopeKind.module, program.scopes[inner.scope].kind);

    // 本体のAはモジュール変数へ、内の呼出しは入れ子関数へ束縛される。
    var body_reads_module_a = false;
    for (program.bindings) |binding| {
        if (binding.kind == .reference and std.mem.eql(u8, binding.name, "A") and
            std.mem.eql(u8, binding.resolved_name, "nested-scope__A"))
        {
            body_reads_module_a = true;
        }
    }
    try std.testing.expect(body_reads_module_a);
    var inner_calls: usize = 0;
    for (program.bindings) |binding| {
        if (binding.kind == .call and std.mem.eql(u8, binding.resolved_name, "nested-scope__内")) inner_calls += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), inner_calls);

    // 入れ子関数の本体スコープは外側関数ではなくモジュールを親にする。
    var inner_scope_is_module_child = false;
    for (program.function_scopes) |owner| {
        if (!std.mem.eql(u8, owner.node.name, "内")) continue;
        const parent = program.scopes[owner.scope].parent orelse continue;
        if (program.scopes[parent].kind == .module) inner_scope_is_module_child = true;
    }
    try std.testing.expect(inner_scope_is_module_child);
}

test "取り込みモジュール内の入れ子関数を全モジュール解決前に宣言する" {
    // 入れ子関数は外側関数の解決時ではなく、事前宣言走査でfunclistへ登録する。
    // 他モジュールの参照は全入力の事前宣言後に解決されるため、この順序が
    // 崩れると非修飾呼出しが未解決になる。
    const parser = @import("../frontend/parser.zig");
    var library = try parser.parse(std.testing.allocator, "●外とは\n●内とは\n1で戻る\nここまで\nここまで\n", "lib.nako3");
    defer library.deinit();
    var main = try parser.parse(std.testing.allocator, "内\n", "main.nako3");
    defer main.deinit();
    var program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "main", .path = "main.nako3", .root = main.root.?, .marker_rank = 0 },
        .{ .name = "lib", .path = "lib.nako3", .root = library.root.?, .marker_rank = 1 },
    });
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var imported_calls: usize = 0;
    for (program.bindings) |binding| {
        if (binding.kind == .call and std.mem.eql(u8, binding.resolved_name, "lib__内")) imported_calls += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), imported_calls);
}

test "同名の関数定義はコード生成順の後勝ちで上書きする" {
    // 公式は関数定義をfunclistへ登録し、同名定義は後勝ちになる。lnakoも
    // 単一シンボルを再利用し、助詞・引数個数を最後の定義へ揃える。
    const parser = @import("../frontend/parser.zig");
    const source = "●(Aの)Fとは\nAで戻る\nここまで\n●外とは\n●(AとBの)Fとは\nA+Bで戻る\nここまで\nここまで\n外\nF(2,3)を表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "lastwins.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "lastwins.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    const function = program.findSymbol("lastwins__F") orelse return error.TestExpectedFunction;
    try std.testing.expectEqual(@as(usize, 2), function.argument_count);
    var f_symbols: usize = 0;
    for (program.symbols) |symbol| {
        if (symbol.kind == .function and std.mem.eql(u8, symbol.name, "F")) f_symbols += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), f_symbols);
}

test "同名の通常関数とテスト関数は後勝ちで上書きせず二重定義にする" {
    // 公式cnako v3.7.24は通常関数とテスト関数を別の名前空間へ登録する
    // （●F と ●テスト:F を併記してもFの呼出しは通常関数を実行する）。
    // lnakoは単一シンボル空間のため、異種同名を後勝ちで混ぜず、既存の
    // 二重定義診断で止める。
    const parser = @import("../frontend/parser.zig");
    const cases = [_]struct {
        source: []const u8,
        path: []const u8,
        qualified_name: []const u8,
        kind: SymbolKind,
        argument_count: usize,
    }{
        .{
            .source = "●(Aの)Fとは\nAを表示\nここまで\n●テスト:Fとは\n「test」を表示\nここまで\nF(1)\n",
            .path = "function-then-test.nako3",
            .qualified_name = "function-then-test__F",
            .kind = .function,
            .argument_count = 1,
        },
        .{
            .source = "●テスト:Fとは\n「test」を表示\nここまで\n●(Aの)Fとは\nAを表示\nここまで\nF(1)\n",
            .path = "test-then-function.nako3",
            .qualified_name = "test-then-function__F",
            .kind = .test_function,
            .argument_count = 0,
        },
    };
    for (cases) |case| {
        var parsed = try parser.parse(std.testing.allocator, case.source, case.path);
        defer parsed.deinit();
        var program = try analyze(std.testing.allocator, parsed.root.?, case.path);
        defer program.deinit();
        try std.testing.expect(!program.succeeded());
        try std.testing.expectEqual(diagnostic.Code.duplicate_symbol, program.diagnostics[0].code);
        // 先に宣言した側の kind・引数個数は後続の異種定義で書き換わらない。
        const function = program.findSymbol(case.qualified_name) orelse return error.TestExpectedFunction;
        try std.testing.expectEqual(case.kind, function.kind);
        try std.testing.expectEqual(case.argument_count, function.argument_count);
    }
}

test "入れ子の同名関数が確定済みの引数情報を上書きしない" {
    // predeclareModuleFunctions が最後の定義（ここではモジュール直下の
    // 1引数F）で arity・助詞を確定する。後続の入れ子定義の再宣言で
    // 2引数の定義へ戻ると、F(2) が引数不足として拒否される（Issue #195）。
    const parser = @import("../frontend/parser.zig");
    const source = "●外とは\n●(AとBの)Fとは\nA+Bを表示\nここまで\nここまで\n●(Aの)Fとは\nAを表示\nここまで\nF(2)\n";
    var parsed = try parser.parse(std.testing.allocator, source, "nested-order.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "nested-order.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    const function = program.findSymbol("nested-order__F") orelse return error.TestExpectedFunction;
    try std.testing.expectEqual(@as(usize, 1), function.argument_count);
    try std.testing.expectEqual(@as(usize, 1), function.parameter_josi.len);
    try std.testing.expectEqualStrings("の", function.parameter_josi[0]);
}

test "入れ子定義より前の同名関数呼出しを最終定義の引数情報で解決する" {
    // 外側関数の本体は入れ子定義より前に F(1) を呼ぶ。最終定義は
    // モジュール直下の1引数Fであり、入れ子定義（2引数）の再宣言で
    // 巻き戻るとこの呼出しが引数不足になる（Issue #195）。
    const parser = @import("../frontend/parser.zig");
    const source = "●外とは\nF(1)\n●(AとBの)Fとは\nA+Bを表示\nここまで\nここまで\n●(Aの)Fとは\nAを表示\nここまで\n外\n";
    var parsed = try parser.parse(std.testing.allocator, source, "nested-before.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "nested-before.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    const function = program.findSymbol("nested-before__F") orelse return error.TestExpectedFunction;
    try std.testing.expectEqual(@as(usize, 1), function.argument_count);
    var calls: usize = 0;
    for (program.bindings) |binding| {
        if (binding.kind == .call and std.mem.eql(u8, binding.resolved_name, "nested-before__F")) calls += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "無名関数の代入は外側の可変束縛を解決する" {
    const parser = @import("../frontend/parser.zig");
    const source = "●(Aを)作るとは\nF=関数()\nA=A+1\nここまで\nFで戻る\nここまで\n";
    var parsed = try parser.parse(std.testing.allocator, source, "closure.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "closure.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expectEqual(@as(usize, 2), program.function_scopes.len);
    var non_module_a: usize = 0;
    for (program.symbols) |symbol| {
        if (!std.mem.eql(u8, symbol.name, "A")) continue;
        if (program.scopes[symbol.scope].kind == .module) continue;
        non_module_a += 1;
        try std.testing.expectEqual(SymbolKind.parameter, symbol.kind);
    }
    try std.testing.expectEqual(@as(usize, 1), non_module_a);
}

test "静的に解決したユーザー関数の引数個数差を拒否する" {
    const parser = @import("../frontend/parser.zig");
    const source = "●(AとBを)Fとは\nA+Bで戻る\nここまで\nF(1)\nF(1,2,3)\n";
    var parsed = try parser.parse(std.testing.allocator, source, "arity.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "arity.nako3");
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
    var count: usize = 0;
    for (program.diagnostics) |item| {
        if (item.code == .invalid_argument_count) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "標準組み込み命令のC形式引数個数を診断し可変引数と助詞構文を許可する" {
    const parser = @import("../frontend/parser.zig");
    const source = "切取(\"a\")\n切取(\"a\",\"b\")\n切取(\"a\",\"b\",\"c\")\n今(1)\n連結()\n連結(1,2)\nCSVオプション設定({})\nAを配列結合\n";
    var parsed = try parser.parse(std.testing.allocator, source, "builtin-arity.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "builtin-arity.nako3");
    defer program.deinit();

    var messages: [3][]const u8 = undefined;
    var count: usize = 0;
    for (program.diagnostics) |item| if (item.code == .invalid_argument_count) {
        try std.testing.expect(count < messages.len);
        messages[count] = item.message;
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, messages.len), count);
    try std.testing.expectEqualStrings("関数『切取』で引数1個が指定されましたが、2個の引数を指定してください。", messages[0]);
    try std.testing.expectEqualStrings("関数『切取』で引数3個が指定されましたが、2個の引数を指定してください。", messages[1]);
    try std.testing.expectEqualStrings("関数『今』で引数1個が指定されましたが、0個の引数を指定してください。", messages[2]);
}

test "低レイヤー命令のC形式引数個数を診断する" {
    const parser = @import("../frontend/parser.zig");
    const source = "ファイル閉(1,2)\nファイル開(\"a\",\"r\",\"x\")\n";
    var parsed = try parser.parse(std.testing.allocator, source, "low-level-arity.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "low-level-arity.nako3");
    defer program.deinit();
    var count: usize = 0;
    for (program.diagnostics) |item| {
        if (item.code == .invalid_argument_count) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "裸の名前付き関数は1引数以下だけ暗黙呼び出しとして解決する" {
    const parser = @import("../frontend/parser.zig");
    const source = "●(Aを)Fとは\nAで戻る\nここまで\n●(AとBを)Gとは\nA+Bで戻る\nここまで\nTYPEOF(F)を表示\nTYPEOF(G)を表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "implicit-call.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "implicit-call.nako3");
    defer program.deinit();
    var implicit_f = false;
    var invalid_count: usize = 0;
    for (program.bindings) |binding| {
        if (binding.kind == .call and std.mem.eql(u8, binding.resolved_name, "implicit-call__F")) implicit_f = true;
    }
    for (program.diagnostics) |item| if (item.code == .invalid_argument_count) {
        invalid_count += 1;
    };
    try std.testing.expect(implicit_f);
    try std.testing.expectEqual(@as(usize, 1), invalid_count);
}

test "未定義変数への増減を暗黙のモジュール変数宣言として解決する" {
    const parser = @import("../frontend/parser.zig");
    var parsed = try parser.parse(std.testing.allocator, "Aを1増\nAを表示\n", "increment.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "increment.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(program.findSymbol("increment__A") != null);
    var declaration_bound = false;
    for (program.bindings) |binding| if (binding.kind == .declaration and std.mem.eql(u8, binding.name, "A") and std.mem.eql(u8, binding.resolved_name, "increment__A")) {
        declaration_bound = true;
    };
    try std.testing.expect(declaration_bound);
}

test "同名の公開シンボルはmodList先勝ちで解決する" {
    // 公式findVarはmodList（エントリ→展開順）で先に一致したモジュールを
    // 選び、曖昧さエラーにはならない。修飾名は常にfunclist完全一致。
    const parser = @import("../frontend/parser.zig");
    var main = try parser.parse(std.testing.allocator, "F\na__F\n", "main.nako3");
    defer main.deinit();
    var first = try parser.parse(std.testing.allocator, "●Fとは\n1で戻る\nここまで\n", "a.nako3");
    defer first.deinit();
    var second = try parser.parse(std.testing.allocator, "●Fとは\n2で戻る\nここまで\n", "b.nako3");
    defer second.deinit();
    var program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "main", .path = "main.nako3", .root = main.root.?, .marker_rank = 0 },
        .{ .name = "a", .path = "a.nako3", .root = first.root.?, .marker_rank = 1 },
        .{ .name = "b", .path = "b.nako3", .root = second.root.?, .marker_rank = 2 },
    });
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var qualified_count: usize = 0;
    for (program.bindings) |binding| if (binding.kind == .call and std.mem.eql(u8, binding.resolved_name, "a__F")) {
        qualified_count += 1;
    };
    // 裸名の F はmodList先勝ちで a__F に、修飾名 a__F も a__F に解決される
    try std.testing.expectEqual(@as(usize, 2), qualified_count);
}

test "取り込んだ公開関数を非修飾名と修飾名で解決する" {
    const parser = @import("../frontend/parser.zig");
    var library = try parser.parse(std.testing.allocator, "●(Aを)二倍とは\nA*2で戻る\nここまで\n", "lib.nako3");
    defer library.deinit();
    var main = try parser.parse(std.testing.allocator, "3を二倍して表示\nlib__二倍(4)を表示\n", "main.nako3");
    defer main.deinit();
    var program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "lib", .path = "lib.nako3", .root = library.root.? },
        .{ .name = "main", .path = "main.nako3", .root = main.root.?, .marker_rank = 1 },
    });
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(program.findSymbol("lib__二倍") != null);
    var imported_calls: usize = 0;
    for (program.bindings) |binding| if (binding.kind == .call and std.mem.eql(u8, binding.resolved_name, "lib__二倍")) {
        imported_calls += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), imported_calls);
}

test "厳チェックの未定義名を警告にし、定数再代入はエラーにする" {
    // 公式`!厳しくチェック`は未定義参照を`logger.warn`で警告するだけで
    // 実行を継続する（終了0・`undefined`表示）。定数再代入はエラーのまま。
    const parser = @import("../frontend/parser.zig");
    var parsed = try parser.parse(std.testing.allocator, "!厳チェック\n定数 A=1\nA=2\n未宣言値を表示\n", "strict.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "strict.nako3");
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
    var undefined_count: usize = 0;
    var const_count: usize = 0;
    for (program.diagnostics) |item| {
        if (item.code == .undefined_symbol) {
            undefined_count += 1;
            try std.testing.expectEqual(diagnostic.Severity.warning, item.severity);
        }
        if (item.code == .assign_to_constant) const_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), undefined_count);
    try std.testing.expectEqual(@as(usize, 1), const_count);

    // 未定義参照だけなら警告に留まり、コンパイルは成功する。
    var warnings_only = try parser.parse(std.testing.allocator, "!厳しくチェック\n「{X}」を表示。\n", "strict-warn.nako3");
    defer warnings_only.deinit();
    var warning_program = try analyze(std.testing.allocator, warnings_only.root.?, "strict-warn.nako3");
    defer warning_program.deinit();
    try std.testing.expect(warning_program.succeeded());
    try std.testing.expectEqual(diagnostic.Severity.warning, warning_program.diagnostics[0].severity);
    try std.testing.expectEqual(diagnostic.Code.undefined_symbol, warning_program.diagnostics[0].code);

    // 未定義名は暗黙宣言され、実行時に`undefined`として読める。
    var bound = false;
    for (warning_program.bindings) |binding| {
        if (binding.kind == .reference and std.mem.eql(u8, binding.name, "X")) bound = std.mem.eql(u8, binding.resolved_name, "strict-warn__X");
    }
    try std.testing.expect(bound);

    // 参照位置より後の代入が作るシンボルへの前方参照も、公式の単一パスでは
    // 参照時点で未定義のため警告する（束縛は後続代入のシンボルのまま）。
    var fwd_parsed = try parser.parse(std.testing.allocator, "!厳チェック\nXを表示\nX=1\nXを表示\n", "strict-fwd.nako3");
    defer fwd_parsed.deinit();
    var fwd_program = try analyze(std.testing.allocator, fwd_parsed.root.?, "strict-fwd.nako3");
    defer fwd_program.deinit();
    try std.testing.expect(fwd_program.succeeded());
    var fwd_warnings: usize = 0;
    for (fwd_program.diagnostics) |item| {
        if (item.code == .undefined_symbol) {
            fwd_warnings += 1;
            try std.testing.expectEqual(diagnostic.Severity.warning, item.severity);
            try std.testing.expectEqual(@as(u32, 1), item.span.line);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), fwd_warnings);
    var fwd_bound = false;
    for (fwd_program.bindings) |binding| {
        if (binding.kind == .reference and std.mem.eql(u8, binding.name, "X")) fwd_bound = std.mem.eql(u8, binding.resolved_name, "strict-fwd__X");
    }
    try std.testing.expect(fwd_bound);

    // 未定義の命令呼出しは公式も文法エラー（`関数『X』が見当たりません`）
    // なので、厳格モードでもエラーのままにする。
    var call_parsed = try parser.parse(std.testing.allocator, "!厳しくチェック\n未知命令()\n", "strict-call.nako3");
    defer call_parsed.deinit();
    var call_program = try analyze(std.testing.allocator, call_parsed.root.?, "strict-call.nako3");
    defer call_program.deinit();
    try std.testing.expect(!call_program.succeeded());
    try std.testing.expectEqual(diagnostic.Code.undefined_symbol, call_program.diagnostics[0].code);
    try std.testing.expectEqual(diagnostic.Severity.error_severity, call_program.diagnostics[0].severity);
}

test "未定義の命令呼出しと定数呼出しを公式同様に診断する" {
    const parser = @import("../frontend/parser.zig");
    const Case = struct {
        source: []const u8,
        code: diagnostic.Code,
        line: u32,
        message: []const u8,
    };
    const cases = [_]Case{
        .{
            .source = "XYZ(1)\n",
            .code = .undefined_symbol,
            .line = 0,
            .message = "関数『undefined-command__XYZ』が見当たりません。",
        },
        .{
            .source = "XYZ\n",
            .code = .incomplete_statement,
            .line = 0,
            .message = "不完全な文です。単語『undefined-command__XYZ』が解決していません。",
        },
        .{
            .source = "もし 1=1 ならば\n  「A」と表示\nそうでなければ\n  「B」と表示\nここまで\n",
            .code = .incomplete_statement,
            .line = 2,
            .message = "不完全な文です。単語『それ』が解決していません。",
        },
        .{
            .source = "回数()\n",
            .code = .undefined_symbol,
            .line = 0,
            .message = "『回数』は関数ではありません。",
        },
    };
    for (cases) |case| {
        var parsed = try parser.parse(std.testing.allocator, case.source, "undefined-command.nako3");
        defer parsed.deinit();
        var program = try analyze(std.testing.allocator, parsed.root.?, "undefined-command.nako3");
        defer program.deinit();
        try std.testing.expect(!program.succeeded());
        var found = false;
        for (program.diagnostics) |item| {
            if (item.code != case.code or !std.mem.eql(u8, item.message, case.message)) continue;
            found = true;
            try std.testing.expectEqual(case.line, item.span.line);
        }
        try std.testing.expect(found);
    }
}

test "組み込み命令名と関数名への代入を診断する" {
    // 公式は`func token`＋`=`を代入的呼出しの名残として構文エラーにする。
    const parser = @import("../frontend/parser.zig");
    const sources = [_][]const u8{
        "INT=3.5\n", // 代入
        "INTに2を代入\n", // 代入文
        "変数 INT=1\n", // 変数宣言
        "今とは定数=1\n", // とは宣言
        "変数 [INT,A]=[1,2]\n", // 変数一覧宣言
        "デスクトップ=1\n", // 同名グローバルを持つ命令名（連鎖呼出し一覧からは除外されるが`func token`）
        "__DEBUG=1\n", // `__`を含む命令名
    };
    for (sources) |source| {
        var parsed = try parser.parse(std.testing.allocator, source, "function-target.nako3");
        defer parsed.deinit();
        var program = try analyze(std.testing.allocator, parsed.root.?, "function-target.nako3");
        defer program.deinit();
        try std.testing.expect(!program.succeeded());
        try std.testing.expectEqual(diagnostic.Code.assign_to_function, program.diagnostics[0].code);
        try std.testing.expectEqual(@as(u32, 1), program.diagnostics[0].span.line + 1);
    }

    // システム変数（`func token`ではない）と通常の変数は代入できる。
    const allowed = [_][]const u8{ "回数=1\n", "A=1\nA=2\n" };
    for (allowed) |source| {
        var parsed = try parser.parse(std.testing.allocator, source, "function-target-ok.nako3");
        defer parsed.deinit();
        var program = try analyze(std.testing.allocator, parsed.root.?, "function-target-ok.nako3");
        defer program.deinit();
        try std.testing.expect(program.succeeded());
    }

    // ユーザー定義関数への代入も公式と同じく関数として報告する。
    var parsed = try parser.parse(std.testing.allocator, "●Fとは\n1で戻る\nここまで\nF=1\n", "user-function-target.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "user-function-target.nako3");
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
    try std.testing.expectEqual(diagnostic.Code.assign_to_function, program.diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 4), program.diagnostics[0].span.line + 1);

    // 組み込み名と同名のユーザー関数への代入は、公式の単一エラーと同じく
    // 診断を1件だけ出す（命令名とシンボルの両経路で重複させない）。
    {
        var dup_parsed = try parser.parse(std.testing.allocator, "●INTとは\n1で戻る\nここまで\nINT=1\n", "dup-function-target.nako3");
        defer dup_parsed.deinit();
        var dup_program = try analyze(std.testing.allocator, dup_parsed.root.?, "dup-function-target.nako3");
        defer dup_program.deinit();
        try std.testing.expect(!dup_program.succeeded());
        try std.testing.expectEqual(diagnostic.Code.assign_to_function, dup_program.diagnostics[0].code);
        try std.testing.expectEqual(@as(usize, 1), dup_program.diagnostics.len);
    }
}

test "宣言助詞に一致しない引数は公式の未解決の単語診断になる" {
    // Issue #108: 公式`yCallFunc`は助詞スロットへ収まらない引数をスタックへ
    // 残し、行末で『未解決の単語があります: [...]』の文法エラーにする。
    // 診断位置は公式が検出する行末（改行区切りなら次の行）に揃える。
    const parser = @import("../frontend/parser.zig");
    const cases = [_]struct { source: []const u8, line: usize, message: []const u8 }{
        .{ .source = "A=1\nB=2\nAがBを足す\nそれを表示\n", .line = 3, .message = "未解決の単語があります: [単語『main__A』が]" },
        .{ .source = "それは「xyz」\n「abc」で大文字変換を表示。\n", .line = 1, .message = "未解決の単語があります: [文字列『abc』で]" },
        .{ .source = "●Fとは\n9で戻る\nここまで\nAをF\n", .line = 4, .message = "未解決の単語があります: [単語『main__A』を]" },
        .{ .source = "5を7を表示\n", .line = 1, .message = "未解決の単語があります: [数値5を]" },
        .{ .source = "●Fとは\n9で戻る\nここまで\nそれをF\n", .line = 4, .message = "未解決の単語があります: [単語『それ』を]" },
        .{ .source = "●(XにYを)Fとは\nX+Yで戻る\nここまで\nAがBをF\n", .line = 4, .message = "未解決の単語があります: [単語『main__A』が]" },
        // 公式`nodeToStr`と同じくcall_value・配列/プロパティ参照・
        // 配列/辞書リテラルも型名『…』で報告する（`式`へ畳まない）。
        .{ .source = "●Gとは\n「x」で戻る\nここまで\n●Fとは\nそれは{関数}G\nここまで\nA=[9]\nF()()が[A]を表示\n", .line = 8, .message = "未解決の単語があります: [『call_value』が]" },
        .{ .source = "A=[1]\nA[0]が[1]を表示\n", .line = 2, .message = "未解決の単語があります: [『ref_array』が]" },
        .{ .source = "A={x:1}\nA.xが[1]を表示\n", .line = 2, .message = "未解決の単語があります: [『ref_prop』が]" },
        .{ .source = "[1,2]が[1]を表示\n", .line = 1, .message = "未解決の単語があります: [『json_array』が]" },
        .{ .source = "{x:1}が[1]を表示\n", .line = 1, .message = "未解決の単語があります: [『json_obj』が]" },
        // 公式のref_array/ref_propは裸のword起点の参照だけ。括弧済みの
        // 語や値への後置アクセスはref_array_value（`『@』`/`『$』`）、
        // `A[0].x`のプロパティは公式では同一ref_arrayへ吸収される。
        .{ .source = "A=[1]\n(A)[0]が[1]を表示\n", .line = 2, .message = "未解決の単語があります: [『@』が]" },
        .{ .source = "A={x:1}\n(A).xが[1]を表示\n", .line = 2, .message = "未解決の単語があります: [『$』が]" },
        .{ .source = "A=[1]\nA[0].xが[1]を表示\n", .line = 2, .message = "未解決の単語があります: [『ref_array』が]" },
        .{ .source = "[1,2][0]が[1]を表示\n", .line = 1, .message = "未解決の単語があります: [『@』が]" },
        .{ .source = "[{x:1}].xが[1]を表示\n", .line = 1, .message = "未解決の単語があります: [『$』が]" },
    };
    for (cases) |case| {
        var parsed = try parser.parse(std.testing.allocator, case.source, "main.nako3");
        defer parsed.deinit();
        try std.testing.expect(parsed.succeeded());
        var program = try analyzer.analyzeWithSource(std.testing.allocator, parsed.root.?, "main.nako3", parsed.stream.source.text);
        defer program.deinit();
        try std.testing.expect(!program.succeeded());
        try std.testing.expectEqual(diagnostic.Code.unresolved_word, program.diagnostics[0].code);
        try std.testing.expectEqual(case.line, program.diagnostics[0].span.line);
        try std.testing.expectEqualStrings(case.message, program.diagnostics[0].message);
    }
}

test "繰り返しの外の『抜ける』『続ける』を文法エラーにする" {
    // Issue #166: 公式convCheckLoopはflagLoopの立たない位置の文を
    // 『それは繰り返しの中で利用してください』の文法エラーにする。
    // 関数境界で文脈は区切られるため、呼ばれない関数内や繰り返し内で
    // 定義された関数の中の文も同じ診断になる。
    const parser = @import("../frontend/parser.zig");
    const invalid = [_]struct { source: []const u8, line: usize, message: []const u8 }{
        .{ .source = "抜ける。\n", .line = 0, .message = "『抜ける』文がありますが、それは繰り返しの中で利用してください。" },
        .{ .source = "続ける。\n", .line = 0, .message = "『続ける』文がありますが、それは繰り返しの中で利用してください。" },
        .{ .source = "●Fとは\n抜ける。\nここまで\n", .line = 1, .message = "『抜ける』文がありますが、それは繰り返しの中で利用してください。" },
        .{ .source = "●Fとは\n続ける。\nここまで\n", .line = 1, .message = "『続ける』文がありますが、それは繰り返しの中で利用してください。" },
        .{ .source = "F=関数()\n抜ける。\nここまで\n", .line = 1, .message = "『抜ける』文がありますが、それは繰り返しの中で利用してください。" },
        // 繰り返し内で定義された関数の本体も別文脈（公式は生成JSの評価時に
        // Illegal break statementで異常終了するだけなので診断する）。
        .{ .source = "3回\n●Fとは\n抜ける。\nここまで\nここまで\n", .line = 2, .message = "『抜ける』文がありますが、それは繰り返しの中で利用してください。" },
        .{ .source = "もし1=1ならば\n抜ける。\nここまで\n", .line = 1, .message = "『抜ける』文がありますが、それは繰り返しの中で利用してください。" },
        .{ .source = "エラー監視\n抜ける。\nエラーならば\n「x」を表示\nここまで\n", .line = 1, .message = "『抜ける』文がありますが、それは繰り返しの中で利用してください。" },
        // 『違えば』節は公式もflagLoopを立てないため文法エラーになる。
        .{ .source = "Aで条件分岐\n1ならば\n「x」を表示\nここまで\n違えば\n抜ける。\nここまで\nここまで\n", .line = 5, .message = "『抜ける』文がありますが、それは繰り返しの中で利用してください。" },
        // case節の『続ける』はループを必要とする（公式はeval時SyntaxError）。
        .{ .source = "Aで条件分岐\n1ならば\n続ける。\nここまで\nここまで\n", .line = 2, .message = "『続ける』文がありますが、それは繰り返しの中で利用してください。" },
        .{ .source = "3回\n回数を表示\nここまで\n抜ける。\n", .line = 3, .message = "『抜ける』文がありますが、それは繰り返しの中で利用してください。" },
    };
    for (invalid) |case| {
        var parsed = try parser.parse(std.testing.allocator, case.source, "loop-context.nako3");
        defer parsed.deinit();
        var program = try analyze(std.testing.allocator, parsed.root.?, "loop-context.nako3");
        defer program.deinit();
        try std.testing.expect(!program.succeeded());
        try std.testing.expectEqual(diagnostic.Code.invalid_control_statement, program.diagnostics[0].code);
        try std.testing.expectEqual(case.line, program.diagnostics[0].span.line);
        try std.testing.expectEqualStrings(case.message, program.diagnostics[0].message);
    }
}

test "繰り返しと条件分岐のcase節の『抜ける』『続ける』は受理する" {
    const parser = @import("../frontend/parser.zig");
    const valid = [_][]const u8{
        "3回\n抜ける。\nここまで\n",
        "3回\n続ける。\nここまで\n",
        "(真)の間\n抜ける。\nここまで\n",
        "後判定\n続ける。\nここまで偽になるまで\n",
        "Iを1から3まで繰り返す\n抜ける。\nここまで\n",
        "[1,2]を反復\n抜ける。\nここまで\n",
        // 入れ子の繰り返しの内側
        "2回\n(真)の間\n抜ける。\nここまで\nここまで\n",
        // 条件分岐のcase節の『抜ける』はその条件分岐を抜ける
        "Aで条件分岐\n1ならば\n抜ける。\nここまで\nここまで\n",
        // case節内の繰り返しの『抜ける』『続ける』はその繰り返しが対象
        "Aで条件分岐\n1ならば\n3回\n抜ける。\nここまで\nここまで\nここまで\n",
        "Aで条件分岐\n1ならば\n3回\n続ける。\nここまで\nここまで\nここまで\n",
        // ループ内の条件分岐ではcase節・『違えば』節どちらも『抜ける』『続ける』可
        "3回\nAで条件分岐\n1ならば\n抜ける。\nここまで\n違えば\n続ける。\nここまで\nここまで\nここまで\n",
        // ループ内のもし・エラー監視の内側
        "3回\nもし1=1ならば\n抜ける。\nここまで\nここまで\n",
        "3回\nエラー監視\n抜ける。\nエラーならば\n「x」を表示\nここまで\nここまで\n",
        // 関数本体内の繰り返しは独立して有効
        "●Fとは\n3回\n抜ける。\nここまで\nここまで\n",
        "●Fとは\nAで条件分岐\n1ならば\n抜ける。\nここまで\nここまで\nここまで\n",
    };
    for (valid) |source| {
        var parsed = try parser.parse(std.testing.allocator, source, "loop-context-ok.nako3");
        defer parsed.deinit();
        var program = try analyze(std.testing.allocator, parsed.root.?, "loop-context-ok.nako3");
        defer program.deinit();
        try std.testing.expect(program.succeeded());
    }
}

test "助詞が正しい呼出しと暗黙『それ』連文は未解決語にしない" {
    const parser = @import("../frontend/parser.zig");
    const sources = [_][]const u8{
        "A=1\nB=2\nAにBを足して表示\n",
        "「abc」を大文字変換して表示\n",
        "●Fとは\n9で戻る\nここまで\nF\n",
        "●(Aを)Fとは\nAで戻る\nここまで\n1を表示してF\n",
    };
    for (sources) |source| {
        var parsed = try parser.parse(std.testing.allocator, source, "main.nako3");
        defer parsed.deinit();
        var program = try analyzer.analyzeWithSource(std.testing.allocator, parsed.root.?, "main.nako3", parsed.stream.source.text);
        defer program.deinit();
        try std.testing.expect(program.succeeded());
    }
}

test "package qualified symbolは宣言したimporter以外から解決されない" {
    const parser = @import("../frontend/parser.zig");
    var package = try parser.parse(std.testing.allocator, "値=1\n", "math.nako3");
    defer package.deinit();
    var declared = try parser.parse(std.testing.allocator, "math__値を表示\n", "declared.nako3");
    defer declared.deinit();
    var undeclared = try parser.parse(std.testing.allocator, "math__値を表示\n", "undeclared.nako3");
    defer undeclared.deinit();
    const aliases = [_]analyzer.NamespaceAlias{.{
        .source_namespace = "math",
        .internal_namespace = "opaque_pkg_0",
        .target_module = 0,
        .is_explicit = true,
    }};

    // Package symbols use an opaque internal prefix; source alias lookup is scoped
    // to this importer and translates math__Value to the internal key.
    var declared_program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "math", .internal_namespace = "opaque_pkg_0", .path = "math.nako3", .root = package.root.?, .is_package = true },
        .{ .name = "declared", .path = "declared.nako3", .root = declared.root.?, .namespace_aliases = &aliases },
    });
    defer declared_program.deinit();
    var declared_resolved = false;
    for (declared_program.bindings) |binding| {
        if (binding.kind != .reference or !std.mem.eql(u8, binding.name, "math__値")) continue;
        if (binding.symbol) |symbol_id| {
            if (declared_program.symbols[symbol_id].module_index == 0) declared_resolved = true;
        }
    }
    try std.testing.expect(declared_resolved);

    var undeclared_program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "math", .path = "math.nako3", .root = package.root.?, .is_package = true },
        .{ .name = "undeclared", .path = "undeclared.nako3", .root = undeclared.root.? },
    });
    defer undeclared_program.deinit();
    for (undeclared_program.bindings) |binding| {
        if (binding.kind != .reference or !std.mem.eql(u8, binding.name, "math__値")) continue;
        if (binding.symbol) |symbol_id| try std.testing.expect(undeclared_program.symbols[symbol_id].module_index != 0);
    }
}

test "package aliasは関数parameterの同名qualified localより優先されない" {
    const parser = @import("../frontend/parser.zig");
    var package = try parser.parse(std.testing.allocator, "値=1\n", "package.nako3");
    defer package.deinit();
    var main = try parser.parse(std.testing.allocator, "●(math__値を)Fとは\nmath__値を表示\nここまで\nF(10)\n", "main.nako3");
    defer main.deinit();
    const aliases = [_]analyzer.NamespaceAlias{.{
        .source_namespace = "math",
        .internal_namespace = "package",
        .target_module = 0,
        .is_explicit = true,
    }};
    var program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "package", .path = "package.nako3", .root = package.root.? },
        .{ .name = "main", .path = "main.nako3", .root = main.root.?, .namespace_aliases = &aliases },
    });
    defer program.deinit();
    try std.testing.expect(program.succeeded());

    var found_local_parameter = false;
    for (program.bindings) |binding| {
        if (binding.kind != .reference or !std.mem.eql(u8, binding.name, "math__値")) continue;
        const symbol = program.symbols[binding.symbol.?];
        if (symbol.kind == .parameter) found_local_parameter = true;
    }
    try std.testing.expect(found_local_parameter);
}

test "package aliasは同一targetへの別aliasの先行展開で早期可視化されない" {
    const parser = @import("../frontend/parser.zig");
    var package = try parser.parse(std.testing.allocator, "値=1\n", "package.nako3");
    defer package.deinit();
    var main = try parser.parse(std.testing.allocator, "first__値を表示\nmath__値を表示\n", "main.nako3");
    defer main.deinit();
    const aliases = [_]analyzer.NamespaceAlias{
        .{ .source_namespace = "first", .internal_namespace = "package", .target_module = 0, .import_position = 0, .is_explicit = true },
        .{ .source_namespace = "math", .internal_namespace = "package", .target_module = 0, .import_position = 100, .is_explicit = true },
    };
    const package_ranks = [_]usize{0};
    const main_ranks = [_]usize{ 1, 1 };
    var program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "package", .path = "package.nako3", .root = package.root.?, .stmt_ranks = &package_ranks, .marker_rank = 0 },
        .{ .name = "main", .path = "main.nako3", .root = main.root.?, .namespace_aliases = &aliases, .stmt_ranks = &main_ranks, .marker_rank = 1 },
    });
    defer program.deinit();

    var first_alias_resolved = false;
    var second_alias_resolved = false;
    for (program.bindings) |binding| {
        if (binding.kind != .reference or binding.symbol == null) continue;
        if (std.mem.eql(u8, binding.name, "first__値")) first_alias_resolved = program.symbols[binding.symbol.?].module_index == 0;
        if (std.mem.eql(u8, binding.name, "math__値")) second_alias_resolved = program.symbols[binding.symbol.?].module_index == 0;
    }
    try std.testing.expect(first_alias_resolved);
    try std.testing.expect(!second_alias_resolved);
}

test "package aliasはimportより前のpackage globalを可視にしない" {
    const parser = @import("../frontend/parser.zig");
    var package = try parser.parse(std.testing.allocator, "値=1\n", "package.nako3");
    defer package.deinit();
    var main = try parser.parse(std.testing.allocator, "math__値を表示\n●Fとは\nmath__値を表示\nここまで\nF\n", "main.nako3");
    defer main.deinit();
    const aliases = [_]analyzer.NamespaceAlias{.{
        .source_namespace = "math",
        .internal_namespace = "package",
        .target_module = 0,
        .is_explicit = true,
    }};
    const package_ranks = [_]usize{2};
    const main_ranks = [_]usize{ 0, 0, 1 };
    var program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "package", .path = "package.nako3", .root = package.root.?, .stmt_ranks = &package_ranks, .marker_rank = 2 },
        .{ .name = "main", .path = "main.nako3", .root = main.root.?, .namespace_aliases = &aliases, .stmt_ranks = &main_ranks, .marker_rank = 0 },
    });
    defer program.deinit();

    var found_reference = false;
    for (program.bindings) |binding| {
        if (binding.kind != .reference or !std.mem.eql(u8, binding.name, "math__値")) continue;
        found_reference = true;
        if (binding.symbol) |symbol_id| try std.testing.expect(program.symbols[symbol_id].module_index != 0);
    }
    try std.testing.expect(found_reference);
}

test "『{関数}名』はユーザー関数と組み込み命令へ束縛する" {
    const parser = @import("../frontend/parser.zig");
    const source = "●AAAとは\n30を戻す\nここまで\n{関数}AAAを実行\n{関数}足を実行\n";
    var parsed = try parser.parse(std.testing.allocator, source, "func-ref.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var program = try analyze(std.testing.allocator, parsed.root.?, "func-ref.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var saw_user = false;
    var saw_builtin = false;
    for (program.bindings) |binding| {
        if (binding.kind == .call and std.mem.eql(u8, binding.name, "AAA") and std.mem.endsWith(u8, binding.resolved_name, "__AAA")) saw_user = true;
        if (binding.kind == .builtin and std.mem.eql(u8, binding.resolved_name, "足")) saw_builtin = true;
    }
    try std.testing.expect(saw_user);
    try std.testing.expect(saw_builtin);
}

test "『{関数}未定義名』は関数として見つからない旨を診断する" {
    const parser = @import("../frontend/parser.zig");
    var parsed = try parser.parse(std.testing.allocator, "{関数}ZZZを実行\n", "func-ref-unknown.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var program = try analyze(std.testing.allocator, parsed.root.?, "func-ref-unknown.nako3");
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
    var count: usize = 0;
    for (program.diagnostics) |item| {
        if (item.code == .undefined_symbol) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "『{関数}名』の動的プラグイン命令はdynamic_builtinとして束縛する" {
    const parser = @import("../frontend/parser.zig");
    // ネイティブプラグイン取り込みモジュールでは未知の命令名を動的命令と
    // して束縛する。関数値は実行時にplugin dispatchへ委譲される。
    var parsed = try parser.parse(std.testing.allocator, "F={関数}外部追加\n", "native-plugin.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var program = try analyzeModules(std.testing.allocator, &.{.{
        .name = "native-plugin",
        .path = "native-plugin.nako3",
        .root = parsed.root.?,
        .allows_dynamic_commands = true,
    }});
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var saw_dynamic = false;
    for (program.bindings) |binding| {
        if (binding.kind == .builtin and binding.dynamic_builtin and std.mem.eql(u8, binding.resolved_name, "外部追加")) saw_dynamic = true;
    }
    try std.testing.expect(saw_dynamic);
}

test "動的評価へ引き継いだ実行時登録命令名を動的builtinへ束縛する" {
    const parser = @import("../frontend/parser.zig");
    // `ナデシコ`/`ナデシコ続` の動的コードは取り込み辺を持たないため、
    // interpreterが実行時registryから渡すdispatch名だけを受理する。
    const registered = [_]DynamicCommandAlias{
        .{ .source_namespace = "ネイティブ加算", .dispatch_namespace = "ネイティブ加算", .exact = true },
        .{ .source_namespace = "nativepkg__外部追加", .dispatch_namespace = "nativepkg__外部追加", .exact = true },
    };
    var parsed = try parser.parse(
        std.testing.allocator,
        "ネイティブ加算(2, 3)\nnativepkg__外部追加(1, 2)\nF={関数}ネイティブ加算\n",
        "<dynamic>.nako3",
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var program = try analyzeModules(std.testing.allocator, &.{.{
        .name = "main",
        .path = "<dynamic>.nako3",
        .root = parsed.root.?,
        .dynamic_command_aliases = &registered,
    }});
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var unqualified = false;
    var namespaced = false;
    var function_pointer = false;
    for (program.bindings) |binding| {
        if (binding.kind != .builtin or !binding.dynamic_builtin) continue;
        if (std.mem.eql(u8, binding.resolved_name, "ネイティブ加算")) {
            if (binding.node.kind == .function_pointer) function_pointer = true else unqualified = true;
        }
        if (std.mem.eql(u8, binding.resolved_name, "nativepkg__外部追加")) namespaced = true;
    }
    try std.testing.expect(unqualified);
    try std.testing.expect(namespaced);
    try std.testing.expect(function_pointer);
}

test "動的評価へ引き継いだ実行時登録命令名に無い呼出しは未定義命令として診断する" {
    const parser = @import("../frontend/parser.zig");
    const registered = [_]DynamicCommandAlias{
        .{ .source_namespace = "ネイティブ加算", .dispatch_namespace = "ネイティブ加算", .exact = true },
    };
    var parsed = try parser.parse(std.testing.allocator, "未登録命令(1)\n", "<dynamic>.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var program = try analyzeModules(std.testing.allocator, &.{.{
        .name = "main",
        .path = "<dynamic>.nako3",
        .root = parsed.root.?,
        .dynamic_command_aliases = &registered,
    }});
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
    var diagnosed = false;
    for (program.diagnostics) |item| {
        if (item.code != .undefined_symbol) continue;
        if (std.mem.eql(u8, item.message, "関数『未登録命令』が見当たりません。")) diagnosed = true;
    }
    try std.testing.expect(diagnosed);
}

test "package内scopeの依存命令は所有者修飾のdispatch名へ束縛する" {
    const parser = @import("../frontend/parser.zig");
    // 別package scopeで同じaliasを使う推移依存は、ソース上の `util__命令`
    // を読みやすいまま、runtime登録名は `{owner}__{alias}__命令` へ写す。
    var parsed = try parser.parse(std.testing.allocator, "util__外部追加(1, 2)を表示\n", "dep-module.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    const aliases = [_]DynamicCommandAlias{.{ .source_namespace = "util", .dispatch_namespace = "pkg_a__util" }};
    var program = try analyzeModules(std.testing.allocator, &.{.{
        .name = "dep-module",
        .path = "dep-module.nako3",
        .root = parsed.root.?,
        .dynamic_command_aliases = &aliases,
    }});
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var saw_scoped_dispatch = false;
    for (program.bindings) |binding| {
        if (binding.kind == .builtin and binding.dynamic_builtin and
            std.mem.eql(u8, binding.name, "util__外部追加") and
            std.mem.eql(u8, binding.resolved_name, "pkg_a__util__外部追加")) saw_scoped_dispatch = true;
    }
    try std.testing.expect(saw_scoped_dispatch);
}
