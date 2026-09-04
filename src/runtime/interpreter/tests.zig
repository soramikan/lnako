const std = @import("std");
const istate = @import("state.zig");
const shared = @import("shared.zig");
const value_mod = @import("../value.zig");
const parser = @import("../../frontend/parser.zig");
const semantic = @import("../../semantic/analyzer.zig");
const hir = @import("../../ir/hir.zig");
const lower_ssa = @import("../../ir/lower_ssa.zig");
const verifier = @import("../../ir/verifier.zig");
const ir = @import("../../ir/nako_ir.zig");

const Interpreter = istate.Interpreter;
const Host = istate.Host;
const BufferHost = istate.BufferHost;
const Value = shared.Value;
const Runtime = shared.Runtime;
const TestResult = shared.TestResult;
const CompatJsTrace = shared.CompatJsTrace;

test "SSA IRで条件・反復・関数・配列辞書を実行する" {
    const source = "●(AとBを)足すとは\nA+Bで戻る\nここまで\n合計=0\nNを1から3まで繰り返す\n合計=合計+N\nここまで\nもし合計=6ならば\n足す(合計,4)を表示\n違えば\n0を表示\nここまで\nA=[1,2]\nA[1]=5\nA[1]を表示\nB={\"x\":7}\nB@\"x\"を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("10\n5\n7\n", host.written());
}

test "Interpreter幅変換は辞書のカスタムsubstring・charAt・splitとprototypeを呼び出す" {
    const source =
        "P={}\n" ++
        "P[\"substring\"]=関数(A,B)それは\"x\";ここまで\n" ++
        "P[\"charAt\"]=関数(A)それは\"ｱ\";ここまで\n" ++
        "D={\"__proto__\":P,\"length\":2}\n" ++
        "カタカナ全角変換(D)を表示\n" ++
        "Q={}\n" ++
        "Q[\"split\"]=関数(A)それは[\"ガ\",\"ッ\",\"ツ\"];ここまで\n" ++
        "E={\"__proto__\":Q}\n" ++
        "カタカナ半角変換(E)を表示\n" ++
        "全角変換(D)を表示\n" ++
        "半角変換(E)を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("アア\nｶﾞｯﾂ\nアア\nｶﾞｯﾂ\n", host.written());
}

test "礼節状態と名前空間スタックと公開言語カタログを実行する" {
    const source =
        "●甲とは\n1で戻る\nここまで\n" ++
        "名前空間を表示\nプラグイン名を表示\n" ++
        "敬具()\n礼節レベル取得()を表示\n敬具()\n礼節レベル取得()を表示\nください()\n礼節レベル取得()を表示\n" ++
        "プラグイン名設定(\"副\")\n名前空間設定(\"内側\")\nプラグイン名設定(\"孫\")\n" ++
        "名前空間を表示\nプラグイン名を表示\n名前空間ポップ()\n名前空間を表示\nプラグイン名を表示\n" ++
        "JSON変換(グローバル関数一覧取得())を表示\n" ++
        "要素数(システム関数一覧取得())を表示\n" ++
        "要素数(助詞一覧取得())を表示\n要素数(予約語一覧取得())を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings(
        "main\nメイン\n0\n100\n101\n内側\n孫\nmain\n副\n[\"main__甲\"]\n478\n48\n38\n",
        host.written(),
    );
}

