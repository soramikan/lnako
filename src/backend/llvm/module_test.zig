const std = @import("std");
const module_mod = @import("module.zig");
const ir = @import("../../ir/nako_ir.zig");
const parser = @import("../../frontend/parser.zig");
const semantic = @import("../../semantic/analyzer.zig");
const hir = @import("../../ir/hir.zig");
const lower = @import("../../ir/lower_ssa.zig");
const optimizer = @import("../../ir/optimizer.zig");

const generate = module_mod.generate;
const findUnsupported = module_mod.findUnsupported;
const isNativePluginCall = module_mod.isNativePluginCall;

test "package経由のnative plugin命令を修飾名でemitしnamespace登録する" {
    // package plugin命令は `{namespace}__{命令}` でのみ動的builtinへ束縛する。
    var parsed = try parser.parse(std.testing.allocator, "math__外部追加(1, 2)を表示\n", "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    const aliases = [_]semantic.DynamicCommandAlias{.{ .source_namespace = "math", .dispatch_namespace = "math" }};
    var analyzed = try semantic.analyzeModules(std.testing.allocator, &.{.{
        .name = "main",
        .path = "main.nako3",
        .root = parsed.root.?,
        .dynamic_command_aliases = &aliases,
    }});
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lower(std.testing.allocator, &.{parsed.root.?}, &.{"main"}, &.{"main.nako3"}, &.{&.{}}, analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const path_allocator = program.arena.allocator();
    const paths = try path_allocator.alloc([]const u8, 1);
    paths[0] = try path_allocator.dupe(u8, "/tmp/liblnako_pkg_plugin.dylib");
    program.native_plugin_paths = paths;
    const packages = try path_allocator.alloc(ir.NativePluginPackage, 1);
    packages[0] = .{ .path = try path_allocator.dupe(u8, "/tmp/liblnako_pkg_plugin.dylib"), .namespace = "math" };
    program.native_plugin_packages = packages;

    // 修飾名は動的グローバルではなくplugin dispatchへ流れる
    var qualified_plugin_call = false;
    for (program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .call or !std.mem.eql(u8, instruction.name, "math__外部追加")) continue;
        qualified_plugin_call = true;
        // package aliasへ束縛された呼出しには動的builtinの印が付く
        try std.testing.expect(instruction.dynamic_call);
        try std.testing.expect(isNativePluginCall(program, function, instruction));
    };
    try std.testing.expect(qualified_plugin_call);
    try std.testing.expect(findUnsupported(program) == null);

    var module = try generate(std.testing.allocator, program, "main.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_native_plugin_package_register(ptr, i64, ptr, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.native.plugin.namespace.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_native_plugin_package_register(ptr @lnako.native.plugin.path.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_native_plugin_call(ptr %root.slot.") != null);
}

test "package pluginを取り込んでいないmoduleの修飾名呼出しはplugin dispatchへ流さない" {
    // 取り込み辺（dynamic_command_aliases）を持たないmoduleが登録済みの
    // package namespaceと同じprefixを持つ名前を書いても、意味解析の動的
    // 束縛を経ないためplugin callへ分類しない（信頼境界）。
    var parsed = try parser.parse(std.testing.allocator, "math__外部追加(1, 2)を表示\n", "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyzeModules(std.testing.allocator, &.{.{
        .name = "main",
        .path = "main.nako3",
        .root = parsed.root.?,
    }});
    defer analyzed.deinit();
    var hir_program = try hir.lower(std.testing.allocator, &.{parsed.root.?}, &.{"main"}, &.{"main.nako3"}, &.{&.{}}, analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const path_allocator = program.arena.allocator();
    const paths = try path_allocator.alloc([]const u8, 1);
    paths[0] = try path_allocator.dupe(u8, "/tmp/liblnako_pkg_plugin.dylib");
    program.native_plugin_paths = paths;
    const packages = try path_allocator.alloc(ir.NativePluginPackage, 1);
    packages[0] = .{ .path = try path_allocator.dupe(u8, "/tmp/liblnako_pkg_plugin.dylib"), .namespace = "math" };
    program.native_plugin_packages = packages;

    var qualified_call = false;
    for (program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .call or !std.mem.eql(u8, instruction.name, "math__外部追加")) continue;
        qualified_call = true;
        try std.testing.expect(!instruction.dynamic_call);
        try std.testing.expect(!isNativePluginCall(program, function, instruction));
    };
    try std.testing.expect(qualified_call);
}

/// 数値bodyの`F`は、条件付き代入のローカル`X`を未代入のまま読む。
/// インタプリタでは`undefined`（NaN）になるため、内部bodyの入口で
/// NaNへ初期化しておく必要がある。
const typed_local_number_fixture =
    \\●(Nを)Fとは
    \\もし、N>1ならば
    \\X=N
    \\ここまで
    \\X+1で戻る
    \\ここまで
    \\F(0)を表示
    \\
;

/// 真偽値ローカルの未代入参照は、初期化しないと`br i1 undef`（完全なUB）になる。
const typed_local_boolean_fixture =
    \\●(Nを)判定とは
    \\もし、N>1ならば
    \\B=(N=2)
    \\ここまで
    \\もしBならば
    \\1で戻る
    \\ここまで
    \\0で戻る
    \\ここまで
    \\判定(0)を表示
    \\
;

