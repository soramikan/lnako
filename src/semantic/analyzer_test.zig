const std = @import("std");
const diagnostic = @import("../frontend/diagnostic.zig");
const analyzer = @import("analyzer.zig");
const analyze = analyzer.analyze;
const analyzeModules = analyzer.analyzeModules;
const moduleName = analyzer.moduleName;
const SymbolKind = analyzer.SymbolKind;

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
