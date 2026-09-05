const std = @import("std");
const target_builtin = @import("builtin");
const ir = @import("../../ir/nako_ir.zig");
const ast = @import("../../frontend/ast.zig");
const aot_builtin = @import("../../runtime/aot_builtin.zig");
const shared = @import("module/shared.zig");

const emitter_mod = @import("module/emitter.zig");

pub const Emitter = emitter_mod.Emitter;

pub const GeneratedModule = struct {
    text: []u8,

    pub fn deinit(self: *GeneratedModule, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

const manifest_mod = @import("module/manifest.zig");
const unsupported_mod = @import("module/unsupported.zig");

pub const ManifestCall = manifest_mod.ManifestCall;
pub const manifestCall = manifest_mod.manifestCall;
pub const writeBuiltinManifest = manifest_mod.writeBuiltinManifest;
pub const completeBuiltinManifest = manifest_mod.completeBuiltinManifest;
pub const writeGlobalManifest = manifest_mod.writeGlobalManifest;
pub const completeGlobalManifest = manifest_mod.completeGlobalManifest;
pub const writeLiteralManifest = manifest_mod.writeLiteralManifest;
pub const completeLiteralManifest = manifest_mod.completeLiteralManifest;
pub const UnsupportedFeature = unsupported_mod.UnsupportedFeature;
pub const findUnsupported = unsupported_mod.findUnsupported;

pub fn generate(allocator: std.mem.Allocator, program: ir.Program, source_path: []const u8, optimized: bool) !GeneratedModule {
    var emitter = Emitter{
        .allocator = allocator,
        .program = program,
        .source_path = source_path,
        .optimized = optimized,
        .output = .init(allocator),
    };
    defer emitter.deinit();
    try emitter_mod.run(&emitter);
    return .{ .text = try emitter.output.toOwnedSlice() };
}

test "Nako SSA IRをデバッグ情報付きLLVM IRへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "A=1\nB=A+2\nBを表示\nコマンドラインを表示\n母艦パスを表示\n母艦パス取得()を表示\nデバッグ表示({\"a\":1})\nフォルダ作成(\"data\")\n圧縮(\"source.txt\",\"archive.zip\")を表示\n起動待機(\"printf process\")を表示\nF=関数(P)それはP;ここまで\nFでファイル処理時\nファイル処理強制停止\nAJAXテキスト取得(\"http://127.0.0.1/\")を表示\n__DEBUG_BP_WAIT(12)を表示\n", "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "main.nako3", false);
    defer module.deinit(std.testing.allocator);
    const expected_entry = if (target_builtin.os.tag == .windows)
        "define i32 @wmain(i32 %argc, ptr %argv)"
    else
        "define i32 @main(i32 %argc, ptr %argv)";
    try std.testing.expect(std.mem.indexOf(u8, module.text, expected_entry) != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call i32 @lnako_aot_runtime_init()") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_runtime_drain_events()\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_runtime_drain_events()\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_timer_call_site(ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_promise_call_site(ptr, ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_file_operation_call(ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_file_operation_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_archive_call(ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_archive_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_process_call(ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_node_process_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_file_callback_call(ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_node_file_callback_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_http_call(ptr, ptr, ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_node_http_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_constants_init(ptr, ptr, ptr, i32, ptr)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_constants_init_wide(ptr, ptr, ptr, i32, ptr)\n") != null);
    const expected_constants_initializer = if (target_builtin.os.tag == .windows)
        "call void @lnako_aot_node_constants_init_wide(ptr "
    else
        "call void @lnako_aot_node_constants_init(ptr ";
    try std.testing.expect(std.mem.indexOf(u8, module.text, expected_constants_initializer) != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_directory_constants_init(ptr, ptr, ptr)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_mother_path_init(ptr, ptr, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.node.source.path") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_node_mother_path_init(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_runtime_deinit()") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.global.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "!llvm.dbg.cu") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "!DILocation(line: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_builtin_call_site") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_dispatch_display_begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare i64 @lnako_aot_dispatch_display_begin_with_epoch(i64, ptr)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_dispatch_result(i64, i64, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_dispatch_result(i64 %display.call_id, i64 %site_id, i64 %display.start_epoch)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_debug_display(ptr, ptr, i64, ptr, i64, ptr, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_debug_breakpoint_wait_call(ptr, ptr, ptr, ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_debug_breakpoint_wait_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.debug.path.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_debug_display") != null);
}

test "ネイティブプラグイン命令をAOT ABIへ出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "外部追加(1)を表示\n", "native-plugin.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyzeModules(std.testing.allocator, &.{.{
        .name = "native-plugin",
        .path = "native-plugin.nako3",
        .root = parsed.root.?,
        .allows_dynamic_commands = true,
    }});
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lower(std.testing.allocator, &.{parsed.root.?}, &.{"native-plugin"}, &.{"native-plugin.nako3"}, analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const path_allocator = program.arena.allocator();
    const paths = try path_allocator.alloc([]const u8, 1);
    paths[0] = try path_allocator.dupe(u8, "/tmp/liblnako_test_plugin.dylib");
    program.native_plugin_paths = paths;

    var native_call_found = false;
    for (program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .call or !std.mem.eql(u8, instruction.name, "外部追加")) continue;
        native_call_found = true;
        try std.testing.expect(!instruction.is_builtin_call);
        try std.testing.expect(instruction.direct_callee == null);
        try std.testing.expect(instruction.site_id == null);
    };
    try std.testing.expect(native_call_found);
    try std.testing.expect(findUnsupported(program) == null);

    var module = try generate(std.testing.allocator, program, "native-plugin.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_native_plugin_register(ptr, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_native_plugin_call(ptr, ptr, i64, ptr, i64, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.native.plugin.name.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.native.plugin.path.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_native_plugin_register(ptr @lnako.native.plugin.path.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_native_plugin_call(ptr %root.slot.") != null);
}

test "AOT builtin manifestはdispatch routeとcanonical opcodeを保持する" {
    const display = manifestCall("表示", null, true).?;
    try std.testing.expectEqualStrings("表示", display.source_name);
    try std.testing.expectEqualStrings("display", display.canonical_opcode);
    try std.testing.expectEqualStrings("direct-display", display.route);
    try std.testing.expectEqual(@as(u16, 0), display.opcode);

    const cut = manifestCall("切取", null, true).?;
    try std.testing.expectEqualStrings("cut", cut.canonical_opcode);
    try std.testing.expectEqualStrings("cut", cut.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.cut), cut.opcode);

    const regexp = manifestCall("正規表現マッチ", null, true).?;
    try std.testing.expectEqualStrings("regexp_match", regexp.canonical_opcode);
    try std.testing.expectEqualStrings("regexp", regexp.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.regexp_match), regexp.opcode);

    const builtin = manifestCall("文字列変換", null, true).?;
    try std.testing.expectEqualStrings("to_string", builtin.canonical_opcode);
    try std.testing.expectEqualStrings("builtin", builtin.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.to_string), builtin.opcode);

    const debug = manifestCall("デバッグ表示", null, true).?;
    try std.testing.expectEqualStrings("system_debug_display", debug.canonical_opcode);
    try std.testing.expectEqualStrings("debug-display", debug.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_debug_display), debug.opcode);

    const hatena = manifestCall("ハテナ関数実行", null, true).?;
    try std.testing.expectEqualStrings("system_hatena_execute", hatena.canonical_opcode);
    try std.testing.expectEqualStrings("hatena-default", hatena.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_hatena_execute), hatena.opcode);

    const hatena_configure = manifestCall("ハテナ関数設定", null, true).?;
    try std.testing.expectEqualStrings("system_hatena_configure", hatena_configure.canonical_opcode);
    try std.testing.expectEqualStrings("hatena-configure", hatena_configure.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_hatena_configure), hatena_configure.opcode);

    const node_interrupt = manifestCall("強制終了時", null, true).?;
    try std.testing.expectEqualStrings("node_interrupt_callback", node_interrupt.canonical_opcode);
    try std.testing.expectEqualStrings("node-interrupt", node_interrupt.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_interrupt_callback), node_interrupt.opcode);

    const breakpoint_wait = manifestCall("__DEBUG_BP_WAIT", null, true).?;
    try std.testing.expectEqualStrings("system_debug_breakpoint_wait", breakpoint_wait.canonical_opcode);
    try std.testing.expectEqualStrings("debug-breakpoint-wait", breakpoint_wait.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_debug_breakpoint_wait), breakpoint_wait.opcode);

    const stdin_line = manifestCall("尋", null, true).?;
    try std.testing.expectEqualStrings("node_stdin_line", stdin_line.canonical_opcode);
    try std.testing.expectEqualStrings("node-stdin-lines", stdin_line.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_stdin_line), stdin_line.opcode);

    const archive_tool_path = manifestCall("圧縮解凍ツールパス変更", null, true).?;
    try std.testing.expectEqualStrings("node_archive_tool_path_set", archive_tool_path.canonical_opcode);
    try std.testing.expectEqualStrings("archive-tool-path", archive_tool_path.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_archive_tool_path_set), archive_tool_path.opcode);

    const archive_create = manifestCall("圧縮", null, true).?;
    try std.testing.expectEqualStrings("node_archive_create", archive_create.canonical_opcode);
    try std.testing.expectEqualStrings("node-archive", archive_create.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_archive_create), archive_create.opcode);

    const archive_extract_callback = manifestCall("解凍時", null, true).?;
    try std.testing.expectEqualStrings("node_archive_extract_callback", archive_extract_callback.canonical_opcode);
    try std.testing.expectEqualStrings("node-archive", archive_extract_callback.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_archive_extract_callback), archive_extract_callback.opcode);

    const process_wait = manifestCall("起動待機", null, true).?;
    try std.testing.expectEqualStrings("node_process_run_wait", process_wait.canonical_opcode);
    try std.testing.expectEqualStrings("node-process", process_wait.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_process_run_wait), process_wait.opcode);

    const process_start = manifestCall("起動", null, true).?;
    try std.testing.expectEqualStrings("node_process_start", process_start.canonical_opcode);
    try std.testing.expectEqualStrings("node-process", process_start.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_process_start), process_start.opcode);

    const file_callback = manifestCall("ファイルコピー時", null, true).?;
    try std.testing.expectEqualStrings("node_file_copy_callback", file_callback.canonical_opcode);
    try std.testing.expectEqualStrings("node-file-callback", file_callback.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_file_copy_callback), file_callback.opcode);

    const ajax_options = manifestCall("AJAXオプション設定", null, true).?;
    try std.testing.expectEqualStrings("node_ajax_options_set", ajax_options.canonical_opcode);
    try std.testing.expectEqualStrings("ajax-options", ajax_options.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_ajax_options_set), ajax_options.opcode);

    const ajax_onerror = manifestCall("AJAX失敗時", null, true).?;
    try std.testing.expectEqualStrings("node_ajax_onerror_set", ajax_onerror.canonical_opcode);
    try std.testing.expectEqualStrings("ajax-onerror", ajax_onerror.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_ajax_onerror_set), ajax_onerror.opcode);

    const ajax_http = manifestCall("AJAXテキスト取得", null, true).?;
    try std.testing.expectEqualStrings("node_ajax_text_get", ajax_http.canonical_opcode);
    try std.testing.expectEqualStrings("node-http", ajax_http.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_ajax_text_get), ajax_http.opcode);

    const file_open = manifestCall("開", null, true).?;
    try std.testing.expectEqualStrings("node_file_open", file_open.canonical_opcode);
    try std.testing.expectEqualStrings("node-file-io", file_open.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_file_open), file_open.opcode);

    const sjis_file = manifestCall("SJISファイル読", null, true).?;
    try std.testing.expectEqualStrings("node_file_sjis_read", sjis_file.canonical_opcode);
    try std.testing.expectEqualStrings("node-file-encoding", sjis_file.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_file_sjis_read), sjis_file.opcode);

    const sjis = manifestCall("SJIS変換", null, true).?;
    try std.testing.expectEqualStrings("node_encoding_sjis_encode", sjis.canonical_opcode);
    try std.testing.expectEqualStrings("node-encoding", sjis.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_encoding_sjis_encode), sjis.opcode);

    const file_list = manifestCall("ファイル列挙", null, true).?;
    try std.testing.expectEqualStrings("node_file_list", file_list.canonical_opcode);
    try std.testing.expectEqualStrings("node-file-operation", file_list.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_file_list), file_list.opcode);

    const file_copy = manifestCall("ファイル上書コピー", null, true).?;
    try std.testing.expectEqualStrings("node_file_copy_overwrite", file_copy.canonical_opcode);
    try std.testing.expectEqualStrings("node-file-operation", file_copy.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_file_copy_overwrite), file_copy.opcode);

    const timer_wait = manifestCall("秒待", null, true).?;
    try std.testing.expectEqualStrings("timer_wait", timer_wait.canonical_opcode);
    try std.testing.expectEqualStrings("builtin", timer_wait.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.timer_wait), timer_wait.opcode);

    const timer = manifestCall("秒後", null, true).?;
    try std.testing.expectEqualStrings("timer_after", timer.canonical_opcode);
    try std.testing.expectEqualStrings("timer", timer.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.timer_after), timer.opcode);

    const promise = manifestCall("成功時", null, true).?;
    try std.testing.expectEqualStrings("promise_success", promise.canonical_opcode);
    try std.testing.expectEqualStrings("promise", promise.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.promise_success), promise.opcode);

    const dynamic = manifestCall("ナデシコ", null, true).?;
    try std.testing.expectEqualStrings("system_nadesiko", dynamic.canonical_opcode);
    try std.testing.expectEqualStrings("dynamic-execute", dynamic.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_nadesiko), dynamic.opcode);

    const dynamic_continue = manifestCall("ナデシコ続", null, true).?;
    try std.testing.expectEqualStrings("system_nadesiko_continue", dynamic_continue.canonical_opcode);
    try std.testing.expectEqualStrings("dynamic-execute", dynamic_continue.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_nadesiko_continue), dynamic_continue.opcode);

    try std.testing.expect(manifestCall("利用者関数", 0, false) == null);
    try std.testing.expect(manifestCall("未知命令", null, false) == null);
}

