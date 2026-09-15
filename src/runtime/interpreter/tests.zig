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
const plugin_node = @import("../../plugins/node.zig");
const prepared = @import("prepared.zig");

const Interpreter = istate.Interpreter;
const Host = istate.Host;
const BufferHost = istate.BufferHost;
const Value = shared.Value;
const Runtime = shared.Runtime;
const TestResult = shared.TestResult;
const CompatJsTrace = shared.CompatJsTrace;

test "Prepared Interpreterは関数メタデータを一度だけ解決し実行結果を保つ" {
    const source =
        "●(Aを)二倍とは\n" ++
        "A*2で戻る\n" ++
        "ここまで\n" ++
        "二倍(3)を表示\n";
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

    const first = try interpreter.prepareProgram(&interpreter.root_program);
    const second = try interpreter.prepareProgram(&interpreter.root_program);
    try std.testing.expect(first == second);
    try std.testing.expectEqual(interpreter.root_program.functions.len, first.functions.len);

    var saw_binary = false;
    var saw_direct_call = false;
    var saw_local_slot = false;
    var saw_direct_value_local = false;
    var saw_builtin_id = false;
    var saw_stable_global_slot = false;
    for (first.functions) |function| {
        try std.testing.expect(function.value_count > 0);
        for (function.storage_classes) |storage| {
            if (storage == .value) saw_direct_value_local = true;
        }
        for (function.blocks) |block| for (block.instructions) |instruction| {
            if (instruction.binary_operator) |operator| {
                if (operator == .multiply) saw_binary = true;
            }
            if (instruction.call_target) |target| switch (target) {
                .direct_ir => saw_direct_call = true,
                .global_or_builtin => |builtin_target| {
                    if (builtin_target.id != null) saw_builtin_id = true;
                    if (builtin_target.global_slot != prepared.no_global_slot) saw_stable_global_slot = true;
                },
                else => {},
            };
            if (instruction.local_slot != prepared.no_local_slot) saw_local_slot = true;
        };
    }
    try std.testing.expect(saw_binary);
    try std.testing.expect(saw_direct_call);
    try std.testing.expect(saw_local_slot);
    try std.testing.expect(saw_direct_value_local);
    try std.testing.expect(saw_builtin_id);
    try std.testing.expect(saw_stable_global_slot);

    const reserved_slot = try interpreter.globalSlot("prepared-slot-test");
    try std.testing.expect(interpreter.globalSlotValue(reserved_slot) == null);
    try interpreter.setGlobalValue("prepared-slot-test", .{ .number = 1 });
    try std.testing.expectEqual(reserved_slot, try interpreter.globalSlot("prepared-slot-test"));
    try std.testing.expectEqual(@as(f64, 1), interpreter.globalSlotValue(reserved_slot).?.number);
    try interpreter.setGlobalValue("prepared-slot-test", .{ .number = 2 });
    try std.testing.expectEqual(@as(f64, 2), interpreter.globalSlotValue(reserved_slot).?.number);

    const frame_misses_before = runtime.counters.frame_pools_misses;
    const first_buffer = try interpreter.acquireValueBuffer(3);
    const first_buffer_len = first_buffer.len;
    interpreter.releaseValueBuffer(first_buffer);
    const pooled_before = interpreter.pooled_frame_buffers;
    const second_buffer = try interpreter.acquireValueBuffer(3);
    try std.testing.expectEqual(first_buffer_len, second_buffer.len);
    try std.testing.expect(interpreter.pooled_frame_buffers > pooled_before);
    try std.testing.expect(runtime.counters.frame_pools_misses > frame_misses_before);
    try std.testing.expect(runtime.counters.frame_pools_hits > 0);
    interpreter.releaseValueBuffer(second_buffer);

    _ = try interpreter.run();
    try std.testing.expectEqualStrings("6\n", host.written());
}

test "Prepared Interpreterはinterrupt budgetと命令safepointを維持する" {
    const source = "A=1\nB=2\nC=A+B\nCを表示\n";
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

    interpreter.configureInterruptBudget(2);
    try std.testing.expectEqual(@as(usize, 2), interpreter.interruptBudget());
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("3\n", host.written());
    try std.testing.expect(interpreter.interruptSafepointCount() > 1);
}