test "特殊実行とデバッグ支援命令を実行する" {
    const source =
        "●(Aを)倍とは\nA*2で戻る\nここまで\n" ++
        "●七とは\n7で戻る\nここまで\n" ++
        "●空関数とは\n1で戻る\nここまで\n" ++
        "ASYNC()\nAWAIT実行(\"倍\",[3])を表示\n実行(\"七\")を表示\n実行(9)を表示\n" ++
        "実行時間計測(\"空関数\")を表示\nデバッグ表示({\"a\":1})\n??(2+3)\n" ++
        "ハテナ関数設定([\"文字列変換\",\"デバッグ表示\"])\n??(6)\n" ++
        "エラー監視\n\"故意\"のエラー発生\nエラーならば\nエラーメッセージを表示\nここまで\n" ++
        "__DEBUG_BP_WAIT(12)を表示\nASSERT等(1,1)を表示\n__DEBUG()\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expect(interpreter.debug_enabled);
    try std.testing.expectEqualStrings(
        "6\n7\n9\n0\nmain.nako3(15): {\"a\":1}\nmain.nako3(16): 5\nmain.nako3(18): 6\n故意\n12\nundefined\n",
        host.written(),
    );
}

test "ASSERT等はNodeのSameValue境界を保つ" {
    var fixture = try compileForTest(std.testing.allocator, "ASSERT等(非数,非数)を表示\n");
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("undefined\n", host.written());
}

test "AWAIT実行でPromiseを完了させブレイクポイント待機を解除する" {
    const source =
        "●(Xを)待機値とは\nXで戻る\nここまで\n" ++
        "動いた時には(成功,失敗)\n0.001秒後には\n成功(8)\nここまで\nここまで\n" ++
        "P=そ\nAWAIT実行(\"待機値\",[P])を表示\n" ++
        "__DEBUGブレイクポイント一覧=[13]\n__DEBUG待機フラグ=1\n__DEBUG_BP_WAIT(13)を表示\n__DEBUG待機フラグを表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("8\n13\n0\n", host.written());
}

test "Windowsのデバッグ表示パスを公式処理系と同じドライブ名へ短縮する" {
    try std.testing.expectEqualStrings(
        "C",
        Interpreter.normalizeDebugSourcePath("C:\\work\\main.nako3", true),
    );
    try std.testing.expectEqualStrings(
        "/work/main.nako3",
        Interpreter.normalizeDebugSourcePath("/work/main.nako3", false),
    );
}

test "バイト列の添字・更新・反復をUint8Array互換で実行する" {
    const TestNode = struct {
        pub fn cwd(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, ".");
        }

        pub fn randomBytes(_: *anyopaque, output: []u8) !void {
            for (output, 0..) |*byte, index| byte.* = @intCast(index);
        }
    };
    const source = "B=3のランダム配列生成\nB[0]を表示\nB[1]=258\n要素数(B)を表示\nBを反復\n対象を表示\nここまで\nAB=B[\"buffer\"]\nAB[\"length\"]=2\nAB[\"0\"]=\"x\"\nAB[\"1\"]=\"y\"\n何文字目(AB,\"xy\")を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var runtime_host = host.host();
    runtime_host.node_context = .{ .context = &host, .cwdFn = TestNode.cwd, .randomBytesFn = TestNode.randomBytes };
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, runtime_host);
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("0\n3\n0\n2\n2\n1\n", host.written());
}

test "連続表示は公式処理系と同じく改行する" {
    var fixture = try compileForTest(std.testing.allocator, "\"100%安全%s\"を連続表示\n\"次\"を表示\n");
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("100%安全%s\n次\n", host.written());
}

test "例外監視と動的ななでしこ実行を処理する" {
    const source = "エラー監視\n\"失敗\"のエラー発生\nエラーならば\nエラーメッセージを表示\nここまで\n\"1+2を表示する。\"をナデシコする。\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("失敗\n3\n", host.written());
}

test "global read traceはbuiltin dispatch traceと分離される" {
    const source = "PIを表示\n永遠を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var runtime_host = host.host();
    runtime_host.global_trace_path = "global-trace.jsonl";
    runtime_host.global_trace_writeFn = BufferHost.writeGlobalTrace;
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, runtime_host);
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expect(std.mem.indexOf(u8, host.global_trace.items, "\"phase\":\"global-read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.global_trace.items, "\"name\":\"PI\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.global_trace.items, "\"name\":\"永遠\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.global_trace.items, "\"phase\":\"dispatch-result\"") == null);
}