test "AOT throw terminatorは専用dispatch trace ABIを出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "エラー監視\n1のエラー発生\nエラーならば\n\"handled\"を表示\nここまで\n", "throw-dispatch.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "throw-dispatch.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "throw-dispatch.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "throw-dispatch.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_throw_site(i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_throw_site(i64 ") != null);
}

test "site-aware builtin emissionはsite ID欠落を拒否する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "1を表示\n", "missing-site.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "missing-site.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "missing-site", "missing-site.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var found_builtin = false;
    for (program.functions) |*function| for (function.blocks) |*block| for (block.instructions) |*instruction| {
        if (instruction.opcode == .call and instruction.is_builtin_call) {
            instruction.site_id = null;
            found_builtin = true;
            break;
        }
    };
    try std.testing.expect(found_builtin);
    try std.testing.expectError(error.MissingDispatchSiteId, generate(std.testing.allocator, program, "missing-site.nako3", false));
}

test "global loadを専用AOT trace ABIへ出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "PIを表示\n", "global-trace.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "global-trace.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "global-trace.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "global-trace.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_global_read_site(i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_global_read_site(i64 1)") != null);
}

test "global storeを専用AOT trace ABIへ出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const source = "ファイルコピーデフォルト動作を表示\nファイルコピーデフォルト動作=\"上書\"\n";
    var parsed = try parser.parse(std.testing.allocator, source, "global-store-trace.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "global-store-trace.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "global-store-trace.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "global-store-trace.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_global_write_site(i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_global_write_site(i64 2)") != null);
}

test "catalog literalを専用AOT trace ABIへ出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "真を表示\nNULLを表示\n", "literal-trace.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "literal-trace.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "literal-trace.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "literal-trace.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_literal_site(i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_literal_site(i64 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_literal_site(i64 2)") != null);
}