test "Prepared Interpreterはdead result storeを省略し戻り値観測を維持する" {
    const overwritten_source =
        "●Aとは\n" ++
        "7で戻る\n" ++
        "ここまで\n" ++
        "A()\n" ++
        "それは9\n" ++
        "それを表示\n";
    var overwritten_fixture = try compileForTest(std.testing.allocator, overwritten_source);
    defer overwritten_fixture.ir_program.deinit();
    defer overwritten_fixture.hir_program.deinit();
    defer overwritten_fixture.analyzed.deinit();
    defer overwritten_fixture.parsed.deinit();
    var overwritten_runtime = Runtime.init(std.testing.allocator);
    defer overwritten_runtime.deinit();
    var overwritten_host = BufferHost{ .allocator = std.testing.allocator };
    defer overwritten_host.deinit();
    var overwritten_interpreter = Interpreter.init(std.testing.allocator, &overwritten_runtime, overwritten_fixture.ir_program, overwritten_host.host());
    defer overwritten_interpreter.deinit();

    const overwritten_prepared = try overwritten_interpreter.prepareProgram(&overwritten_interpreter.root_program);
    var saw_omitted_call = false;
    for (overwritten_prepared.functions) |function| {
        for (function.blocks) |block| for (block.instructions) |instruction| {
            if (instruction.ir_instruction.opcode == .call and instruction.omit_result_store) saw_omitted_call = true;
        };
    }
    try std.testing.expect(saw_omitted_call);
    _ = try overwritten_interpreter.run();
    try std.testing.expectEqualStrings("9\n", overwritten_host.written());

    const observed_source =
        "●Aとは\n" ++
        "7で戻る\n" ++
        "ここまで\n" ++
        "A()\n" ++
        "それを表示\n";
    var observed_fixture = try compileForTest(std.testing.allocator, observed_source);
    defer observed_fixture.ir_program.deinit();
    defer observed_fixture.hir_program.deinit();
    defer observed_fixture.analyzed.deinit();
    defer observed_fixture.parsed.deinit();
    var observed_runtime = Runtime.init(std.testing.allocator);
    defer observed_runtime.deinit();
    var observed_host = BufferHost{ .allocator = std.testing.allocator };
    defer observed_host.deinit();
    var observed_interpreter = Interpreter.init(std.testing.allocator, &observed_runtime, observed_fixture.ir_program, observed_host.host());
    defer observed_interpreter.deinit();

    const observed_prepared = try observed_interpreter.prepareProgram(&observed_interpreter.root_program);
    var saw_kept_call = false;
    var saw_direct_call = false;
    for (observed_prepared.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.ir_instruction.opcode != .call) continue;
        if (instruction.call_target) |target| switch (target) {
            .direct_ir => {
                saw_direct_call = true;
                if (!instruction.omit_result_store) saw_kept_call = true;
            },
            else => {},
        };
    };
    try std.testing.expect(saw_direct_call);
    try std.testing.expect(saw_kept_call);
    _ = try observed_interpreter.run();
    try std.testing.expectEqualStrings("7\n", observed_host.written());
}

test "Prepared InterpreterはToPrimitive callback中のそれを保持する" {
    const source =
        "●Aとは\n" ++
        "7で戻る\n" ++
        "ここまで\n" ++
        "D={}\n" ++
        "D[\"valueOf\"]=関数()それを表示;それは7;ここまで\n" ++
        "A()\n" ++
        "(D-1)を表示\n" ++
        "それは9\n" ++
        "それを表示\n";
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

    const prepared_program = try interpreter.prepareProgram(&interpreter.root_program);
    var saw_kept_call = false;
    for (prepared_program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.ir_instruction.opcode != .call) continue;
        if (instruction.ir_instruction.name.len > 0 and std.mem.endsWith(u8, instruction.ir_instruction.name, "__A")) {
            saw_kept_call = !instruction.omit_result_store;
        }
    };
    try std.testing.expect(saw_kept_call);
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("7\n6\n9\n", host.written());
}