test "compat-js traceは4命令をoperation別metadataとして記録する" {
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var trace = CompatJsTrace{
        .path = "compat-js-trace.jsonl",
        .context = &host,
        .writeFn = BufferHost.writeCompatJsTrace,
    };
    trace.emit("JS実行", "eval", "compat-js-attempt", null, 0x0000000100000001);
    trace.emit("JS実行", "eval", "compat-js-result", "success", 0x0000000100000001);
    trace.emit("JSオブジェクト取得", "lookup", "compat-js-attempt", null, 0x0000000100000003);
    trace.emit("JSオブジェクト取得", "lookup", "compat-js-result", "success", 0x0000000100000003);
    trace.emit("JS関数実行", "call", "compat-js-attempt", null, 0x0000000100000006);
    trace.emit("JS関数実行", "call", "compat-js-result", "success", 0x0000000100000006);
    trace.emit("JSメソッド実行", "method-call", "compat-js-attempt", null, 0x0000000100000008);
    trace.emit("JSメソッド実行", "method-call", "compat-js-result", "success", 0x0000000100000008);
    trace.finish();
    try std.testing.expect(std.mem.indexOf(u8, host.compat_js_trace.items, "\"operation\":\"eval\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.compat_js_trace.items, "\"operation\":\"lookup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.compat_js_trace.items, "\"operation\":\"call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.compat_js_trace.items, "\"operation\":\"method-call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.compat_js_trace.items, "\"phase\":\"trace-end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.compat_js_trace.items, "\"source\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, host.compat_js_trace.items, "\"args\"") == null);
}

test "global read/write traceは実行順とbuiltin dispatch traceから分離される" {
    const source = "ファイルコピーデフォルト動作を表示\nファイルコピーデフォルト動作=\"上書\"\nファイルコピーデフォルト動作を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var runtime_host = host.host();
    runtime_host.global_trace_path = "global-binding-trace.jsonl";
    runtime_host.global_trace_writeFn = BufferHost.writeGlobalTrace;
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, runtime_host);
    defer interpreter.deinit();
    _ = try interpreter.run();
    const first_read = std.mem.indexOf(u8, host.global_trace.items, "\"phase\":\"global-read\"").?;
    const write = std.mem.indexOf(u8, host.global_trace.items, "\"phase\":\"global-write\"").?;
    const second_read = std.mem.indexOfPos(u8, host.global_trace.items, write + 1, "\"phase\":\"global-read\"").?;
    try std.testing.expect(first_read < write);
    try std.testing.expect(write < second_read);
    try std.testing.expect(std.mem.indexOf(u8, host.global_trace.items, "\"name\":\"ファイルコピーデフォルト動作\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.global_trace.items, "\"phase\":\"dispatch-result\"") == null);
}

test "catalog literal traceはglobal read traceと分離される" {
    const source = "はいを表示\nいいえを表示\n真を表示\n偽を表示\nオンを表示\nオフを表示\nNULLを表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var runtime_host = host.host();
    runtime_host.literal_trace_path = "literal-trace.jsonl";
    runtime_host.literal_trace_writeFn = BufferHost.writeLiteralTrace;
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, runtime_host);
    defer interpreter.deinit();
    _ = try interpreter.run();
    var lines = std.mem.splitScalar(u8, host.literal_trace.items, '\n');
    var event_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len > 0 and std.mem.indexOf(u8, line, "\"phase\":\"literal\"") != null) event_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), event_count);
    try std.testing.expect(std.mem.indexOf(u8, host.literal_trace.items, "\"name\":\"NULL\"") != null);
    try std.testing.expect(host.global_trace.items.len == 0);
}