fn optimizedModuleText(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var parsed = try parser.parse(allocator, source, "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var lowered = try lower.lower(allocator, hir_program);
    defer lowered.deinit();
    var program = try lowered.clone(allocator);
    defer program.deinit();
    _ = try optimizer.optimize(allocator, &program, .{ .max_iterations = 8, .preserve_named_dynamic = true });
    var module = try generate(allocator, program, "main.nako3", true);
    defer module.deinit(allocator);
    return allocator.dupe(u8, module.text);
}

test "型付きbodyのローカルは未代入でも意味論上の値で初期化される" {
    // `%typed.local.N`はallocaだけで初期化されず、条件付き代入の枝を通らない
    // 経路では未初期化のスタック値が読まれていた（数値は非決定、i1は`br i1 undef`）。
    const text = try optimizedModuleText(std.testing.allocator, typed_local_number_fixture);
    defer std.testing.allocator.free(text);
    const init_store = std.mem.indexOf(u8, text, "store double 0x7FF8000000000000, ptr %typed.local.1") orelse return error.TestUnexpectedResult;
    const first_load = std.mem.indexOf(u8, text, "load double, ptr %typed.local.1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(init_store < first_load);
}

test "型付きbodyの真偽値ローカルは分岐条件より前に偽で初期化される" {
    const text = try optimizedModuleText(std.testing.allocator, typed_local_boolean_fixture);
    defer std.testing.allocator.free(text);
    const init_store = std.mem.indexOf(u8, text, "store i1 false, ptr %typed.local.1") orelse return error.TestUnexpectedResult;
    const condition_load = std.mem.indexOf(u8, text, "load i1, ptr %typed.local.1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(init_store < condition_load);
    try std.testing.expect(std.mem.indexOf(u8, text, "br i1 undef") == null);
}

fn countIrOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| {
        count += 1;
        index = found + needle.len;
    }
    return count;
}

/// 深度ゲートを通らない`@lnako.fn.{id}`直接呼び出しのうち、入口・wrapper・
/// モジュールエントリ以外のもの（＝`writeCall`の旧来の静的呼び出し）を数える。
fn countUngatedStaticCalls(text: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, " = call %lnako.Value @lnako.fn.") == null) continue;
        if (std.mem.indexOf(u8, line, ".depth.value = call") != null) continue;
        if (std.mem.indexOf(u8, line, "%entry.result = call") != null) continue;
        if (std.mem.indexOf(u8, line, "%wrapper.result = call") != null) continue;
        if (std.mem.indexOf(u8, line, "%import.value.") != null) continue;
        count += 1;
    }
    return count;
}

test "静的呼び出しはAOTの深度ゲートを通り上限で未定義値へ合流する" {
    // 自己再帰は`lnako_aot_function_call`を通らない直接callになるため、
    // 同じ深度上限を共有するゲートを必ず経由させる。
    var parsed = try parser.parse(std.testing.allocator, "●再帰(N)とは\n  もし N > 0 ならば\n    再帰(N - 1)を表示\n  ここまで\nここまで\n再帰(3)を表示\n", "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyzeModules(std.testing.allocator, &.{.{
        .name = "main",
        .path = "main.nako3",
        .root = parsed.root.?,
    }});
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lower(std.testing.allocator, &.{parsed.root.?}, &.{"main"}, &.{"main.nako3"}, &.{&.{}}, analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();

    var module = try generate(std.testing.allocator, program, "main.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare i32 @lnako_aot_call_depth_enter()") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_call_depth_leave()") != null);
    // 直接callはすべてゲート内の`.depth.value`経由で発行される。
    const guarded_calls = countIrOccurrences(module.text, ".depth.value = call %lnako.Value @lnako.fn.");
    try std.testing.expect(guarded_calls >= 2);
    try std.testing.expectEqual(guarded_calls, countIrOccurrences(module.text, ".depth.invoke:"));
    try std.testing.expectEqual(guarded_calls, countIrOccurrences(module.text, ".depth.limit:"));
    // ゲート外に残る直接呼び出しは、プログラム入口・生成wrapper・モジュール
    // エントリ（いずれも外側から入る境界）に限られる。`writeCall`が発行する
    // 旧来の`%v{id} = call`形式が1つでも残れば0にならない。
    try std.testing.expectEqual(@as(usize, 0), countUngatedStaticCalls(module.text));
    // 入口と帰りは必ず対称。
    try std.testing.expectEqual(countIrOccurrences(module.text, "call i32 @lnako_aot_call_depth_enter()"), countIrOccurrences(module.text, "call void @lnako_aot_call_depth_leave()"));
    // 上限到達経路は呼び出しを行わず、未定義値のphiで合流する。
    try std.testing.expect(std.mem.indexOf(u8, module.text, "phi %lnako.Value [ { i8 0, i64 0 }, %call.") != null);
}