test "Prepared Interpreterはloop・call・allocの割り込みを実際にキャンセルする" {
    const source =
        "F=関数(S)それは真;ここまで\n" ++
        "Fを強制終了時\n" ++
        "HIT=0\n" ++
        "Nを1から100000まで繰り返す\n" ++
        "HIT=HIT+1\n" ++
        "X=[N]\n" ++
        "F()\n" ++
        "ここまで\n" ++
        "\"AFTER\"を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var probe = InterruptProbe{ .cancel_after = 40 };
    var runtime_host = host.host();
    runtime_host.node_context = .{
        .context = &probe,
        .cwdFn = interruptTestCwd,
        .installInterruptFn = interruptTestInstall,
        .consumeInterruptFn = interruptTestConsume,
    };
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, runtime_host);
    defer interpreter.deinit();
    interpreter.configureInterruptBudget(Interpreter.default_interrupt_budget);

    try std.testing.expectError(error.ProcessExitRequested, interpreter.run());
    try std.testing.expect(probe.installed);
    try std.testing.expect(probe.polls >= probe.cancel_after);
    try std.testing.expect(interpreter.interruptSafepointCount() >= probe.polls);
    try std.testing.expect(interpreter.getGlobal("main__HIT") != null);
    try std.testing.expect(interpreter.getGlobal("main__X") != null);
    try std.testing.expectEqualStrings("", host.written());
}

const InterruptProbe = struct {
    polls: usize = 0,
    cancel_after: usize,
    cancel_sent: bool = false,
    installed: bool = false,
};

fn interruptTestCwd(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, ".");
}

fn interruptTestInstall(context: *anyopaque) !void {
    const probe: *InterruptProbe = @ptrCast(@alignCast(context));
    probe.installed = true;
}

fn interruptTestConsume(context: *anyopaque) bool {
    const probe: *InterruptProbe = @ptrCast(@alignCast(context));
    probe.polls += 1;
    if (probe.polls < probe.cancel_after or probe.cancel_sent) return false;
    probe.cancel_sent = true;
    return true;
}

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

const module_graph = @import("../../semantic/module_graph.zig");
const ast_mod = @import("../../frontend/ast.zig");

const ModuleTestFile = struct { suffix: []const u8, source: []const u8 };

const ModuleTestProvider = struct {
    files: []const ModuleTestFile,

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *ModuleTestProvider = @ptrCast(@alignCast(context));
        for (self.files) |file| if (std.mem.endsWith(u8, path, file.suffix)) return allocator.dupe(u8, file.source);
        return error.FileNotFound;
    }
};