test "動的実行のbuiltin traceは動的IRのsiteを親IRへ混ぜない" {
    const source = "\"1を表示\"をナデシコする。\n\"2を表示\"をナデシコ続。\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var runtime_host = host.host();
    runtime_host.dispatch_trace_path = "dynamic-trace.jsonl";
    runtime_host.dispatch_trace_writeFn = BufferHost.writeDispatchTrace;
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, runtime_host);
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("1\n2\n", host.written());
    try std.testing.expect(std.mem.indexOf(u8, host.dispatch_trace.items, "\"siteId\":null,\"command\":\"表示\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.dispatch_trace.items, "\"siteId\":null,\"command\":\"ナデシコ\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, host.dispatch_trace.items, "\"siteId\":null,\"command\":\"ナデシコ続\"") == null);
}

test "動的実行中も保留Promiseのcallbackが生成元IRを参照する" {
    const source =
        "●(Aを)補正とは\n" ++
        "A+1で戻る\n" ++
        "ここまで\n" ++
        "動いた時には(成功,失敗)\n" ++
        "成功(9)\n" ++
        "ここまで\n" ++
        "F=それ\n" ++
        "Fの成功した時には\n" ++
        "補正(対象)を表示\n" ++
        "ここまで\n" ++
        "ナデシコ(\"1を表示\")\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("1\n10\n", host.written());
}

test "エラー発生は公式Error.messageの値変換を行う" {
    const source =
        "エラー監視\nundefinedのエラー発生\nエラーならば\n(\"U:\"&エラーメッセージ)を表示\nここまで\n" ++
        "エラー監視\n123のエラー発生\nエラーならば\n(\"N:\"&エラーメッセージ)を表示\nここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("U:\nN:123\n", host.written());
}

test "配列生成の安全上限を命令別の診断へ変換する" {
    const source =
        "エラー監視\n" ++
        "配列連番作成(0,無限大)を表示\n" ++
        "エラーならば\n" ++
        "エラーメッセージを表示\n" ++
        "ここまで\n" ++
        "エラー監視\n" ++
        "配列要素作成(0,無限大)を表示\n" ++
        "エラーならば\n" ++
        "エラーメッセージを表示\n" ++
        "ここまで\n" ++
        "A=[0]\n" ++
        "エラー監視\n" ++
        "配列入替(A,0,1000000)を表示\n" ++
        "エラーならば\n" ++
        "エラーメッセージを表示\n" ++
        "ここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings(
        "Array sequence exceeds safety limit\nArray fill size exceeds safety limit\nSparse array length exceeds safety limit\n",
        host.written(),
    );
}

test "辞書のカスタムToPrimitiveはヒント順序と失敗を保つ" {
    const source =
        "D={}\n" ++
        "D[\"toString\"]=関数()それは\"CUSTOM\";ここまで\n" ++
        "文字列変換(D)を表示\n" ++
        "P={}\n" ++
        "P[\"toString\"]=関数()それは\"PROTO\";ここまで\n" ++
        "D={\"__proto__\":P}\n" ++
        "文字列変換(D)を表示\n" ++
        "D={}\n" ++
        "D[\"toString\"]=関数()それは\"12x\";ここまで\n" ++
        "実数変換(D)を表示\n" ++
        "D={}\n" ++
        "D[\"valueOf\"]=関数()それは7;ここまで\n" ++
        "(D-1)を表示\n" ++
        "(D+1)を表示\n" ++
        "D={}\n" ++
        "D[\"toString\"]=関数()それは{};ここまで\n" ++
        "D[\"valueOf\"]=関数()それは7;ここまで\n" ++
        "文字列変換(D)を表示\n" ++
        "D={}\n" ++
        "D[\"toString\"]=関数()それは{};ここまで\n" ++
        "D[\"valueOf\"]=関数()それは{};ここまで\n" ++
        "エラー監視\n" ++
        "文字列変換(D)を表示\n" ++
        "エラーならば\n" ++
        "エラーメッセージを表示\n" ++
        "ここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("CUSTOM\nPROTO\n12\n6\nNaN\n7\nCannot convert object to primitive value\n", host.written());
}