test "最適化時のtyped直接呼び出しも同じ深度ゲートを通る" {
    // typed ABIの呼び出しはIR最適化で引数型がnumber/booleanへ確定した関数にだけ
    // 出る。O1以降と同じ手順（optimize→generate(true)）で数値関数を特殊化し、
    // typed直接呼び出しもgeneric経路と同じゲートを通ることを確かめる。
    var parsed = try parser.parse(std.testing.allocator, "●(Aを)Fとは\nB=A+1\nもしAならば\nBで戻る\n違えば\n0で戻る\nここまで\nここまで\nX=F(2)\nXを表示\n", "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var optimized_program = try program.clone(std.testing.allocator);
    defer optimized_program.deinit();
    _ = try optimizer.optimize(std.testing.allocator, &optimized_program, .{});
    try std.testing.expectEqual(ir.Type.number, optimized_program.findFunction("main__F").?.parameters[0].type);

    var module = try generate(std.testing.allocator, optimized_program, "main.nako3", true);
    defer module.deinit(std.testing.allocator);
    const typed_calls = countIrOccurrences(module.text, " = call double @lnako.fn.number.") +
        countIrOccurrences(module.text, " = call i1 @lnako.fn.boolean.");
    const gated_typed = countIrOccurrences(module.text, ".depth.value = call double @lnako.fn.number.") +
        countIrOccurrences(module.text, ".depth.value = call i1 @lnako.fn.boolean.");
    // 特殊化された呼び出しが実際に存在し、そのすべてがゲート内にある。
    try std.testing.expect(typed_calls >= 1);
    try std.testing.expectEqual(typed_calls, gated_typed);
}

test "compat-js AOTはESM manifestとQuickJS dispatchをemitし、通常AOTは混入させない" {
    // 通常AOT: QuickJS/compat ABIもESM manifestも生成物へ入らない。
    var parsed = try parser.parse(std.testing.allocator, "1+2を表示\n", "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "main.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "lnako_aot_compat_") == null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "lnako_qjs_") == null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.compat.esm.manifest") == null);

    // compat AOT: `JS実行` のdispatchとESM manifestの収録・登録をemitする。
    var compat_parsed = try parser.parse(std.testing.allocator, "JS実行(\"1+2\")を表示\n", "main.nako3");
    defer compat_parsed.deinit();
    try std.testing.expect(compat_parsed.succeeded());
    var compat_analyzed = try semantic.analyze(std.testing.allocator, compat_parsed.root.?, "main.nako3");
    defer compat_analyzed.deinit();
    try std.testing.expect(compat_analyzed.succeeded());
    var compat_hir = try hir.lowerSingle(std.testing.allocator, compat_parsed.root.?, "main", "main.nako3", compat_analyzed);
    defer compat_hir.deinit();
    var compat_program = try lower.lower(std.testing.allocator, compat_hir);
    defer compat_program.deinit();
    // 通常AOTは同じprogramを未対応として拒否する。
    try std.testing.expect(findUnsupported(compat_program) != null);
    compat_program.compat_js = true;
    const js_modules = try compat_program.arena.allocator().alloc(ir.JavaScriptModule, 1);
    js_modules[0] = .{
        .path = "mod.mjs",
        .source = "export function add(a, b) { return a + b; }",
        .is_plugin = false,
        .namespaces = &.{},
        .package_root = null,
        .bare_aliases = &.{},
    };
    compat_program.javascript_modules = js_modules;
    try std.testing.expect(findUnsupported(compat_program) == null);
    var compat_module = try generate(std.testing.allocator, compat_program, "main.nako3", false);
    defer compat_module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, compat_module.text, "declare void @lnako_aot_compat_js_eval(ptr, ptr, i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, compat_module.text, "call void @lnako_aot_compat_js_eval(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, compat_module.text, "@lnako.compat.esm.manifest = constant") != null);
    try std.testing.expect(std.mem.indexOf(u8, compat_module.text, "call void @lnako_aot_compat_esm_register(ptr @lnako.compat.esm.manifest") != null);
    // ESM登録失敗はエントリ実行前に既存の例外経路で終了する。
    try std.testing.expect(std.mem.indexOf(u8, compat_module.text, "entry.compat.esm.exception.abort:") != null);
    try std.testing.expect(std.mem.indexOf(u8, compat_module.text, "mod.mjs") != null);
    try std.testing.expect(std.mem.indexOf(u8, compat_module.text, "call void @lnako_aot_compat_deinit()") != null);
}

test "compat-js AOTは4つのJS命令を許可し、通常AOTは拒否する" {
    const cases = [_]struct {
        source: []const u8,
        callee: []const u8,
    }{
        .{ .source = "JS関数実行(\"(a,b)=>a+b\",[1,2])を表示\n", .callee = "lnako_aot_compat_js_call" },
        .{ .source = "JSオブジェクト取得(\"x\",\"y\")を表示\n", .callee = "lnako_aot_compat_js_object_get" },
        .{ .source = "JSメソッド実行(\"f\",\"m\",[])\n", .callee = "lnako_aot_compat_js_method_call" },
    };
    for (cases) |test_case| {
        var parsed = try parser.parse(std.testing.allocator, test_case.source, "main.nako3");
        defer parsed.deinit();
        try std.testing.expect(parsed.succeeded());
        var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
        defer analyzed.deinit();
        try std.testing.expect(analyzed.succeeded());
        var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
        defer hir_program.deinit();
        var program = try lower.lower(std.testing.allocator, hir_program);
        defer program.deinit();
        // 通常AOTはcompat専用命令を依然として拒否する。
        try std.testing.expect(findUnsupported(program) != null);
        program.compat_js = true;
        try std.testing.expect(findUnsupported(program) == null);
        var module = try generate(std.testing.allocator, program, "main.nako3", false);
        defer module.deinit(std.testing.allocator);
        const declaration = try std.fmt.allocPrint(std.testing.allocator, "declare void @{s}(ptr, ptr, i64)", .{test_case.callee});
        defer std.testing.allocator.free(declaration);
        try std.testing.expect(std.mem.indexOf(u8, module.text, declaration) != null);
        const call = try std.fmt.allocPrint(std.testing.allocator, "call void @{s}(ptr ", .{test_case.callee});
        defer std.testing.allocator.free(call);
        try std.testing.expect(std.mem.indexOf(u8, module.text, call) != null);
    }
}

