const std = @import("std");
const lnako = @import("lnako");

/// 入力コンパイルのオプション。`forced_mode` は .dncl/.dncl2 拡張子や
/// --dncl/--dncl2 フラグで強制される構文モード。
const InvalidPackageEnvironment = struct {
    fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!lnako.semantic.module_graph.ResolvedPackageImport {
        return error.InvalidPackageEnvironment;
    }
};

pub const InputOptions = struct {
    compat_js: bool = false,
    forced_mode: lnako.frontend.token.Mode = .{},
    /// Optional explicit package resolver. CLI compilation loads the verified
    /// `.nako/environment.json` automatically when this is null.
    package_resolver: ?lnako.semantic.module_graph.PackageResolver = null,
};

pub fn compileInput(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: InputOptions, stderr: *std.Io.Writer) !?lnako.ir.nako_ir.Program {
    return compileInputTraced(allocator, io, path, options, stderr, false);
}

pub fn compileInputTraced(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: InputOptions, stderr: *std.Io.Writer, trace: bool) !?lnako.ir.nako_ir.Program {
    var file_provider = lnako.semantic.module_graph.FileProvider{ .io = io };
    var package_environment: ?lnako.package.import_resolver.Resolver = null;
    defer if (package_environment) |*environment| environment.deinit();
    var package_root: ?[]u8 = null;
    defer if (package_root) |root| allocator.free(root);
    var effective_options = options;
    var invalid_package_environment = InvalidPackageEnvironment{};
    if (effective_options.package_resolver == null) {
        package_root = lnako.package.import_resolver.findProjectRoot(allocator, io, path) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            break :blk null;
        };
        if (package_root) |root| {
            package_environment = lnako.package.import_resolver.Resolver.load(allocator, io, root) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            if (package_environment) |*environment| {
                effective_options.package_resolver = environment.packageResolver();
            } else {
                // A stale/broken environment must not prevent unrelated source
                // imports from compiling. Package specifiers still fail closed.
                effective_options.package_resolver = .{ .context = &invalid_package_environment, .resolveFn = InvalidPackageEnvironment.resolve };
            }
        }
    }
    var timer = FrontendTimer{ .io = io, .last = if (trace) std.Io.Timestamp.now(io, .awake).nanoseconds else 0 };
    return compileInputWithProviderTimed(allocator, path, effective_options, stderr, file_provider.sourceProvider(), if (trace) &timer else null);
}

pub fn compileInputWithProvider(allocator: std.mem.Allocator, path: []const u8, options: InputOptions, stderr: *std.Io.Writer, source_provider: lnako.semantic.module_graph.SourceProvider) !?lnako.ir.nako_ir.Program {
    return compileInputWithProviderTimed(allocator, path, options, stderr, source_provider, null);
}

fn compileInputWithProviderTimed(allocator: std.mem.Allocator, path: []const u8, options: InputOptions, stderr: *std.Io.Writer, source_provider: lnako.semantic.module_graph.SourceProvider, timer: ?*FrontendTimer) !?lnako.ir.nako_ir.Program {
    var graph = lnako.semantic.module_graph.load(allocator, path, source_provider, .{ .compat_js = options.compat_js, .forced_mode = options.forced_mode, .package_resolver = options.package_resolver }) catch |err| {
        // 拡張子と--dncl/--dncl2の方言競合はusageエラーとしてCLI層へ伝搬する。
        if (err == error.ConflictingDnclModes) return err;
        try stderr.print("{s}: 読み込みまたは字句解析に失敗しました: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    defer graph.deinit();
    if (timer) |t| try t.phase(stderr, "module-load/parse");
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
    if (timer) |t| try t.phase(stderr, "semantic-analysis");
    if (!program.succeeded()) {
        for (program.diagnostics) |item| try item.render(sourceForDiagnostic(graph, item.file), stderr);
        return null;
    }
    var roots: std.ArrayList(*lnako.frontend.ast.Node) = .empty;
    defer roots.deinit(allocator);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var variant_roots: std.ArrayList(*lnako.frontend.ast.Node) = .empty;
    defer variant_roots.deinit(allocator);
    var variant_counts: std.ArrayList(usize) = .empty;
    defer variant_counts.deinit(allocator);
    var semantic_module_index: usize = 0;
    for (graph.modules) |module| {
        if (module.kind != .nako3) continue;
        try roots.append(allocator, module.parsed.?.root.?);
        try names.append(allocator, program.modules[semantic_module_index].name);
        semantic_module_index += 1;
        try paths.append(allocator, module.path);
        for (module.variants.items) |variant| try variant_roots.append(allocator, variant.parse.root.?);
        try variant_counts.append(allocator, module.variants.items.len);
    }
    // variant_roots.items への追加が終わってからモジュール単位の
    // 部分スライスへ切り分ける（追加中に切ると再確保でダングルする）。
    const module_variant_roots = try allocator.alloc([]const *lnako.frontend.ast.Node, roots.items.len);
    defer allocator.free(module_variant_roots);
    var variant_offset: usize = 0;
    for (variant_counts.items, 0..) |count, index| {
        module_variant_roots[index] = variant_roots.items[variant_offset .. variant_offset + count];
        variant_offset += count;
    }
    var hir_program = try lnako.ir.hir.lower(allocator, roots.items, names.items, paths.items, module_variant_roots, program);
    defer hir_program.deinit();
    if (timer) |t| try t.phase(stderr, "AST-lowering");
    var ir_program = try lnako.ir.lower_ssa.lower(allocator, hir_program);
    errdefer ir_program.deinit();
    if (timer) |t| try t.phase(stderr, "SSA-construction");
    ir_program.compat_js = options.compat_js;
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
    if (timer) |t| try t.phase(stderr, "module-metadata");
    var verification = try lnako.ir.verifier.verify(allocator, ir_program);
    defer verification.deinit();
    if (timer) |t| try t.phase(stderr, "SSA-verification");
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

test "package importは共通compile経路からAOT用IR module metadataへ到達する" {
    const TestProvider = struct {
        fn read(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (pathHasSuffix(path, "main.nako3")) return allocator.dupe(u8, "!「パッケージ:math」を取り込む\n");
            if (pathHasSuffix(path, "packages/math/index.nako3")) return allocator.dupe(u8, "A=1\n");
            return error.FileNotFound;
        }
    };
    const TestResolver = struct {
        fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, specifier: []const u8) !lnako.semantic.module_graph.ResolvedPackageImport {
            if (!std.mem.eql(u8, specifier, "パッケージ:math")) return error.PackageNotFound;
            return .{
                .path = try std.fs.path.resolve(allocator, &.{"packages/math/index.nako3"}),
                .canonical_id = try allocator.dupe(u8, "pkg:math-id/main"),
                .namespace = "math",
            };
        }
    };

    var resolver_context: u8 = 0;
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    var program = (try compileInputWithProvider(
        std.testing.allocator,
        "main.nako3",
        .{ .package_resolver = .{ .context = &resolver_context, .resolveFn = TestResolver.resolve } },
        &stderr.writer,
        .{ .context = &resolver_context, .readFn = TestProvider.read },
    )) orelse return error.CompileFailed;
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 2), program.module_entries.len);
    try std.testing.expectEqual(@as(usize, 2), program.module_names.len);
    try std.testing.expectEqualStrings("main", program.module_names[0]);
    try std.testing.expectEqualStrings("math", program.module_names[1]);

    const llvm_compiler = lnako.backend.llvm.compiler;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const optimizations = [_]llvm_compiler.Optimization{ .o0, .o1, .o2, .o3 };
    for (optimizations) |optimization| {
        const output_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/package-{s}.ll", .{ temporary.sub_path, @tagName(optimization) });
        defer std.testing.allocator.free(output_path);
        var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer diagnostics.deinit();
        llvm_compiler.compile(std.testing.allocator, std.testing.io, program, .{
            .source_path = "main.nako3",
            .output_path = output_path,
            .emit = .llvm_ir,
            .optimization = optimization,
        }, &diagnostics.writer) catch |failure| switch (failure) {
            error.LlvmLibraryNotFound => return error.SkipZigTest,
            else => return failure,
        };
        const llvm_ir = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, output_path, std.testing.allocator, .limited(4 * 1024 * 1024));
        defer std.testing.allocator.free(llvm_ir);
        try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "target triple") != null);
        try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "define") != null);
    }
}