test "配列のカスタムToPrimitiveは文字列と数値hintへ接続する" {
    const source =
        "A=[1,2]\n" ++
        "A[\"toString\"]=関数()それは\"ARRAY\";ここまで\n" ++
        "文字列変換(A)を表示\n" ++
        "B=[1,2]\n" ++
        "B[\"valueOf\"]=関数()それは7;ここまで\n" ++
        "(B-1)を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("ARRAY\n6\n", host.written());
}

test "byte bufferのcustom prototypeをToPrimitiveへ接続する" {
    var fixture = try compileForTest(std.testing.allocator, "");
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = [_]Value{.undefined} ** 6;
    var root_frame = runtime.rootFrame();
    defer root_frame.deinit();
    for (&roots) |*root| try root_frame.protect(root);
    roots[0] = try runtime.createBytes(&.{ 85, 66 });
    roots[1] = try runtime.createUint8Array(&.{ 85, 66 });
    roots[2] = try runtime.createArrayBuffer(&.{ 85, 66 });
    const to_string_name = try runtime.stringUtf8("toString");
    roots[3] = try runtime.createNativeFunction(to_string_name.string, 0, testInterpreterCustomString, &.{});
    const value_of_name = try runtime.stringUtf8("valueOf");
    roots[4] = try runtime.createNativeFunction(value_of_name.string, 0, testInterpreterConstantSeven, &.{});
    roots[5] = try runtime.createDictionary();
    try roots[5].dictionary.set((try runtime.stringUtf8("toString")).string, roots[3]);
    roots[0].bytes.prototype = roots[5];
    roots[1].bytes.prototype = roots[5];
    var number_prototype = try runtime.createDictionary();
    try root_frame.protect(&number_prototype);
    try number_prototype.dictionary.set((try runtime.stringUtf8("valueOf")).string, roots[4]);
    roots[2].bytes.prototype = number_prototype;
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    const buffer_primitive = (try interpreter.objectToPrimitive(roots[0], .string)).?;
    try std.testing.expect(buffer_primitive == .string);
    try std.testing.expectEqualSlices(u16, &.{ 'C', 'U', 'S', 'T', 'O', 'M' }, buffer_primitive.string.units);
    const uint8_primitive = (try interpreter.objectToPrimitive(roots[1], .string)).?;
    try std.testing.expect(uint8_primitive == .string);
    try std.testing.expectEqualSlices(u16, &.{ 'C', 'U', 'S', 'T', 'O', 'M' }, uint8_primitive.string.units);
    const number = (try interpreter.objectToPrimitive(roots[2], .number)).?;
    try std.testing.expect(number == .number);
    try std.testing.expectEqual(@as(f64, 7), number.number);
}

test "テスト定義を個別に実行して結果を記録する" {
    var fixture = try compileForTest(std.testing.allocator, "●テスト:成功とは\n1と1がASSERT等\nここまで\n●テスト:失敗とは\n0と1がASSERT等\nここまで\n");
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    const results = try interpreter.runTests();
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(results[0].passed);
    try std.testing.expect(!results[1].passed);
}

test "抜ける・続ける・反復・条件分岐を実行する" {
    const source = "S=0\nIを1から5まで繰り返す\nもしI=2ならば、続ける\nもしI=4ならば、抜ける\nS=S+I\nここまで\nSを表示\n[3,4]を反復\n対象を表示\nここまで\n2で条件分岐\n1ならば\n\"a\"を表示\nここまで\n2ならば\n\"b\"を表示\nここまで\n違えば\n\"c\"を表示\nここまで\nここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("4\n3\n4\nb\n", host.written());
}

test "無名関数がローカル変数を捕捉する" {
    const source = "●(Aを)加算器作成とは\nF=関数(B)それはA+B\nここまで\nFで戻る\nここまで\nG=加算器作成(10)\nG(5)を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("15\n", host.written());
}