/// `--compat-js` を有効化したAOTモジュールテキストを生成する。
fn compatJsModuleText(allocator: std.mem.Allocator, source: []const u8, optimized: bool) ![]u8 {
    var parsed = try parser.parse(allocator, source, "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(allocator, hir_program);
    defer program.deinit();
    // compat専用命令は通常AOTでは未対応のまま。
    try std.testing.expect(findUnsupported(program) != null);
    program.compat_js = true;
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(allocator, program, "main.nako3", optimized);
    defer module.deinit(allocator);
    return allocator.dupe(u8, module.text);
}

fn extractDefinedFunction(module_text: []const u8, id: ir.FunctionId) ![]const u8 {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "define internal %lnako.Value @lnako.fn.{d}(", .{id});
    const start = std.mem.indexOf(u8, module_text, header) orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, module_text, start, "\n}\n") orelse return error.TestUnexpectedResult;
    return module_text[start .. end + 3];
}

fn findIrFunctionBySuffix(program: ir.Program, suffix: []const u8) ?ir.Function {
    for (program.functions) |function| {
        if (std.mem.eql(u8, function.name, suffix) or std.mem.endsWith(u8, function.name, suffix)) return function;
    }
    return null;
}

fn countSubstring(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |found| {
        count += 1;
        pos = found + needle.len;
    }
    return count;
}

