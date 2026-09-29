const std = @import("std");
const module_mod = @import("module.zig");
const ir = @import("../../ir/nako_ir.zig");
const parser = @import("../../frontend/parser.zig");
const semantic = @import("../../semantic/analyzer.zig");
const hir = @import("../../ir/hir.zig");
const lower = @import("../../ir/lower_ssa.zig");

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