test "クロージャが外側の可変束縛を共有する" {
    const source =
        "●(Aを)作るとは\n" ++
        "F=関数()\n" ++
        "A=A+1\n" ++
        "Aで戻る\n" ++
        "ここまで\n" ++
        "H=関数()それはA\n" ++
        "ここまで\n" ++
        "A=4\n" ++
        "[F,H]で戻る\n" ++
        "ここまで\n" ++
        "P=作る(1)\n" ++
        "G=P[0]\n" ++
        "H=P[1]\n" ++
        "G()を表示\n" ++
        "H()を表示\n" ++
        "G()を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("5\n5\n6\n", host.written());
}

test "関数の戻り値だけをシステム変数それへ書き戻す" {
    const source = "●七とは\n7で戻る\nここまで\n●空とは\nここまで\n●暗黙とは\nそれは8\nここまで\n七()\nA=それ\n空()\nB=それ\n暗黙()\nC=それ\nAを表示\nBを表示\nCを表示\n表示(1)\nそれを表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("7\nundefined\n8\n1\n8\n", host.written());
}

test "動的関数の不足引数へ共有システム文脈を追加し超過引数を無視する" {
    const source =
        "F=関数(A,B)\nAを表示\nBを表示\nここまで\n" ++
        "F()\nF(1)\nF(2,3,4)\n" ++
        "G=関数(A)それはA;ここまで\nX=G()\nY=G()\nXを表示\nX===Yを表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings(
        "[object Object]\nundefined\n1\n[object Object]\n2\n3\n[object Object]\ntrue\n",
        host.written(),
    );
}

test "Promiseの成功・失敗・処理・終了コールバックを順に実行する" {
    const source =
        "動いた時には(成功,失敗)\n" ++
        "成功(9)\n" ++
        "ここまで\n" ++
        "Pはそれ\n" ++
        "Pの成功した時には\n" ++
        "対象を表示\n" ++
        "ここまで\n" ++
        "動いた時には(成功,失敗)\n" ++
        "失敗(5)\n" ++
        "ここまで\n" ++
        "Qはそれ\n" ++
        "Qの処理した時には(OK,値)\n" ++
        "OKを表示\n" ++
        "値を表示\n" ++
        "ここまで\n" ++
        "その終了した時には\n" ++
        "\"完了\"を表示\n" ++
        "ここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("9\nfalse\n5\n完了\n", host.written());
}

test "GCストレス中もタイマーからPromiseを解決する" {
    const source =
        "動いた時には(成功,失敗)\n" ++
        "0.001秒後には\n" ++
        "成功(7)\n" ++
        "ここまで\n" ++
        "ここまで\n" ++
        "Pはそ\n" ++
        "Pの成功した時には\n" ++
        "対象を表示\n" ++
        "ここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("7\n", host.written());
    try std.testing.expectEqual(@as(u64, 1), host.elapsed_milliseconds);
}

test "決定的時計でタイマーの順序・停止・待機を処理する" {
    const source =
        "0.003秒後には\n" ++
        "\"三\"を表示\n" ++
        "ここまで\n" ++
        "0.001秒後には\n" ++
        "\"一\"を表示\n" ++
        "ここまで\n" ++
        "0.002秒後には\n" ++
        "\"停止失敗\"を表示\n" ++
        "ここまで\n" ++
        "対象のタイマー停止\n" ++
        "0.004秒毎には(TID)\n" ++
        "\"毎\"を表示\n" ++
        "TIDのタイマー停止\n" ++
        "ここまで\n" ++
        "0.005秒待つ\n" ++
        "\"待\"を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("一\n三\n毎\n待\n", host.written());
    try std.testing.expectEqual(@as(u64, 5), host.elapsed_milliseconds);
}

test "BigIntの整数除算を公式生成JavaScript同様に拒否する" {
    var fixture = try compileForTest(std.testing.allocator, "10n÷÷3nを表示\n");
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    try std.testing.expectError(error.CannotConvertBigIntToNumber, interpreter.run());
}