/// 複数ファイルを使う取り込み実行の確認用。返す出力は allocator 所有。
fn runModulesForTest(allocator: std.mem.Allocator, files: []const ModuleTestFile) ![]const u8 {
    var provider = ModuleTestProvider{ .files = files };
    var graph = try module_graph.load(allocator, "main.nako3", .{ .context = &provider, .readFn = ModuleTestProvider.read }, .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    var analyzed = try graph.analyze(allocator);
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var roots: std.ArrayList(*ast_mod.Node) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(allocator);
    defer names.deinit(allocator);
    defer paths.deinit(allocator);
    for (graph.modules) |module| {
        if (module.kind != .nako3) continue;
        try roots.append(allocator, module.parsed.?.root.?);
        try names.append(allocator, module.name);
        try paths.append(allocator, module.path);
    }
    var hir_program = try hir.lower(allocator, roots.items, names.items, paths.items, analyzed);
    defer hir_program.deinit();
    var ir_program = try lower_ssa.lower(allocator, hir_program);
    defer ir_program.deinit();
    var verification = try verifier.verify(allocator, ir_program);
    defer verification.deinit();
    try std.testing.expect(verification.succeeded());
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(allocator, &runtime, ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    return allocator.dupe(u8, host.written());
}

test "取り込み文の位置で取り込み先のトップレベルを実行する" {
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "「A1」と表示。\n!「./lib.nako3」を取り込む\n「A2」と表示。\n" },
        .{ .suffix = "lib.nako3", .source = "「B1」と表示。\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("A1\nB1\nA2\n", output);
}

test "取り込みはネストしても取り込み文位置の実行順を保つ" {
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "「A1」と表示。\n!「./mid.nako3」を取り込む\n「A2」と表示。\n" },
        .{ .suffix = "mid.nako3", .source = "「M1」と表示。\n!「./leaf.nako3」を取り込む\n「M2」と表示。\n" },
        .{ .suffix = "leaf.nako3", .source = "「L1」と表示。\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("A1\nM1\nL1\nM2\nA2\n", output);
}

test "同一モジュールの重複取り込みは最後の取り込み文位置で一度だけ実行する" {
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "「A1」と表示。\n!「./lib.nako3」を取り込む\n「A2」と表示。\n!「./lib.nako3」を取り込む\n「A3」と表示。\n" },
        .{ .suffix = "lib.nako3", .source = "「B1」と表示。\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("A1\nA2\nB1\nA3\n", output);
}

test "循環取り込みはエントリ内容を一度だけ再展開する" {
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "「A1」と表示。\n!「./lib.nako3」を取り込む\n「A2」と表示。\n" },
        .{ .suffix = "lib.nako3", .source = "「B1」と表示。\n!「./main.nako3」を取り込む\n「B2」と表示。\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("A1\nB1\nA1\nA2\nB2\nA2\n", output);
}

test "関数本体内の取り込みは呼び出し毎に実行する" {
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "●Fとは\n　!「./lib.nako3」を取り込む\n　「f-end」と表示。\nここまで。\nF。\nF。\n" },
        .{ .suffix = "lib.nako3", .source = "「B1」と表示。\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("B1\nf-end\nB1\nf-end\n", output);
}

test "関数本体内の取り込みは入れ子の取り込みも呼び出し毎に実行する" {
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "●Fとは\n　!「./lib.nako3」を取り込む\n　「f-end」と表示。\nここまで。\nF。\nF。\n" },
        .{ .suffix = "lib.nako3", .source = "「B1」と表示。\n!「./sub.nako3」を取り込む\n「B2」と表示。\n" },
        .{ .suffix = "sub.nako3", .source = "「S1」と表示。\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("B1\nS1\nB2\nf-end\nB1\nS1\nB2\nf-end\n", output);
}

test "ループ本体内の取り込みは繰り返し毎に実行する" {
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "3回\n　!「./lib.nako3」を取り込む\nここまで。\n" },
        .{ .suffix = "lib.nako3", .source = "「B1」と表示。\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("B1\nB1\nB1\n", output);
}

test "エントリの自己取り込みは一度だけ再展開する" {
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "「M1」と表示。\n!「./main.nako3」を取り込む\n「M2」と表示。\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("M1\nM1\nM2\nM2\n", output);
}

test "関数本体内の取り込み先からの呼び戻しで取り込み内容を再実行する" {
    // 公式は取り込み先トークンを関数本体へ静的展開するため、関数が取り込み
    // 先のコードから呼び戻されると取り込み内容も毎回実行される（実行中の
    // モジュールエントリを無条件に抑止するガードではこのケースが終了して
    // しまい公式と一致しない）。main__Gは修飾名なのでモジュール変数になり、
    // 3回目で再帰が止まる。
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "G=0\n●Fとは\n　「F内」と表示。\n　!「./lib.nako3」を取り込む\nここまで。\nF。\nGを表示。\n" },
        .{ .suffix = "lib.nako3", .source = "「lib側」と表示。\nmain__G=main__G+1\nもし、main__G<3ならば\n　main__F()\nここまで。\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("F内\nlib側\nF内\nlib側\nF内\nlib側\n3\n", output);
}

test "取り込んだモジュールの同名シンボルは展開順の先勝ちで解決する" {
    // 公式findVarはmodList（エントリ→展開マーカー順）で最初に一致した
    // 公開モジュールシンボルを選ぶ。曖昧さエラーにはならない。
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "!「./a.nako3」を取り込む\n!「./b.nako3」を取り込む\nFを表示\nAXを表示\n" },
        .{ .suffix = "a.nako3", .source = "●Fとは\n「A」で戻る\nここまで\n変数 AX=1\n" },
        .{ .suffix = "b.nako3", .source = "●Fとは\n「B」で戻る\nここまで\n変数 AX=2\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("A\n1\n", output);
}

test "推移的に取り込んだモジュールの変数を裸名で解決する" {
    // 公式のmodListは直接importではなく展開された全モジュールを含む
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "!「./mid.nako3」を取り込む\nXを表示\n" },
        .{ .suffix = "mid.nako3", .source = "!「./leaf.nako3」を取り込む\n" },
        .{ .suffix = "leaf.nako3", .source = "変数 X=99\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("99\n", output);
}

test "取り込み先の代入はエントリの同名変数をmodList解決で上書きする" {
    // 公式は代入先もfindVarで解決するため、modBの X=99 は先に展開
    // マーカーが出たエントリの main__X へ書き込まれる。
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "X=1\n!「./mod.nako3」を取り込む\nXを表示\n" },
        .{ .suffix = "mod.nako3", .source = "X=99\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("99\n", output);
}

test "取り込み先の変数宣言はエントリの同名変数を上書きしない" {
    // 変数宣言はfindVarを使わずcreateVar相当で常にmodB__Xを作る。
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "変数 X=1\n!「./mod.nako3」を取り込む\nXを表示\n" },
        .{ .suffix = "mod.nako3", .source = "変数 X=99\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("1\n", output);
}

test "取り込み先関数本体内の代入もmodList順でエントリ変数を上書きする" {
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "X=1\n!「./mod.nako3」を取り込む\nF()\nXを表示\n" },
        .{ .suffix = "mod.nako3", .source = "●Fとは\nX=99\nここまで\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("99\n", output);
}

test "関数定義位置より後のエントリ変数は取り込み先関数から見えない" {
    // 関数本体のパース時点では main__X が未登録のため X は関数ローカル。
    const output = try runModulesForTest(std.testing.allocator, &.{
        .{ .suffix = "main.nako3", .source = "!「./mod.nako3」を取り込む\nX=1\nG()\nXを表示\n" },
        .{ .suffix = "mod.nako3", .source = "●Gとは\nX=99\nここまで\n" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("1\n", output);
}

test "DNCL自動初期化は中間添字をcheck式とwrite-back式で評価し直す" {
    // 公式convLetArrayは `if (!(tmp[k0]..[ki] instanceof Array)) { tmp[k0]..[ki] = 新規配列 }`
    // を生成するため、初期化が走る中間レベルの添字式はcheck・write-back・
    // 後続レベルのcheck/write-back・最終代入で合計2×中間レベル数+1回評価される。
    // A[1,2,f()]=99 はDNCLの逆順規則で A[f()][2][1] になるため f() は5回評価される。
    const source = "●fとは\n「f評価」を表示\nそれは1\nここまで\n!DNCLモード\nA[1,2,f()]=99\n「---」を表示\nA[1,2,1]を表示\n";
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
    try std.testing.expectEqualStrings("f評価\nf評価\nf評価\nf評価\nf評価\n---\n99\n", host.written());
}

test "DNCL自動初期化のwrite-backでnullishな親は設定系TypeErrorになる" {
    // g()はcheck時とwrite-back時で異なる添字を返し、write-backの親走査が
    // 未初期化要素へずれ込む。公式はwrite-back式 `tmp[..]=新規配列` が
    // 『Cannot set properties of undefined』で失敗する（読み出し系ではない）。
    const source = "G=-1\nSEQ=[1,1,1,32,1]\n●gとは\nG=G+1\nそれはSEQ[G]\nここまで\n●hとは\nそれは0\nここまで\n!DNCLモード\nA=[9]\nA[h(),1,g(),1]=77\n「完了」を表示\n";
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
    try std.testing.expectError(error.NakoException, interpreter.run());
    const message_utf8 = try interpreter.exception_value.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(message_utf8);
    try std.testing.expectEqualStrings("Cannot set properties of undefined (setting '0')", message_utf8);
}

test "添字代入はルート変数を添字・値の評価より先に束縛する" {
    // 公式convLetは `get(name)[k0] = value` を生成し、コンテナ参照を
    // 添字評価より先に束縛する。添字式がルート変数を再束縛しても
    // 代入は束縛済みの古いコンテナへ行われ、値の評価は添字の後になる。
    // 公式では A[0] は再束縛後の新しい配列を指すため 10 になる。
    const source = "A=[1,2]\n●fとは\nA=[10,20]\nそれは0\nここまで\nA[f()]=9\nA[0]を表示\n";
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
    try std.testing.expectEqualStrings("10\n", host.written());
}

test "添字代入は添字式を値の評価より先に評価する" {
    // 公式convLetは `get(name)[key] = value` で、keyの評価がvalueより先。
    // プロパティ代入 `A["x"]=f()` でも同じく、値評価中の再束縛後ではなく
    // 束縛済みのコンテナへ書き込む（公式では A["x"] は新しい辞書の 10）。
    const source = "A=[1,2]\n●fとは\n「F評価」を表示\nそれは0\nここまで\n●gとは\n「G評価」を表示\nそれは9\nここまで\nA[f()]=g()\nA[0]を表示\n";
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
    try std.testing.expectEqualStrings("F評価\nG評価\n9\n", host.written());
}

test "添字増減はルート変数を添字評価より先に束縛する" {
    // 公式convIncは `o1=get(name); i1=k; ...` でコンテナを添字評価より
    // 先に束縛する。添字式がルート変数を再束縛しても増減は束縛済みの
    // 古いコンテナへ行われる（公式では A[0] は新しい配列の 10）。
    const source = "A=[1,2]\n●fとは\nA=[10,20]\nそれは0\nここまで\nA[f()]を5増やす\nA[0]を表示\n";
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
    try std.testing.expectEqualStrings("10\n", host.written());
}

test "増減量式は要素読み出し・undefined初期化の後に評価される" {
    // 公式convIncは `v0 = varGetter` で読み出してから
    // `Number(v0) + Number(incValue)` の行で増減量式を評価する。
    // 量の式が対象を再代入しても加算には読み出し済みの値が使われ、
    // 最終的な書き戻しは量の式による代入を上書きする
    // （公式は f()でX=100・戻り値6 → Xは 5+6=11、g()でA[0]=50・戻り値7 → A[0]は 1+7=8）。
    const source = "X=5\nA=[1,2]\n●fとは\nX=100\nそれは6\nここまで\n●gとは\nA[0]=50\nそれは7\nここまで\nXを(f())増やす\nA[0]を(g())増やす\nXを表示\nA[0]を表示\n";
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
    try std.testing.expectEqualStrings("11\n8\n", host.written());
}

test "添字増減の書き戻しは量の評価後に中間コンテナを再走査する" {
    // 公式convIncのvarSetterは `o1[i1]…` を量の評価後に再評価する。
    // 量の式が中間コンテナを差し替えた場合、書き戻しは新しい中間
    // コンテナへ行われる（公式は A[0][0] が 11）。
    const source = "A=[[1,2]]\n●fとは\nA[0]=[9]\nそれは10\nここまで\nA[0][0]を(f())増やす\nA[0][0]を表示\n";
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
    try std.testing.expectEqualStrings("11\n", host.written());
}

test "DNCL最終代入は初期化チェック後にルート変数を読み直す" {
    // 公式convLetArrayの最終代入は `code = name` から生成するため、
    // 初期化チェックの添字評価でルートが再束縛されると新しい値へ
    // 書き込もうとする。A[2,f()]=7 はDNCL逆順で A[f()][2] になり、
    // f()のA=9への再束縛後は数値の要素代入が
    // 『Cannot set properties of undefined』で失敗する。
    const source = "A=[[1,2],[3,4]]\n●fとは\nA=9\nそれは0\nここまで\n!DNCLモード\nA[2,f()]=7\n「完了」を表示\n";
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
    try std.testing.expectError(error.NakoException, interpreter.run());
    const message_utf8 = try interpreter.exception_value.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(message_utf8);
    try std.testing.expectEqualStrings("Cannot set properties of undefined (setting '1')", message_utf8);
}

fn testInterpreterCustomString(runtime: *Runtime, _: []const Value) !Value {
    return runtime.stringUtf8("CUSTOM");
}

fn testInterpreterConstantSeven(_: *Runtime, _: []const Value) !Value {
    return .{ .number = 7 };
}

test "Interpreterのtrace未設定時はemitがロックを取得しない" {
    var dispatch = shared.DispatchTrace{};
    dispatch.emit("表示", "test", "success", 1);
    dispatch.finish();
    var global = shared.GlobalTrace{};
    global.emit("それ", true, 1);
    global.emitWrite("それ", 1);
    global.finish();
    var literal = shared.LiteralTrace{};
    literal.emit("あ", 1);
    literal.finish();
    var compat = CompatJsTrace{};
    compat.emit("JS実行", "eval", "call", null, 1);
    compat.finish();
    try std.testing.expectEqual(@as(u64, 0), dispatch.lock_attempts);
    try std.testing.expectEqual(@as(u64, 0), global.lock_attempts);
    try std.testing.expectEqual(@as(u64, 0), literal.lock_attempts);
    try std.testing.expectEqual(@as(u64, 0), compat.lock_attempts);
}
