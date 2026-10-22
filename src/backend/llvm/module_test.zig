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