test "参照されたスカラーシステム定数をAOTグローバルへ初期化する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "trueを表示\nfalseを表示\nPIを表示\n非数を表示\n無限大を表示\n未定義を表示\n", "constants.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "constants.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "constants.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "constants.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "internal global %lnako.Value { i8 2, i64 1 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "internal global %lnako.Value { i8 2, i64 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "internal global %lnako.Value { i8 3, i64 4614256656552045848 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "internal global %lnako.Value { i8 0, i64 0 }") != null);
}

test "参照された文字列システム定数をGCルート登録後に初期化する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "ナデシコバージョンを表示\n改行を表示\n空を表示\n名前空間を表示\n", "string-constants.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "string-constants.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "string-constants.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "string-constants.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.system.string.") != null);
    const push = std.mem.indexOf(u8, module.text, "call void @lnako_aot_push_roots").?;
    const initialize = std.mem.indexOf(u8, module.text, "call void @lnako_aot_string_new(ptr @lnako.global.").?;
    const entry = std.mem.indexOf(u8, module.text, "%entry.result.0 = call").?;
    try std.testing.expect(push < initialize);
    try std.testing.expect(initialize < entry);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "[4 x i16] [i16 109, i16 97, i16 105, i16 110]") != null);
}

test "プラグイン管理命令を専用AOT ABIへ出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "プラグイン名設定(123)\n名前空間設定(456)\n名前空間ポップ()\n", "plugin-management.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "plugin-management.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "plugin-management.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "plugin-management.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_plugin_management_call(ptr, ptr, i64, i16, ptr, ptr, i64)\n") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, module.text, "call void @lnako_aot_plugin_management_call("));
    try std.testing.expect(std.mem.indexOf(u8, module.text, "ptr @lnako.global.1, ptr @lnako.global.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "[4 x i16] [i16 109, i16 97, i16 105, i16 110]") != null);
}

test "参照された配列システム定数を独立したGCオブジェクトへ初期化する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "抽出文字列[0]=\"A\"\n__DEBUGブレイクポイント一覧[0]=\"B\"\n抽出文字列を表示\n__DEBUGブレイクポイント一覧を表示\n", "array-constants.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "array-constants.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "array-constants.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "array-constants.nako3", false);
    defer module.deinit(std.testing.allocator);
    const first = std.mem.indexOf(u8, module.text, "call void @lnako_aot_array_new(ptr @lnako.global.").?;
    const second = std.mem.indexOfPos(u8, module.text, first + 1, "call void @lnako_aot_array_new(ptr @lnako.global.").?;
    const entry = std.mem.indexOf(u8, module.text, "%entry.result.0 = call").?;
    try std.testing.expect(first < second);
    try std.testing.expect(second < entry);
}

