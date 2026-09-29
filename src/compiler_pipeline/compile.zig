const std = @import("std");
const lnako = @import("lnako");

/// 入力コンパイルのオプション。`forced_mode` は .dncl/.dncl2 拡張子や
/// --dncl/--dncl2 フラグで強制される構文モード。
const InvalidPackageEnvironment = struct {
    fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8, _: []const u8) anyerror!lnako.semantic.module_graph.ResolvedPackageImport {
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
    var internal_names: std.ArrayList([]const u8) = .empty;
    defer internal_names.deinit(allocator);
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
        try internal_names.append(allocator, graph.internal_module_names[module.index]);
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
    const plugin_namespaces = try allocator.alloc(std.ArrayList([]const u8), graph.modules.len);
    defer {
        for (plugin_namespaces) |*list| list.deinit(allocator);
        allocator.free(plugin_namespaces);
    }
    for (plugin_namespaces) |*list| list.* = .empty;
    for (graph.modules) |module| {
        if (module.kind != .nako3) continue;
        for (module.imports) |item| if (item.target) |target| {
            if (graph.modules[target].kind != .javascript) continue;
            plugin_modules[target] = true;
            // `pkg:` import経由のESM pluginは公開namespaceで修飾した命令のみ
            // 公開する。同一pathを複数aliasでimportした場合は全namespaceを
            // 保持する（native pluginの `native_plugin_packages` と同契約）。
            // 直接path import辺がある場合は空エントリで「無修飾登録も行う」を
            // 表し、`pkg:` 併存でも直接importの無修飾命令を消さない（native
            // plugin側の `directly_imported` と同じ検出規則）。
            const namespace = if (item.canonical_id != null)
                // runtime 登録名は dispatch namespace（scope 修飾済み）を使う。
                // 推移依存で別ownerの同aliasと登録keyが衝突しないため。
                item.dispatch_namespace orelse item.namespace orelse continue
            else
                "";
            var listed = false;
            for (plugin_namespaces[target].items) |existing| {
                if (std.mem.eql(u8, existing, namespace)) {
                    listed = true;
                    break;
                }
            }
            if (!listed) try plugin_namespaces[target].append(allocator, namespace);
        };
    }
    for (graph.modules) |module| {
        if (module.kind != .javascript) continue;
        const basename = std.fs.path.basename(module.path);
        if (std.ascii.eqlIgnoreCase(basename, "plugin_httpserver.mjs") or std.ascii.eqlIgnoreCase(basename, "plugin_httpserver.js")) {
            http_server_plugin_imported = true;
        }
        if (module.source.len == 0) continue;
        const namespaces = try ir_program.arena.allocator().alloc([]const u8, plugin_namespaces[module.index].items.len);
        for (plugin_namespaces[module.index].items, namespaces) |namespace, *copy| copy.* = try ir_program.arena.allocator().dupe(u8, namespace);
        try javascript_modules.append(ir_program.arena.allocator(), .{
            .path = try ir_program.arena.allocator().dupe(u8, module.path),
            .source = try ir_program.arena.allocator().dupe(u8, module.source),
            .is_plugin = plugin_modules[module.index],
            .namespaces = namespaces,
        });
    }
    ir_program.javascript_modules = try javascript_modules.toOwnedSlice(ir_program.arena.allocator());
    ir_program.http_server_plugin_imported = http_server_plugin_imported;
    // シンボル修飾namespace（package moduleでは公開module名と異なる）を
    // エラー位置・デバッグ情報の逆引き用に実行時名と並列で保持する。
    const internal_module_names = try ir_program.arena.allocator().alloc([]const u8, internal_names.items.len);
    for (internal_names.items, 0..) |name, index| internal_module_names[index] = try ir_program.arena.allocator().dupe(u8, name);
    ir_program.internal_module_names = internal_module_names;
    var native_plugin_paths: std.ArrayList([]const u8) = .empty;
    var native_plugin_packages: std.ArrayList(lnako.ir.nako_ir.NativePluginPackage) = .empty;
    for (graph.modules) |module| {
        if (module.kind != .native_plugin) continue;
        try native_plugin_paths.append(ir_program.arena.allocator(), try ir_program.arena.allocator().dupe(u8, module.path));
    }
    ir_program.native_plugin_paths = try native_plugin_paths.toOwnedSlice(ir_program.arena.allocator());
    // `pkg:` import経由のnative pluginは公開namespaceで修飾した命令のみを
    // 公開する。同一pathを直接path importでも取り込んでいる場合は、無修飾
    // 公開とnamespace修飾公開の両方を登録する — 直接取り込み側へ全面委譲
    // すると `加算` と `math__加算` の両方を登録するpluginで `math__加算`
    // がpackage側の `加算` ではなく plugin 自身の同名raw命令へ誤配される。
    // 直接importの存在は `namespace=""` の sentinel entry で表す
    // （JavaScriptModule.namespaces の空エントリと同契約）。
    for (graph.modules) |module| {
        for (module.imports) |item| {
            const target = item.target orelse continue;
            const target_module = graph.modules[target];
            if (target_module.kind != .native_plugin) continue;
            const namespace: []const u8 = if (item.canonical_id != null)
                // runtime 登録名は dispatch namespace（scope 修飾済み）を使う。
                item.dispatch_namespace orelse item.namespace orelse continue
            else
                "";
            var listed = false;
            for (native_plugin_packages.items) |package| {
                if (std.mem.eql(u8, package.path, target_module.path) and std.mem.eql(u8, package.namespace, namespace)) {
                    listed = true;
                    break;
                }
            }
            if (!listed) try native_plugin_packages.append(ir_program.arena.allocator(), .{
                .path = try ir_program.arena.allocator().dupe(u8, target_module.path),
                .namespace = try ir_program.arena.allocator().dupe(u8, namespace),
            });
        }
    }
    ir_program.native_plugin_packages = try native_plugin_packages.toOwnedSlice(ir_program.arena.allocator());
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
        fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !lnako.semantic.module_graph.ResolvedPackageImport {
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

test "package関数の内部namespaceはerror/debug位置をpackage source pathへ解決する" {
    const TestProvider = struct {
        fn read(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (pathHasSuffix(path, "main.nako3")) return allocator.dupe(u8, "!「パッケージ:demo」を取り込む\n");
            if (pathHasSuffix(path, "packages/demo/index.nako3")) return allocator.dupe(u8, "●報告とは\nデバッグ表示(\"pkg\")\nここまで\n");
            return error.FileNotFound;
        }
    };
    const TestResolver = struct {
        fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !lnako.semantic.module_graph.ResolvedPackageImport {
            if (!std.mem.eql(u8, specifier, "パッケージ:demo")) return error.PackageNotFound;
            return .{
                .path = try std.fs.path.resolve(allocator, &.{"packages/demo/index.nako3"}),
                .canonical_id = try allocator.dupe(u8, "pkg:demo-id/main"),
                .namespace = "demo",
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

    try std.testing.expectEqual(@as(usize, 2), program.module_names.len);
    try std.testing.expectEqual(@as(usize, 2), program.internal_module_names.len);
    try std.testing.expectEqualStrings("demo", program.module_names[1]);
    try std.testing.expect(std.mem.startsWith(u8, program.internal_module_names[1], "package__"));

    const package_path = program.module_paths[1];
    const report_name = try std.fmt.allocPrint(std.testing.allocator, "{s}__報告", .{program.internal_module_names[1]});
    defer std.testing.allocator.free(report_name);
    try std.testing.expectEqual(@as(?usize, 1), program.moduleIndexForFunctionName(report_name));
    try std.testing.expect(pathHasSuffix(package_path, "packages/demo/index.nako3"));
    // エントリ関数（実行時module名）は引き続き公開名で解決される。
    try std.testing.expectEqual(@as(?usize, 1), program.moduleIndexForFunctionName("demo__$entry"));

    var generated = try lnako.backend.llvm.module.generate(std.testing.allocator, program, "main.nako3", false);
    defer generated.deinit(std.testing.allocator);
    // debug path定数はi8列で出力される。"index.nako3" のbyte列が
    // package関数のデバッグ表示locationとして含まれることを検証する。
    try std.testing.expect(std.mem.indexOf(u8, generated.text, "i8 105, i8 110, i8 100, i8 101, i8 120, i8 46, i8 110, i8 97, i8 107, i8 111, i8 51") != null);
}

test "AOT compile gates a shared-target package alias on its own import position" {
    const TestProvider = struct {
        fn read(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (pathHasSuffix(path, "main.nako3")) return allocator.dupe(u8, "!「./math.nako3」を取り込む\nmath_alt__値=30\n!「pkg:math」を取り込む\nmath__値を表示\nmath_alt__値を表示\n!「pkg:math-alt」を取り込む\nmath_alt__値を表示\n");
            if (pathHasSuffix(path, "math.nako3")) return allocator.dupe(u8, "値=10\n");
            if (pathHasSuffix(path, "packages/math/index.nako3")) return allocator.dupe(u8, "値=20\n");
            return error.FileNotFound;
        }
    };
    const TestResolver = struct {
        fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !lnako.semantic.module_graph.ResolvedPackageImport {
            const namespace = if (std.mem.eql(u8, specifier, "pkg:math"))
                "math"
            else if (std.mem.eql(u8, specifier, "pkg:math-alt"))
                "math_alt"
            else
                return error.PackageNotFound;
            return .{
                .path = try std.fs.path.resolve(allocator, &.{"packages/math/index.nako3"}),
                .canonical_id = try allocator.dupe(u8, "pkg:math/main"),
                .namespace = namespace,
            };
        }
    };
    var context: u8 = 0;
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    const maybe_program = try compileInputWithProvider(
        std.testing.allocator,
        "main.nako3",
        .{ .package_resolver = .{ .context = &context, .resolveFn = TestResolver.resolve } },
        &stderr.writer,
        .{ .context = &context, .readFn = TestProvider.read },
    );
    var program = maybe_program orelse return error.CompileFailed;
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 3), program.module_names.len);
    var pre_import_local_load = false;
    for (program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode == .load_global and std.mem.eql(u8, instruction.name, "math_alt__値")) pre_import_local_load = true;
    };
    try std.testing.expect(pre_import_local_load);
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

        fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !lnako.semantic.module_graph.ResolvedPackageImport {
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

test "package内の相対import helperはAOT IRでもopaqueなpackage内部namespaceを維持する" {
    const TestProvider = struct {
        fn read(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (pathHasSuffix(path, "main.nako3")) return allocator.dupe(u8, "!「pkg:math」を取り込む\nmath__報告()\n");
            if (pathHasSuffix(path, "packages/math/index.nako3")) return allocator.dupe(u8, "!「./helper.nako3」を取り込む\n●報告とは\nhelper__内部処理()\nここまで\n");
            if (pathHasSuffix(path, "packages/math/helper.nako3")) return allocator.dupe(u8, "●内部処理とは\nここまで\n");
            return error.FileNotFound;
        }
    };
    const TestResolver = struct {
        fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !lnako.semantic.module_graph.ResolvedPackageImport {
            if (!std.mem.eql(u8, specifier, "pkg:math")) return error.PackageNotFound;
            return .{
                .path = try std.fs.path.resolve(allocator, &.{"packages/math/index.nako3"}),
                .canonical_id = try allocator.dupe(u8, "pkg:math/main"),
                .namespace = "math",
                .package_root = try std.fs.path.resolve(allocator, &.{"packages/math"}),
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

    try std.testing.expectEqual(@as(usize, 3), compiled.module_names.len);
    try std.testing.expectEqual(@as(usize, 3), compiled.internal_module_names.len);
    // helperはcanonical exportではないが、実行時module名（ファイルstem）と
    // opaqueな内部namespaceを別々に保持する。推測可能な `helper__` prefixの
    // 関数名は存在せず、内部名経由ではsource pathへ逆引きできる。
    try std.testing.expectEqualStrings("helper", compiled.module_names[2]);
    try std.testing.expect(std.mem.startsWith(u8, compiled.internal_module_names[2], "package__"));
    // stem名 `helper__` の照合は診断pathの逆引きとしてmoduleへ帰属させる
    // （IR内の実関数名は内部namespace修飾なのでglobal keyとしては露出しない）。
    try std.testing.expectEqual(@as(?usize, 2), compiled.moduleIndexForFunctionName("helper__内部処理"));
    const internal_call = try std.fmt.allocPrint(std.testing.allocator, "{s}__内部処理", .{compiled.internal_module_names[2]});
    defer std.testing.allocator.free(internal_call);
    try std.testing.expectEqual(@as(?usize, 2), compiled.moduleIndexForFunctionName(internal_call));
    try std.testing.expect(pathHasSuffix(compiled.module_paths[2], "packages/math/helper.nako3"));
}

test "package所有moduleのroot外への相対importはAOT compileでも拒否される" {
    const TestProvider = struct {
        fn read(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (pathHasSuffix(path, "main.nako3")) return allocator.dupe(u8, "!「pkg:math」を取り込む\nmath__報告()\n");
            if (pathHasSuffix(path, "packages/math/index.nako3")) return allocator.dupe(u8, "!「../outside.nako3」を取り込む\n●報告とは\nここまで\n");
            if (pathHasSuffix(path, "packages/outside.nako3")) return allocator.dupe(u8, "●外部処理とは\nここまで\n");
            return error.FileNotFound;
        }
    };
    const TestResolver = struct {
        fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !lnako.semantic.module_graph.ResolvedPackageImport {
            if (!std.mem.eql(u8, specifier, "pkg:math")) return error.PackageNotFound;
            return .{
                .path = try std.fs.path.resolve(allocator, &.{"packages/math/index.nako3"}),
                .canonical_id = try allocator.dupe(u8, "pkg:math/main"),
                .namespace = "math",
                .package_root = try std.fs.path.resolve(allocator, &.{"packages/math"}),
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
    // module graph構築で境界外importが診断され、compile全体が失敗する
    // （境界外fileはIRへ到達しない）。
    try std.testing.expect(program == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.writer.buffered(), "package rootの外") != null);
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

test "package経由のnative plugin命令は公開namespaceで修飾されAOT dispatchされる" {
    const TestProvider = struct {
        fn read(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (pathHasSuffix(path, "main.nako3")) return allocator.dupe(u8, "!「pkg:nativepkg」を取り込む\nnativepkg__外部追加(1, 2)\n外部追加(1, 2)\n");
            return error.FileNotFound;
        }
    };
    const TestResolver = struct {
        fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !lnako.semantic.module_graph.ResolvedPackageImport {
            if (!std.mem.eql(u8, specifier, "pkg:nativepkg")) return error.PackageNotFound;
            return .{
                .path = try std.fs.path.resolve(allocator, &.{"packages/nativepkg/plugin.so"}),
                .canonical_id = try allocator.dupe(u8, "pkg:nativepkg/main"),
                .namespace = "nativepkg",
                .package_root = try std.fs.path.resolve(allocator, &.{"packages/nativepkg"}),
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

    // package import由来のplugin pathはnamespace対応表に載る
    try std.testing.expectEqual(@as(usize, 1), compiled.native_plugin_packages.len);
    try std.testing.expectEqualStrings("nativepkg", compiled.native_plugin_packages[0].namespace);
    try std.testing.expect(pathHasSuffix(compiled.native_plugin_packages[0].path, "packages/nativepkg/plugin.so"));
    try std.testing.expectEqual(@as(usize, 1), compiled.native_plugin_paths.len);

    // `nativepkg__外部追加` は修飾名なので isQualifiedGlobal に見えるが、
    // package対応表により plugin dispatch へ分類される。無修飾の `外部追加`
    // は動的builtinに束縛されず plugin dispatch にも流れない。
    const backend_module = lnako.backend.llvm.module;
    var qualified_plugin_call = false;
    for (compiled.functions) |function| {
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.opcode != .call) continue;
                if (!backend_module.isNativePluginCall(compiled, function, instruction)) continue;
                // plugin dispatchへ流れるのはpackage修飾名のみ。無修飾の
                // `外部追加`はlocal宣言へ束縛されpluginへ届かない。
                try std.testing.expect(std.mem.startsWith(u8, instruction.name, "nativepkg__"));
                if (std.mem.eql(u8, instruction.name, "nativepkg__外部追加")) qualified_plugin_call = true;
            }
        }
    }
    try std.testing.expect(qualified_plugin_call);
}

test "直接importとpackage aliasが併存するESM moduleは無修飾と修飾名の両方を登録する" {
    const TestProvider = struct {
        fn read(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (pathHasSuffix(path, "main.nako3")) return allocator.dupe(u8, "!「esmplugin.mjs」を取り込む\n!「pkg:esmpkg」を取り込む\n");
            if (pathHasSuffix(path, "esmplugin.mjs")) return allocator.dupe(u8, "export default {}");
            return error.FileNotFound;
        }
    };
    const TestResolver = struct {
        fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !lnako.semantic.module_graph.ResolvedPackageImport {
            if (!std.mem.eql(u8, specifier, "pkg:esmpkg")) return error.PackageNotFound;
            return .{
                .path = try std.fs.path.resolve(allocator, &.{"esmplugin.mjs"}),
                .canonical_id = try allocator.dupe(u8, "pkg:esmpkg/main"),
                .namespace = "esmpkg",
                .package_root = try std.fs.path.resolve(allocator, &.{"."}),
            };
        }
    };
    var context: u8 = 0;
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    const program = try compileInputWithProvider(
        std.testing.allocator,
        "main.nako3",
        .{ .package_resolver = .{ .context = &context, .resolveFn = TestResolver.resolve }, .compat_js = true },
        &stderr.writer,
        .{ .context = &context, .readFn = TestProvider.read },
    );
    var compiled = program orelse return error.UnexpectedCompileFailure;
    defer compiled.deinit();

    // 同一pathを直接path importでも取り込んでいるため、namespaces は
    // package namespace（`esmpkg`）と無修飾公開の空 sentinel の両方を持つ。
    // native plugin側の `directly_imported` と同契約。
    var found = false;
    for (compiled.javascript_modules) |module| {
        if (!pathHasSuffix(module.path, "esmplugin.mjs")) continue;
        found = true;
        try std.testing.expect(module.is_plugin);
        try std.testing.expectEqual(@as(usize, 2), module.namespaces.len);
        var has_unqualified = false;
        var has_qualified = false;
        for (module.namespaces) |namespace| {
            if (namespace.len == 0) has_unqualified = true;
            if (std.mem.eql(u8, namespace, "esmpkg")) has_qualified = true;
        }
        try std.testing.expect(has_unqualified);
        try std.testing.expect(has_qualified);
    }
    try std.testing.expect(found);
}