test "compat-js AOTは変数bridgeのフレーム・未束縛初期化・ロード正規化を最適化有無双方でemitする" {
    // 1) capture + JS実行（正常return）、2) 捕捉ありthrow + 継続、
    // 3) 未捕捉throw（throw_value target==null）、4) 例外伝播（propagate_exception）、
    // 5) 呼び出しの無いリーフ関数（var.frame省略）を1プログラムで検証する。
    const source =
        "●加算(Aを)\n" ++
        "  B=A+1\n" ++
        "  F=関数()\n" ++
        "    Bで戻る\n" ++
        "  ここまで\n" ++
        "  JS実行(\"1+2\")を表示\n" ++
        "  Bで戻る\n" ++
        "ここまで\n" ++
        "●捕捉処理(Xを)\n" ++
        "  Y=X+1\n" ++
        "  エラー監視\n" ++
        "    \"err\"のエラー発生\n" ++
        "  エラーならば\n" ++
        "    Y=Y+10\n" ++
        "  ここまで\n" ++
        "  JS実行(\"1\")を表示\n" ++
        "  Yで戻る\n" ++
        "ここまで\n" ++
        "●未捕捉送出(Zを)\n" ++
        "  W=Z+1\n" ++
        "  JS実行(\"1\")を表示\n" ++
        "  \"boom\"のエラー発生\n" ++
        "  Wで戻る\n" ++
        "ここまで\n" ++
        "●例外伝播(Pを)\n" ++
        "  Q=P+1\n" ++
        "  未捕捉送出(Q)を表示\n" ++
        "  Qで戻る\n" ++
        "ここまで\n" ++
        "●リーフ(Lを)\n" ++
        "  R=L\n" ++
        "  Rで戻る\n" ++
        "ここまで\n" ++
        "●演算(Lを)\n" ++
        "  R=L+1\n" ++
        "  Rで戻る\n" ++
        "ここまで\n" ++
        "加算(2)を表示\n" ++
        "捕捉処理(3)を表示\n" ++
        "例外伝播(4)を表示\n" ++
        "リーフ(5)を表示\n" ++
        "演算(6)を表示\n";

    var parsed = try parser.parse(std.testing.allocator, source, "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) != null);
    program.compat_js = true;
    try std.testing.expect(findUnsupported(program) == null);

    const add_fn = findIrFunctionBySuffix(program, "__加算") orelse findIrFunctionBySuffix(program, "加算") orelse return error.TestUnexpectedResult;
    const catch_fn = findIrFunctionBySuffix(program, "__捕捉処理") orelse findIrFunctionBySuffix(program, "捕捉処理") orelse return error.TestUnexpectedResult;
    const uncaught_fn = findIrFunctionBySuffix(program, "__未捕捉送出") orelse findIrFunctionBySuffix(program, "未捕捉送出") orelse return error.TestUnexpectedResult;
    const prop_fn = findIrFunctionBySuffix(program, "__例外伝播") orelse findIrFunctionBySuffix(program, "例外伝播") orelse return error.TestUnexpectedResult;
    const leaf_fn = findIrFunctionBySuffix(program, "__リーフ") orelse findIrFunctionBySuffix(program, "リーフ") orelse return error.TestUnexpectedResult;
    const operation_fn = findIrFunctionBySuffix(program, "__演算") orelse findIrFunctionBySuffix(program, "演算") orelse return error.TestUnexpectedResult;

    for ([_]bool{ false, true }) |optimized| {
        var module = try generate(std.testing.allocator, program, "main.nako3", optimized);
        defer module.deinit(std.testing.allocator);
        const text = module.text;

        try std.testing.expect(std.mem.indexOf(u8, text, "%lnako.AotVarEntry = type { ptr, i64 }") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "%lnako.AotVarFrame = type { ptr, ptr, i64, ptr }") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "declare void @lnako_aot_push_var_frame(ptr, ptr, i64, ptr)") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "declare void @lnako_aot_pop_var_frame(ptr)") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "store %lnako.Value { i8 0, i64 1 }, ptr %root.slot.") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "%runtime.unbound = alloca %lnako.Value") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "%v.unbound.is-undefined.") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "select i1 %v.unbound.is-undefined.") != null);

        // 1) 加算（capture + 正常return）: push 1回、全 ret 前に pop_var_frame -> pop_roots
        const add_ir = try extractDefinedFunction(text, add_fn.id);
        try std.testing.expectEqual(@as(usize, 1), countSubstring(add_ir, "call void @lnako_aot_push_var_frame("));
        try std.testing.expectEqual(countSubstring(add_ir, "ret %lnako.Value"), countSubstring(add_ir, "call void @lnako_aot_pop_var_frame(ptr %var.frame)\n  call void @lnako_aot_pop_roots(ptr %root.frame)"));

        // 2) 捕捉処理（エラー監視内のthrow_value target!=null）: catch分岐前でpopしない
        const catch_ir = try extractDefinedFunction(text, catch_fn.id);
        try std.testing.expectEqual(@as(usize, 1), countSubstring(catch_ir, "call void @lnako_aot_push_var_frame("));
        const catch_set_pos = std.mem.indexOf(u8, catch_ir, "call void @lnako_aot_exception_set") orelse return error.TestUnexpectedResult;
        const catch_branch_pos = std.mem.indexOfPos(u8, catch_ir, catch_set_pos, "  br label %bb") orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, catch_ir[catch_set_pos..catch_branch_pos], "lnako_aot_pop_var_frame") == null);
        try std.testing.expectEqual(countSubstring(catch_ir, "ret %lnako.Value"), countSubstring(catch_ir, "call void @lnako_aot_pop_var_frame(ptr %var.frame)\n  call void @lnako_aot_pop_roots(ptr %root.frame)"));

        // 3) 未捕捉送出（throw_value target==null）: throw後もpop_var_frame -> pop_roots
        const uncaught_ir = try extractDefinedFunction(text, uncaught_fn.id);
        try std.testing.expectEqual(@as(usize, 1), countSubstring(uncaught_ir, "call void @lnako_aot_push_var_frame("));
        try std.testing.expect(countSubstring(uncaught_ir, "ret %lnako.Value") >= 2);
        try std.testing.expectEqual(countSubstring(uncaught_ir, "ret %lnako.Value"), countSubstring(uncaught_ir, "call void @lnako_aot_pop_var_frame(ptr %var.frame)\n  call void @lnako_aot_pop_roots(ptr %root.frame)"));

        // 4) 例外伝播（propagate_exception）: 伝播脱出経路もpop_var_frame -> pop_roots
        const prop_ir = try extractDefinedFunction(text, prop_fn.id);
        try std.testing.expectEqual(@as(usize, 1), countSubstring(prop_ir, "call void @lnako_aot_push_var_frame("));
        try std.testing.expect(countSubstring(prop_ir, "ret %lnako.Value") >= 2);
        try std.testing.expectEqual(countSubstring(prop_ir, "ret %lnako.Value"), countSubstring(prop_ir, "call void @lnako_aot_pop_var_frame(ptr %var.frame)\n  call void @lnako_aot_pop_roots(ptr %root.frame)"));

        // 5) リーフ関数: 呼び出しが無いため var.frame を出力しない
        const leaf_ir = try extractDefinedFunction(text, leaf_fn.id);
        try std.testing.expect(std.mem.indexOf(u8, leaf_ir, "lnako_aot_push_var_frame") == null);
        try std.testing.expect(std.mem.indexOf(u8, leaf_ir, "lnako_aot_pop_var_frame") == null);

        // 6) `.binary` を持つ関数: valueOf/toString 経由でJSからローカル変数を
        //    観測され得るため、リーフでも var.frame を省略しない。
        const operation_ir = try extractDefinedFunction(text, operation_fn.id);
        try std.testing.expectEqual(@as(usize, 1), countSubstring(operation_ir, "call void @lnako_aot_push_var_frame("));
        try std.testing.expectEqual(countSubstring(operation_ir, "ret %lnako.Value"), countSubstring(operation_ir, "call void @lnako_aot_pop_var_frame(ptr %var.frame)\n  call void @lnako_aot_pop_roots(ptr %root.frame)"));
    }
}