test "参照された辞書システム定数を専用AOT初期化子へ渡す" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "JSON変換(ブラウザ名変換表)を表示\n", "dictionary-constants.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "dictionary-constants.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "dictionary-constants.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "dictionary-constants.nako3", false);
    defer module.deinit(std.testing.allocator);
    const initialize = std.mem.indexOf(u8, module.text, "call void @lnako_aot_caniuse_agents_new(ptr @lnako.global.").?;
    const entry = std.mem.indexOf(u8, module.text, "%entry.result.0 = call").?;
    try std.testing.expect(initialize < entry);
}

test "参照された元号データを専用AOT初期化子へ渡す" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "JSON変換(元号データ)を表示\n", "era-data.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "era-data.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "era-data.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "era-data.nako3", false);
    defer module.deinit(std.testing.allocator);
    const initialize = std.mem.indexOf(u8, module.text, "call void @lnako_aot_era_data_new(ptr @lnako.global.").?;
    const entry = std.mem.indexOf(u8, module.text, "%entry.result.0 = call").?;
    try std.testing.expect(initialize < entry);
}

test "正規表現マッチは未参照の抽出文字列もAOTグローバルへ確保する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "正規表現マッチ(\"a\",『/(a)/』)\n", "regexp-global.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "regexp-global.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "regexp_global", "regexp-global.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "regexp-global.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_array_new(ptr @lnako.global.") != null);
    const call = std.mem.indexOf(u8, module.text, "call void @lnako_aot_regexp_call_site").?;
    const capture_pointer = std.mem.indexOfPos(u8, module.text, call, "ptr @lnako.global.").?;
    const call_end = std.mem.indexOfPos(u8, module.text, call, "\n").?;
    try std.testing.expect(capture_pointer < call_end);
}

test "配列と辞書をルート付きAOTランタイム呼び出しへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const source = "A=[1,2]\nA[1]=5\nA[1]を表示\nAを表示\nB={\"x\":7}\nB@\"x\"を表示\nBを表示\nX=[8,9]\n変数[C,D]=X\nCを表示\n変数[E,F]=7\nEを表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "collections.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "collections.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "collections.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "collections.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_push_roots") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_pop_roots") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_array_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_dictionary_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_index_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_index_set") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_destructure_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_print_collection") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_index_get(ptr, ptr, ptr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "ptr %runtime.scratch") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare %lnako.Value @lnako_aot_") == null);
}

