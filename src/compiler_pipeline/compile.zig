const std = @import("std");
const lnako = @import("lnako");

pub fn compileInput(allocator: std.mem.Allocator, io: std.Io, path: []const u8, compat_js: bool, stderr: *std.Io.Writer) !?lnako.ir.nako_ir.Program {
    var file_provider = lnako.semantic.module_graph.FileProvider{ .io = io };
    return compileInputWithProvider(allocator, path, compat_js, stderr, file_provider.sourceProvider());
}

pub fn compileInputWithProvider(allocator: std.mem.Allocator, path: []const u8, compat_js: bool, stderr: *std.Io.Writer, source_provider: lnako.semantic.module_graph.SourceProvider) !?lnako.ir.nako_ir.Program {
    var graph = lnako.semantic.module_graph.load(allocator, path, source_provider, .{ .compat_js = compat_js }) catch |err| {
        try stderr.print("{s}: 読み込みまたは字句解析に失敗しました: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    defer graph.deinit();
    if (!graph.succeeded()) {
        for (graph.diagnostics) |item| try item.render(sourceForDiagnostic(graph, item.file), stderr);
        for (graph.modules) |module| if (module.parsed) |parsed| {
            for (parsed.diagnostics) |item| try item.render(module.source, stderr);
        };
        return null;
    }
    // 公式処理系がlogger.errorを記録しつつ継続する廃止構文を、成功結果の
    // 前に表示する。ParseResult.succeeded()はこの診断だけを非致命として扱う。
    for (graph.modules) |module| if (module.parsed) |parsed| {
        for (parsed.diagnostics) |item| try item.render(module.source, stderr);
    };
    var program = try graph.analyze(allocator);
    defer program.deinit();
    if (!program.succeeded()) {
        for (program.diagnostics) |item| try item.render(sourceForDiagnostic(graph, item.file), stderr);
        return null;
    }
    var roots: std.ArrayList(*lnako.frontend.ast.Node) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    for (graph.modules) |module| {
        if (module.kind != .nako3) continue;
        try roots.append(allocator, module.parsed.?.root.?);
        try names.append(allocator, module.name);
        try paths.append(allocator, module.path);
    }
    var hir_program = try lnako.ir.hir.lower(allocator, roots.items, names.items, paths.items, program);
    defer hir_program.deinit();
    var ir_program = try lnako.ir.lower_ssa.lower(allocator, hir_program);
    errdefer ir_program.deinit();
    ir_program.compat_js = compat_js;
    var javascript_modules: std.ArrayList(lnako.ir.nako_ir.JavaScriptModule) = .empty;
    var http_server_plugin_imported = false;
    const plugin_modules = try allocator.alloc(bool, graph.modules.len);
    defer allocator.free(plugin_modules);
    @memset(plugin_modules, false);
    for (graph.modules) |module| {
        if (module.kind != .nako3) continue;
        for (module.imports) |item| if (item.target) |target| {
            if (graph.modules[target].kind == .javascript) plugin_modules[target] = true;
        };
    }
    for (graph.modules) |module| {
        if (module.kind != .javascript) continue;
        const basename = std.fs.path.basename(module.path);
        if (std.ascii.eqlIgnoreCase(basename, "plugin_httpserver.mjs") or std.ascii.eqlIgnoreCase(basename, "plugin_httpserver.js")) {
            http_server_plugin_imported = true;
        }
        if (module.source.len == 0) continue;
        try javascript_modules.append(ir_program.arena.allocator(), .{
            .path = try ir_program.arena.allocator().dupe(u8, module.path),
            .source = try ir_program.arena.allocator().dupe(u8, module.source),
            .is_plugin = plugin_modules[module.index],
        });
    }
    ir_program.javascript_modules = try javascript_modules.toOwnedSlice(ir_program.arena.allocator());
    ir_program.http_server_plugin_imported = http_server_plugin_imported;
    var native_plugin_paths: std.ArrayList([]const u8) = .empty;
    for (graph.modules) |module| {
        if (module.kind != .native_plugin) continue;
        try native_plugin_paths.append(ir_program.arena.allocator(), try ir_program.arena.allocator().dupe(u8, module.path));
    }
    ir_program.native_plugin_paths = try native_plugin_paths.toOwnedSlice(ir_program.arena.allocator());
    var verification = try lnako.ir.verifier.verify(allocator, ir_program);
    defer verification.deinit();
    if (!verification.succeeded()) {
        for (verification.issues) |issue| try stderr.print("IR検証エラー[{s}] {s}: {s}\n", .{ @tagName(issue.code), issue.function_name, issue.message });
        ir_program.deinit();
        return null;
    }
    return ir_program;
}

fn sourceForDiagnostic(graph: lnako.semantic.module_graph.ModuleGraph, file: []const u8) []const u8 {
    for (graph.modules) |module| if (std.mem.eql(u8, module.path, file)) return module.source;
    return "";
}