test "AOT compile permits unresolved qualified names outside package dependency scope" {
    const TestProvider = struct {
        fn read(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (pathHasSuffix(path, "main.nako3")) return allocator.dupe(u8, "!「pkg:math」を取り込む\n!「pkg:orphan」を取り込む\n");
            if (pathHasSuffix(path, "packages/math/index.nako3")) return allocator.dupe(u8, "値=42\n");
            if (pathHasSuffix(path, "packages/orphan/index.nako3")) return allocator.dupe(u8, "math__値を表示。\n");
            return error.FileNotFound;
        }
    };
    const TestResolver = struct {
        const Package = struct { path: []const u8, canonical_id: []const u8, namespace: []const u8 };

        fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, specifier: []const u8) !lnako.semantic.module_graph.ResolvedPackageImport {
            const package: Package = if (std.mem.eql(u8, specifier, "pkg:math")) .{
                .path = "packages/math/index.nako3",
                .canonical_id = "pkg:math/main",
                .namespace = "math",
            } else if (std.mem.eql(u8, specifier, "pkg:orphan")) .{
                .path = "packages/orphan/index.nako3",
                .canonical_id = "pkg:orphan/main",
                .namespace = "orphan",
            } else return error.PackageNotFound;
            return .{
                .path = try std.fs.path.resolve(allocator, &.{package.path}),
                .canonical_id = try allocator.dupe(u8, package.canonical_id),
                .namespace = package.namespace,
            };
        }
    };
    var context: u8 = 0;
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    const program = try compileInputWithProvider(
        std.testing.allocator,
        "main.nako3",
        .{ .package_resolver = .{ .context = &context, .resolveFn = TestResolver.resolve } },
        &stderr.writer,
        .{ .context = &context, .readFn = TestProvider.read },
    );
    var compiled = program orelse return error.UnexpectedCompileFailure;
    defer compiled.deinit();
    var saw_unresolved_qualified_load = false;
    for (compiled.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode == .load_global and std.mem.eql(u8, instruction.name, "math__値")) {
            saw_unresolved_qualified_load = true;
        }
    };
    try std.testing.expect(saw_unresolved_qualified_load);
}

fn pathHasSuffix(path: []const u8, suffix: []const u8) bool {
    if (suffix.len > path.len) return false;
    const start = path.len - suffix.len;
    if (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') return false;
    for (suffix, 0..) |char, index| {
        const path_char = path[start + index];
        const normalized_path_char: u8 = if (path_char == '\\') '/' else path_char;
        const normalized_suffix_char: u8 = if (char == '\\') '/' else char;
        if (normalized_path_char != normalized_suffix_char) return false;
    }
    return true;
}

const FrontendTimer = struct {
    io: std.Io,
    last: i96,

    fn phase(self: *FrontendTimer, diagnostics: *std.Io.Writer, label: []const u8) !void {
        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        try diagnostics.print("[Compiler] {s}: {d}ns\n", .{ label, now - self.last });
        try diagnostics.flush();
        self.last = now;
    }
};