test "回数・範囲・コレクション反復をAOTイテレーターへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const source = "C=2\nC回\n回数を表示\nここまで\nNを1から2まで繰り返す\nNを表示\nここまで\nA=[3,4]\nAを反復\n対象を表示\nここまで\nS=\"AB\"\nSを反復\n対象を表示\nここまで\n";
    var parsed = try parser.parse(std.testing.allocator, source, "iterators.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "iterators.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "iterators.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "iterators.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_iterator_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_iterator_has_next") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_iterator_next") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "ptr @lnako.global.") != null);
}

test "UTF-16文字列定数と添字と反復をAOTランタイムへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "S=「A😀B」\nS[1]を表示\n「A😀B」を反復\n対象を表示\nここまで\nN=「A\x00B」\nNを表示\n", "string-iterator.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "string-iterator.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "string-iterator.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "string-iterator.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_string_new(ptr, ptr, i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_print_utf16(ptr, i1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "[4 x i16] [i16 65, i16 55357, i16 56832, i16 66]") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "[3 x i16] [i16 65, i16 0, i16 66]") != null);
}

test "BigInt定数と真偽判定をAOTランタイムへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "123456789012345678901234567890nを表示\nもし0nならば\n『誤』を表示\n違えば\n『正』を表示\nここまで\n", "bigint.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "bigint.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "bigint.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "bigint.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_bigint_new(ptr, ptr, i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_print_bigint(ptr, i1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare i32 @lnako_aot_bigint_truthy(ptr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.bigint.") != null);
}