test "引数なし連続加算は共有システム文脈を返す" {
    const source = "A=連続加算()\nB=連続加算()\nAを表示\n(A===B)を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("[object Object]\ntrue\n", host.written());
}

test "CHRの不正コードポイントを値付き公式文言で監視する" {
    const source =
        "エラー監視\nCHR(-1)を表示\nエラーならば\nエラーメッセージを表示\nここまで\n" ++
        "エラー監視\nCHR(1.5)を表示\nエラーならば\nエラーメッセージを表示\nここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("Invalid code point -1\nInvalid code point 1.5\n", host.written());
}

test "文字列挿入検索は公式の小数位置とNaN位置を保持する" {
    const source =
        "文字挿入(\"A😀B\",2,\"X\")を表示\n" ++
        "文字挿入(\"ABC\",2.9,\"X\")を表示\n" ++
        "文字挿入(\"ABC\",\"2rest\",\"X\")を表示\n" ++
        "文字検索(\"A😀B😀\",3,\"😀\")を表示\n" ++
        "文字検索(\"A😀B😀\",2.9,\"😀\")を表示\n" ++
        "文字検索(\"A😀B😀\",\"2rest\",\"😀\")を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("AX😀B\nAXBC\nXABC\n4\n2.9\n0\n", host.written());
}

test "文字列連結反復出現は公式のnullと小数と空区切りを扱う" {
    const source =
        "連結(\"a\",1,NULL,undefined)を表示\n" ++
        "リフレイン(\"x\",2.1)を表示\n" ++
        "リフレイン(\"x\",\"2rest\")を表示\n" ++
        "出現回数(\"😀\",\"\")を表示\n" ++
        "出現回数(\"\",\"\")を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("a1\nxxx\n\n1\n-1\n", host.written());
}

test "部分文字列命令は数値小数と文字列小数と位置0を区別する" {
    const source =
        "文字抜出(\"A😀BCD\",2.9,2.9)を表示\n" ++
        "文字抜出(\"A😀BCD\",\"2.9\",\"2.9\")を表示\n" ++
        "文字抜出(\"ABCDE\",0,2)を表示\n" ++
        "LEFT(\"A😀BCD\",2.9)を表示\n" ++
        "RIGHT(\"A😀BCD\",2.9)を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("😀BC\n😀B\n\nA😀\nBCD\n", host.written());
}

test "文字削除はspliceの負位置と数値化不能削除数を扱う" {
    const source =
        "文字削除(\"ABCDE\",\"2rest\",\"2rest\")を表示\n" ++
        "文字削除(\"ABCDE\",0,2)を表示\n" ++
        "文字削除(\"ABCDE\",-1,2)を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("ABCDE\nABCD\nABC\n", host.written());
}

test "単置換の置換パターンと全置換の空検索語を公式通り処理する" {
    const source =
        "置換(\"abc\",\"\",\"-\")を表示\n" ++
        "置換(\"abc\",\"b\",\"[$&]\")を表示\n" ++
        "単置換(\"abc\",\"b\",\"[$$][$&][$`][$']\")を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("a-b-c\na[$&]c\na[$][b][a][c]c\n", host.written());
}

test "連続する例外監視で直前の捕捉値を再利用しない" {
    const source =
        "エラー監視\nA=1n+1\nエラーならば\nエラーメッセージを表示\nここまで\n" ++
        "エラー監視\nB=5n÷÷2n\nエラーならば\nエラーメッセージを表示\nここまで\n" ++
        "エラー監視\nC=1n>>>1n\nエラーならば\nエラーメッセージを表示\nここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings(
        "Cannot mix BigInt and other types, use explicit conversions\n" ++
            "Cannot convert a BigInt value to a number\n" ++
            "BigInts have no unsigned right shift, use >> instead\n",
        host.written(),
    );
}