test "通常AOTは変数bridgeの型・シンボル・未束縛初期化を一切emitしない" {
    var parsed = try parser.parse(std.testing.allocator, "●加算(Aを)\n  B=A+1\n  Bで戻る\nここまで\n加算(2)を表示\n", "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "main.nako3", false);
    defer module.deinit(std.testing.allocator);

    for ([_][]const u8{
        "lnako_aot_push_var_frame",
        "lnako_aot_pop_var_frame",
        "%lnako.AotVarEntry",
        "%lnako.AotVarFrame",
        ".var.names",
        "%runtime.unbound",
        "%v.unbound.",
        "{ i8 0, i64 1 }",
    }) |forbidden| {
        try std.testing.expect(std.mem.indexOf(u8, module.text, forbidden) == null);
    }
}

test "compat-js AOTはESM登録前に変数・実行環境定数を登録し名前付き関数専用スロットを除外する" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "●補助(Xを)\n  X+1で戻る\nここまで\nユーザー変数=42\nJS実行(\"1+2\")を表示\n",
        "main.nako3",
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    program.compat_js = true;
    const js_modules = try program.arena.allocator().alloc(ir.JavaScriptModule, 1);
    js_modules[0] = .{
        .path = "mod.mjs",
        .source = "export function add(a, b) { return a + b; }",
        .is_plugin = false,
        .namespaces = &.{},
        .package_root = null,
        .bare_aliases = &.{},
    };
    program.javascript_modules = js_modules;
    var module = try generate(std.testing.allocator, program, "main.nako3", false);
    defer module.deinit(std.testing.allocator);

    const register_index = std.mem.indexOf(u8, module.text, "call void @lnako_aot_dynamic_global_register(") orelse return error.TestUnexpectedResult;
    const node_constants_index = std.mem.indexOf(u8, module.text, "call void @lnako_aot_node_constants_init") orelse return error.TestUnexpectedResult;
    const dir_constants_index = std.mem.indexOf(u8, module.text, "call void @lnako_aot_node_directory_constants_init(") orelse return error.TestUnexpectedResult;
    const mother_path_index = std.mem.indexOf(u8, module.text, "call void @lnako_aot_node_mother_path_init(") orelse return error.TestUnexpectedResult;
    const system_index = std.mem.indexOf(u8, module.text, "call void @lnako_aot_string_new(") orelse return error.TestUnexpectedResult;
    const esm_index = std.mem.indexOf(u8, module.text, "call void @lnako_aot_compat_esm_register(") orelse return error.TestUnexpectedResult;
    const entry_index = std.mem.indexOf(u8, module.text, "%entry.result = call %lnako.Value @lnako.fn.") orelse return error.TestUnexpectedResult;
    // グローバル登録・実行環境システム定数初期化がESM登録より前、ESM登録が
    // トップレベル評価より前であること。
    try std.testing.expect(register_index < esm_index);
    try std.testing.expect(node_constants_index < esm_index);
    try std.testing.expect(dir_constants_index < esm_index);
    try std.testing.expect(mother_path_index < esm_index);
    try std.testing.expect(system_index < esm_index);
    try std.testing.expect(esm_index < entry_index);

    // 名前付き関数生成スロットは `dynamic_globals` へ登録せず、ユーザー変数スロットは登録する。
    const helper_fn = findIrFunctionBySuffix(program, "__補助") orelse findIrFunctionBySuffix(program, "補助") orelse return error.TestUnexpectedResult;
    const helper_decl = try std.fmt.allocPrint(std.testing.allocator, "ptr @lnako.function.name.{d}", .{helper_fn.id});
    defer std.testing.allocator.free(helper_decl);
    const fn_init_line_pos = std.mem.indexOf(u8, module.text, helper_decl) orelse return error.TestUnexpectedResult;
    const line_start = if (std.mem.lastIndexOfScalar(u8, module.text[0..fn_init_line_pos], '\n')) |pos| pos + 1 else 0;
    const fn_init_line = module.text[line_start..fn_init_line_pos];
    const slot_prefix = "call void @lnako_aot_function_new_generated(ptr @lnako.global.";
    const slot_prefix_pos = std.mem.indexOf(u8, fn_init_line, slot_prefix) orelse return error.TestUnexpectedResult;
    const slot_num_start = slot_prefix_pos + slot_prefix.len;
    const slot_num_end = std.mem.indexOfScalarPos(u8, fn_init_line, slot_num_start, ',') orelse return error.TestUnexpectedResult;
    const helper_slot = fn_init_line[slot_num_start..slot_num_end];
    const forbidden_reg = try std.fmt.allocPrint(std.testing.allocator, "ptr @lnako.global.{s})", .{helper_slot});
    defer std.testing.allocator.free(forbidden_reg);
    const main_start = std.mem.indexOf(u8, module.text, "define i32 @main(") orelse std.mem.indexOf(u8, module.text, "define i32 @wmain(") orelse return error.TestUnexpectedResult;
    const main_text = module.text[main_start..];
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, main_text, search_pos, "call void @lnako_aot_dynamic_global_register(")) |pos| {
        const line_end = std.mem.indexOfScalarPos(u8, main_text, pos, '\n') orelse main_text.len;
        try std.testing.expect(std.mem.indexOf(u8, main_text[pos..line_end], forbidden_reg) == null);
        search_pos = line_end;
    }
    const optimized_text = try compatJsModuleText(std.testing.allocator, "X=1\nJS実行(\"1\")を表示\n", true);
    defer std.testing.allocator.free(optimized_text);
}