test "動的算術とBigInt比較をAOTランタイムへ接続する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "A=12345678901234567890n\nB=10n\nA+Bを表示\nA>Bを表示\nA==\"12345678901234567890\"を表示\nA&\"個\"を表示\n8n<<2nを表示\n", "bigint-operators.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "bigint-operators.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "bigint-operators.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "bigint-operators.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_arithmetic") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_compare") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_shift") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_concat") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "binary.has.bigint.") == null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_display_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@.lnako.fmt.number") == null);
}

test "増減文をNumber変換付きAOTランタイムへ接続する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "Aを1増\nAを表示\nB=\"5\"\nBを2増\nBを表示\n", "increment.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "increment.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "increment.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "increment.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_increment") != null);
}

test "関数戻り値をシステム変数それへ書き戻す" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const source = "●七とは\n7で戻る\nここまで\n●空とは\nここまで\n七()\nA=それ\n空()\nB=それ\n";
    var parsed = try parser.parse(std.testing.allocator, source, "result.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "result.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "result", "result.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "result.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "store %lnako.Value %v") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "ret %lnako.Value { i8 0, i64 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.global.0") != null);
}

test "非捕捉無名関数を統一ABIの関数値へ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const source = "F=関数(A)それはA+1;ここまで\nF(3)を表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "function-value.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "function-value.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "function_value", "function-value.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "function-value.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_function_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_function_new_named") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.function.name.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_function_new_named") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_function_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.wrapper.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "define internal void @lnako.wrapper.0(ptr %result.out") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "store %lnako.Value %wrapper.result, ptr %result.out") != null);
}

test "監視外のthrowを保留例外としてmainまで伝播する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "『未捕捉』のエラー発生\n", "uncaught.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "uncaught.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "uncaught", "uncaught.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "uncaught.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_exception_set_error_message") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_exception_abort") != null);
}

test "O1では証明済み数値と真偽判定をアンボックスしO0のIRを変更しない" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const optimizer = @import("../../ir/optimizer.zig");
    const source = "●(Aを)Fとは\nB=A+1\nもしAならば\nBで戻る\n違えば\n0で戻る\nここまで\nここまで\nX=F(2)\nXを表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "optimized.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "optimized.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "optimized.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var optimized_program = try program.clone(std.testing.allocator);
    defer optimized_program.deinit();

    _ = try optimizer.optimize(std.testing.allocator, &optimized_program, .{});
    try std.testing.expectEqual(ir.Type.dynamic, program.findFunction("optimized__F").?.parameters[0].type);
    try std.testing.expectEqual(ir.Type.number, optimized_program.findFunction("optimized__F").?.parameters[0].type);

    var unoptimized_module = try generate(std.testing.allocator, program, "optimized.nako3", false);
    defer unoptimized_module.deinit(std.testing.allocator);
    var optimized_module = try generate(std.testing.allocator, optimized_program, "optimized.nako3", true);
    defer optimized_module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, unoptimized_module.text, "call void @lnako_aot_arithmetic") != null);
    try std.testing.expect(std.mem.indexOf(u8, unoptimized_module.text, "call i1 @lnako.truthy") != null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, "call double @lnako.to_number") == null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, "call void @lnako_aot_arithmetic") == null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, "call i1 @lnako.truthy") == null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, ".bits = extractvalue %lnako.Value") != null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, ".number = bitcast i64") != null);
}