test "プリミティブへの添字代入と反復を公式同様に無操作とする" {
    const source =
        "A=1\nA[0]=2\nAを表示\n" ++
        "B=「abc」\nB[0]=「x」\nBを表示\n" ++
        "NULLを反復\n「到達不可」を表示\nここまで\n" ++
        "はいを反復\n「到達不可」を表示\nここまで\n" ++
        "「後」を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("1\nabc\n後\n", host.written());
}

test "nullとundefinedへの添字代入をキー付き例外として監視する" {
    const source =
        "エラー監視\nNULL[0]=2\nエラーならば\nエラーメッセージを表示\nここまで\n" ++
        "A=undefined\nエラー監視\nA[「x」]=2\nエラーならば\nエラーメッセージを表示\nここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings(
        "Cannot set properties of null (setting '0')\n" ++
            "Cannot set properties of undefined (setting 'x')\n",
        host.written(),
    );
}

test "GCストレス中も実行フレームと反復対象をルートとして保持する" {
    const source = "A=[\"保持\",\"対象\"]\nAを反復\n対象を表示\nここまで\nB={\"key\":\"value\"}\nB@\"key\"を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("保持\n対象\nvalue\n", host.written());
}

test "継続表示プール・表示ログ・改行なし出力を公式規則で処理する" {
    const source =
        "\"A\"を継続表示\n" ++
        "\"B\"を継続表示\n" ++
        "\"C\"を表示\n" ++
        "表示ログを表示\n" ++
        "表示ログクリア\n" ++
        "\"X\"を言\n" ++
        "\"Y\"をコンソール表示\n" ++
        "連続表示(\"1\",2,3)\n" ++
        "連続無改行表示(\"a\",\"b\")\n" ++
        "\"c\"を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("ABC\nABC\n\nX\nY\n123\nabc\n", host.written());
    const log = interpreter.getGlobal("表示ログ").?;
    const log_utf8 = try log.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(log_utf8);
    try std.testing.expectEqualStrings("123\nabc\n", log_utf8);
}

test "配列コールバックと固定日時・乱数ホストを実行する" {
    const source =
        "●(Aを)二倍とは\nA*2で戻る\nここまで\n" ++
        "●(Aを)偶数判定関数とは\n偶数(A)で戻る\nここまで\n" ++
        "●(AとBを)降順とは\nB-Aで戻る\nここまで\n" ++
        "JSON変換(配列マップ(\"二倍\",[1,2,3]))を表示\n" ++
        "JSON変換(配列フィルタ(\"偶数判定関数\",[1,2,3,4]))を表示\n" ++
        "JSON変換(配列カスタムソート(\"降順\",[1,3,2]))を表示\n" ++
        "今日()を表示\n" ++
        "時間ミリ秒取得()を表示\n" ++
        "JSON変換(配列シャッフル([1,2,3,4]))を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("[2,4,6]\n[2,4]\n[3,2,1]\n2025/01/01\n0\n[2,3,1,4]\n", host.written());
}

fn compileForTest(allocator: std.mem.Allocator, source: []const u8) !struct {
    parsed: parser.ParseResult,
    analyzed: semantic.Program,
    hir_program: hir.Program,
    ir_program: ir.Program,
} {
    const parsed = try parser.parse(allocator, source, "main.nako3");
    const analyzed = try semantic.analyze(allocator, parsed.root.?, "main.nako3");
    const hir_program = try hir.lowerSingle(allocator, parsed.root.?, "main", "main.nako3", analyzed);
    const ir_program = try lower_ssa.lower(allocator, hir_program);
    return .{ .parsed = parsed, .analyzed = analyzed, .hir_program = hir_program, .ir_program = ir_program };
}

fn testInterpreterCustomString(runtime: *Runtime, _: []const Value) !Value {
    return runtime.stringUtf8("CUSTOM");
}

fn testInterpreterConstantSeven(_: *Runtime, _: []const Value) !Value {
    return .{ .number = 7 };
}