test "plugin fallback候補があるときだけAOT候補表とfallback呼出しをemitする" {
    const allocator = std.testing.allocator;
    // 1) ESM exact + unqualified fallback -> @lnako_aot_plugin_fallback_call (default_is_esm=1)
    {
        const source = "A=1\n外部甲(1)を表示\n";
        var parsed = try parser.parse(allocator, source, "main.nako3");
        defer parsed.deinit();
        try std.testing.expect(parsed.succeeded());
        const aliases = [_]semantic.DynamicCommandAlias{
            .{
                .source_namespace = "外部甲",
                .dispatch_namespace = "pkg:multi:a.mjs__外部甲",
                .import_position = 0,
                .exact = true,
            },
            .{
                .source_namespace = "",
                .dispatch_namespace = "pkg:multi:b.mjs",
                .import_position = 1,
                .unqualified = true,
            },
        };
        var analyzed = try semantic.analyzeModules(allocator, &.{.{
            .name = "main",
            .path = "main.nako3",
            .root = parsed.root.?,
            .is_package = true,
            .dynamic_command_aliases = &aliases,
        }});
        defer analyzed.deinit();
        try std.testing.expect(analyzed.succeeded());
        var hir_program = try hir.lower(allocator, &.{parsed.root.?}, &.{"main"}, &.{"main.nako3"}, &.{&.{}}, analyzed);
        defer hir_program.deinit();
        var program = try lower.lower(allocator, hir_program);
        defer program.deinit();
        program.compat_js = true;
        const js_modules = try program.arena.allocator().alloc(ir.JavaScriptModule, 2);
        js_modules[0] = .{
            .path = "a.mjs",
            .source = "export default {};",
            .is_plugin = true,
            .namespaces = &.{"pkg:multi:a.mjs"},
            .package_root = null,
            .bare_aliases = &.{},
        };
        js_modules[1] = .{
            .path = "b.mjs",
            .source = "export default {};",
            .is_plugin = true,
            .namespaces = &.{"pkg:multi:b.mjs"},
            .package_root = null,
            .bare_aliases = &.{},
        };
        program.javascript_modules = js_modules;
        try std.testing.expect(findUnsupported(program) == null);

        var module = try generate(allocator, program, "main.nako3", false);
        defer module.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, module.text, "%lnako.AotPluginCandidate = type { ptr, i64 }\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_plugin_fallback_call(ptr, ptr, i64, ptr, i64, i64, i1)\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.plugin.fallback.0 = private unnamed_addr constant [2 x %lnako.AotPluginCandidate]") != null);
        try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_plugin_fallback_call(ptr %root.slot.") != null);
    }

    // 2) native plugin + fallback -> lnako_aot_plugin_fallback_call と lnako_aot_plugin_function_new_fallback を emit
    {
        const source = "A=1\nF={関数}外部甲\n外部甲(1)を表示\n";
        var parsed = try parser.parse(allocator, source, "main.nako3");
        defer parsed.deinit();
        try std.testing.expect(parsed.succeeded());
        const aliases = [_]semantic.DynamicCommandAlias{
            .{
                .source_namespace = "外部甲",
                .dispatch_namespace = "pkg:multi:a.mjs__外部甲",
                .import_position = 0,
                .exact = true,
            },
            .{
                .source_namespace = "",
                .dispatch_namespace = "pkg:multi:b",
                .import_position = 1,
                .unqualified = true,
            },
        };
        var analyzed = try semantic.analyzeModules(allocator, &.{.{
            .name = "main",
            .path = "main.nako3",
            .root = parsed.root.?,
            .is_package = true,
            .dynamic_command_aliases = &aliases,
        }});
        defer analyzed.deinit();
        try std.testing.expect(analyzed.succeeded());
        var hir_program = try hir.lower(allocator, &.{parsed.root.?}, &.{"main"}, &.{"main.nako3"}, &.{&.{}}, analyzed);
        defer hir_program.deinit();
        var program = try lower.lower(allocator, hir_program);
        defer program.deinit();
        const arena = program.arena.allocator();
        const paths = try arena.alloc([]const u8, 1);
        paths[0] = try arena.dupe(u8, "/tmp/liblnako_pkg_plugin.dylib");
        program.native_plugin_paths = paths;
        const packages = try arena.alloc(ir.NativePluginPackage, 1);
        packages[0] = .{ .path = try arena.dupe(u8, "/tmp/liblnako_pkg_plugin.dylib"), .namespace = "pkg:multi:b" };
        program.native_plugin_packages = packages;
        try std.testing.expect(findUnsupported(program) == null);

        var module = try generate(allocator, program, "main.nako3", false);
        defer module.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_plugin_function_new_fallback(ptr, ptr, i64, i1)\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_plugin_function_new_fallback(ptr %root.slot.") != null);
        try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_plugin_fallback_call(ptr %root.slot.") != null);
    }

    // 3) fallback無しの通常plugin呼出しにはfallback ABIを混入させない
    {
        var parsed = try parser.parse(allocator, "math__外部追加(1, 2)を表示\n", "main.nako3");
        defer parsed.deinit();
        try std.testing.expect(parsed.succeeded());
        const aliases = [_]semantic.DynamicCommandAlias{.{ .source_namespace = "math", .dispatch_namespace = "math" }};
        var analyzed = try semantic.analyzeModules(allocator, &.{.{
            .name = "main",
            .path = "main.nako3",
            .root = parsed.root.?,
            .dynamic_command_aliases = &aliases,
        }});
        defer analyzed.deinit();
        try std.testing.expect(analyzed.succeeded());
        var hir_program = try hir.lower(allocator, &.{parsed.root.?}, &.{"main"}, &.{"main.nako3"}, &.{&.{}}, analyzed);
        defer hir_program.deinit();
        var program = try lower.lower(allocator, hir_program);
        defer program.deinit();
        const arena = program.arena.allocator();
        const paths = try arena.alloc([]const u8, 1);
        paths[0] = try arena.dupe(u8, "/tmp/liblnako_pkg_plugin.dylib");
        program.native_plugin_paths = paths;
        const packages = try arena.alloc(ir.NativePluginPackage, 1);
        packages[0] = .{ .path = try arena.dupe(u8, "/tmp/liblnako_pkg_plugin.dylib"), .namespace = "math" };
        program.native_plugin_packages = packages;

        var module = try generate(allocator, program, "main.nako3", false);
        defer module.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, module.text, "%lnako.AotPluginCandidate") == null);
        try std.testing.expect(std.mem.indexOf(u8, module.text, "lnako_aot_plugin_fallback_call") == null);
        try std.testing.expect(std.mem.indexOf(u8, module.text, "lnako_aot_plugin_function_new_fallback") == null);
    }
}

