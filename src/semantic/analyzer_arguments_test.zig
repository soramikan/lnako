const std = @import("std");
const analyze = @import("analyzer.zig").analyze;

test "仮引数『引数』と同名宣言の重複診断を保つ" {
    const parser = @import("../frontend/parser.zig");
    const Case = struct {
        fn expectDuplicate(source: []const u8) !void {
            var parsed = try parser.parse(std.testing.allocator, source, "main.nako3");
            defer parsed.deinit();
            var analyzed = try analyze(std.testing.allocator, parsed.root.?, "main.nako3");
            defer analyzed.deinit();
            var found = false;
            for (analyzed.diagnostics) |item| if (item.code == .duplicate_symbol) {
                found = true;
            };
            try std.testing.expect(found);
        }
    };
    // 仮引数`引数`の2個目は通常の仮引数と同じく二重定義として診断する。
    try Case.expectDuplicate("●(引数と引数の)Fとは\n引数を表示\nここまで\nF(1,2)\n");
    // 明示宣言の特例は最初の1回だけで、2個目の宣言は二重定義として診断する。
    try Case.expectDuplicate("●(Aの)Fとは\n変数 引数=1\n変数 引数=2\n引数を表示\nここまで\n5のF\n");
    // 暗黙の`引数`への代入は定義なので、後続の明示宣言は二重定義になる
    // （公式は「定数『引数』の二重定義はできません。」を宣言行で報告する）。
    try Case.expectDuplicate("●(Aの)Fとは\n引数=8\n定数 引数=7\n引数を表示\nここまで\n1のF\n");
    try Case.expectDuplicate("●(Aの)Fとは\n引数を1増やす\n変数 引数=7\n引数を表示\nここまで\n1のF\n");
    // 読み出し・添字参照・プロパティ参照も変数登録になるため、後続の
    // 明示宣言は二重定義になる（公式genVar/varname_setのnames.add相当）。
    try Case.expectDuplicate("●(Aの)Fとは\n引数を表示\n変数 引数=7\nここまで\n5のF\n");
    try Case.expectDuplicate("●(Aの)Fとは\n引数[0]を表示\n変数 引数=7\nここまで\n5のF\n");
    try Case.expectDuplicate("●(Aの)Fとは\n引数$aを表示\n変数 引数=7\nここまで\n5のF\n");
    // 添字代入・添字増減もDNCL初期化モードに関わらず変数登録になる
    // （公式convLetArray/convIncは常にgenVarする）。
    try Case.expectDuplicate("●(Aの)Fとは\n引数[0]=9\n変数 引数=7\nここまで\n5のF\n");
    try Case.expectDuplicate("●(Aの)Fとは\n引数[0]を1増やす\n変数 引数=7\nここまで\n5のF\n");
    // 宣言の初期化式は名前の登録より先に評価されるため自己参照でも二重定義。
    try Case.expectDuplicate("●(Aの)Fとは\n変数 引数=引数\nここまで\n5のF\n");
    // 分割宣言は二重定義を検査しないが名前は登録するため後続の宣言は二重定義。
    try Case.expectDuplicate("●(Aの)Fとは\n変数[引数,B]=[1,2]\n変数 引数=7\nここまで\n5のF\n");
    // ループ変数への適用も変数登録になる。
    try Case.expectDuplicate("●(Aの)Fとは\n引数を1から3まで繰り返す\nここまで\n変数 引数=7\nここまで\n5のF\n");
    // 関数値の中でも独立した暗黙束縛が同じ規則で管理される。
    try Case.expectDuplicate("F=関数(A)\n引数を表示\n変数 引数=7\nここまで\nF(5)\n");
}