test "ESM plugin のみの構成でもfallback候補付き関数参照をAOTで受理しfallback関数生成をemitする" {
    const allocator = std.testing.allocator;
    // native plugin を持たない（native_plugin_paths が空）`--compat-js` 専用構成。
    const source = "A=1\nF={関数}外部甲\nF(1)を表示\n";
    var parsed = try parser.parse(allocator, source, "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    const aliases = [_]semantic.DynamicCommandAlias{
        .{
            .source_namespace = "外部甲",
            .dispatch_namespace = "pkg:multi:a.mjs__外部甲",
            .import_position = 0,
            .exact = true,
        },
        .{
            .source_namespace = "",
            .dispatch_namespace = "pkg:multi:b.mjs",
            .import_position = 1,
            .unqualified = true,
        },
    };
    var analyzed = try semantic.analyzeModules(allocator, &.{.{
        .name = "main",
        .path = "main.nako3",
        .root = parsed.root.?,
        .is_package = true,
        .dynamic_command_aliases = &aliases,
    }});
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lower(allocator, &.{parsed.root.?}, &.{"main"}, &.{"main.nako3"}, &.{&.{}}, analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(allocator, hir_program);
    defer program.deinit();
    program.compat_js = true;
    const js_modules = try program.arena.allocator().alloc(ir.JavaScriptModule, 2);
    js_modules[0] = .{ .path = "a.mjs", .source = "export default {};", .is_plugin = true, .namespaces = &.{"pkg:multi:a.mjs"}, .package_root = null, .bare_aliases = &.{} };
    js_modules[1] = .{ .path = "b.mjs", .source = "export default {};", .is_plugin = true, .namespaces = &.{"pkg:multi:b.mjs"}, .package_root = null, .bare_aliases = &.{} };
    program.javascript_modules = js_modules;
    try std.testing.expectEqual(@as(usize, 0), program.native_plugin_paths.len);
    // 関数参照がAOT未対応として拒否されない。
    try std.testing.expect(findUnsupported(program) == null);

    var module = try generate(allocator, program, "main.nako3", false);
    defer module.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_plugin_function_new_fallback(ptr %root.slot.") != null);
    // ESM が主配送先なので default_is_esm=1 で候補表を渡す。
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.plugin.fallback.0 = private unnamed_addr constant [2 x %lnako.AotPluginCandidate]") != null);
}

test "fallback候補付き関数参照は直後に保留例外を確認し試す節のcatchへ分岐する" {
    const allocator = std.testing.allocator;
    const source = "エラー監視\n  F={関数}外部甲\nエラーならば\n  「捕捉」を表示\nここまで\n";
    var parsed = try parser.parse(allocator, source, "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    const aliases = [_]semantic.DynamicCommandAlias{
        .{ .source_namespace = "外部甲", .dispatch_namespace = "pkg:multi:a.mjs__外部甲", .import_position = 0, .exact = true },
        .{ .source_namespace = "", .dispatch_namespace = "pkg:multi:b.mjs", .import_position = 1, .unqualified = true },
    };
    var analyzed = try semantic.analyzeModules(allocator, &.{.{
        .name = "main",
        .path = "main.nako3",
        .root = parsed.root.?,
        .is_package = true,
        .dynamic_command_aliases = &aliases,
    }});
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lower(allocator, &.{parsed.root.?}, &.{"main"}, &.{"main.nako3"}, &.{&.{}}, analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(allocator, hir_program);
    defer program.deinit();
    program.compat_js = true;
    const js_modules = try program.arena.allocator().alloc(ir.JavaScriptModule, 2);
    js_modules[0] = .{ .path = "a.mjs", .source = "export default {};", .is_plugin = true, .namespaces = &.{"pkg:multi:a.mjs"}, .package_root = null, .bare_aliases = &.{} };
    js_modules[1] = .{ .path = "b.mjs", .source = "export default {};", .is_plugin = true, .namespaces = &.{"pkg:multi:b.mjs"}, .package_root = null, .bare_aliases = &.{} };
    program.javascript_modules = js_modules;

    // IR: make_closure 直後に exception_pending があり、条件分岐で終わる。
    var saw_checked = false;
    for (program.functions) |function| for (function.blocks) |block| for (block.instructions, 0..) |instruction, index| {
        if (instruction.opcode != .make_closure or instruction.fallback_names.len == 0) continue;
        try std.testing.expect(index + 1 < block.instructions.len);
        try std.testing.expectEqual(ir.Opcode.exception_pending, block.instructions[index + 1].opcode);
        try std.testing.expect(block.terminator == .conditional_branch);
        saw_checked = true;
    };
    try std.testing.expect(saw_checked);

    var module = try generate(allocator, program, "main.nako3", false);
    defer module.deinit(allocator);
    // emit 結果でも fallback 関数生成の後に保留例外の確認が残る（dead-store 解析で除去されない）。
    const call_at = std.mem.indexOf(u8, module.text, "call void @lnako_aot_plugin_function_new_fallback(ptr %root.slot.") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, module.text[call_at..], "call i32 @lnako_aot_exception_pending()") != null);
}