test "『引数』の明示宣言は同名ローカルとして再利用し宣言前の代入を拒否しない" {
    const parser = @import("../frontend/parser.zig");
    const Case = struct {
        fn expectDiagnostics(source: []const u8, duplicates: usize, constant_assignments: usize) !void {
            var parsed = try parser.parse(std.testing.allocator, source, "main.nako3");
            defer parsed.deinit();
            var analyzed = try analyze(std.testing.allocator, parsed.root.?, "main.nako3");
            defer analyzed.deinit();
            var duplicate_count: usize = 0;
            var assignment_count: usize = 0;
            for (analyzed.diagnostics) |item| {
                if (item.code == .duplicate_symbol) duplicate_count += 1;
                if (item.code == .assign_to_constant) assignment_count += 1;
            }
            try std.testing.expectEqual(duplicates, duplicate_count);
            try std.testing.expectEqual(constant_assignments, assignment_count);
        }
    };
    // 宣言だけの`引数`は暗黙束縛をそのまま置き換える（公式も受理する）。
    try Case.expectDiagnostics("●(Aの)Fとは\n定数 引数=7\n引数を表示\nここまで\n1のF\n", 0, 0);
    // 宣言後の再代入は定数代入として拒否する（公式と同じ検出段階）。
    try Case.expectDiagnostics("●(Aの)Fとは\n定数 引数=7\n引数=8\nここまで\n1のF\n", 0, 1);
    // 分割宣言は二重定義を検査しない（公式#1027）ため登録済みの`引数`への
    // 適用も成功する。
    try Case.expectDiagnostics("●(Aの)Fとは\n変数 引数=7\n変数[引数,B]=[1,2]\n引数を表示\nここまで\n1のF\n", 0, 0);
    // 未登録の暗黙`引数`への分割宣言も二重定義にならず名前だけ登録される。
    try Case.expectDiagnostics("●(Aの)Fとは\n変数[引数,B]=[1,2]\nここまで\n1のF\n", 0, 0);
    // 定数宣言済みの`引数`への分割宣言はcheckVarWritable相当の代入診断。
    try Case.expectDiagnostics("●(Aの)Fとは\n定数 引数=7\n変数[引数,B]=[1,2]\nここまで\n1のF\n", 0, 1);
    // 定数リストへの`引数`適用は定数化され後続の代入を拒否する。
    try Case.expectDiagnostics("●(Aの)Fとは\n定数[引数,B]=[1,2]\n引数=9\nここまで\n1のF\n", 0, 1);
    // 入れ子関数の`引数`読み出しは外側の束縛に影響しない。
    try Case.expectDiagnostics("●(Aの)Fとは\n●(Bの)Gとは\n引数を表示\nここまで\n変数 引数=7\nここまで\n5のF\n", 0, 0);
}

test "未登録の『引数』へのプロパティ代入は未定義として診断する" {
    const parser = @import("../frontend/parser.zig");
    const Case = struct {
        fn expectUndefinedCount(source: []const u8, expected: usize) !void {
            var parsed = try parser.parse(std.testing.allocator, source, "main.nako3");
            defer parsed.deinit();
            var analyzed = try analyze(std.testing.allocator, parsed.root.?, "main.nako3");
            defer analyzed.deinit();
            var count: usize = 0;
            for (analyzed.diagnostics) |item| if (item.code == .undefined_symbol) {
                count += 1;
            };
            try std.testing.expectEqual(expected, count);
        }
    };
    // 公式convLetPropは登録済みの名前だけを対象にするため、ソース上で
    // 一度も参照・代入・宣言されていない`引数`へのプロパティ代入は
    // 『見当たりません』になる。
    try Case.expectUndefinedCount("●(Aの)Fとは\n引数$a=1\nここまで\n5のF\n", 1);
    // 宣言・読み出し・代入のどれかで登録済みならプロパティ代入は成功する。
    try Case.expectUndefinedCount("●(Aの)Fとは\n変数 引数=7\n引数$a=1\nここまで\n5のF\n", 0);
    try Case.expectUndefinedCount("●(Aの)Fとは\n引数を表示\n引数$a=1\nここまで\n5のF\n", 0);
    try Case.expectUndefinedCount("●(Aの)Fとは\n引数=8\n引数$a=1\nここまで\n5のF\n", 0);
    // 登録はソース上の最初の接触位置で行われるため、後続文での登録は
    // 先行するプロパティ代入を受理しない（公式の単一パス順と同じ）。
    try Case.expectUndefinedCount("●(Aの)Fとは\n引数$a=1\n引数を表示\nここまで\n5のF\n", 1);
    try Case.expectUndefinedCount("●(Aの)Fとは\n引数$a=1\n引数=8\nここまで\n5のF\n", 1);
    try Case.expectUndefinedCount("●(Aの)Fとは\n引数$a=1\n変数 引数=7\nここまで\n5のF\n", 1);
    try Case.expectUndefinedCount("●(Aの)Fとは\n引数$a=1\n変数[引数,B]=[1,2]\nここまで\n5のF\n", 1);
    try Case.expectUndefinedCount("●(Aの)Fとは\n引数$a=1\n引数[0]=9\nここまで\n5のF\n", 1);
    // 制御ブロック内の登録も文順で判定される。
    try Case.expectUndefinedCount("●(Aの)Fとは\nもし1ならば\n引数=0\nここまで\n引数$a=1\nここまで\n5のF\n", 0);
    try Case.expectUndefinedCount("●(Aの)Fとは\n引数$a=1\nもし1ならば\n引数=0\nここまで\nここまで\n5のF\n", 1);
    try Case.expectUndefinedCount("●(Aの)Fとは\nもし1ならば\n引数$a=1\n引数=0\nここまで\nここまで\n5のF\n", 1);
}

test "厳チェックでも関数内の『引数』は未定義にならない" {
    const parser = @import("../frontend/parser.zig");
    var parsed = try parser.parse(std.testing.allocator, "!厳チェック\n●(Aの)Fとは\n引数[0]を表示\nここまで\n1のF\nF2=関数(A)それは引数[0];ここまで\nF2(3)を表示\n", "strict-arguments.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "strict-arguments.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
}
