const std = @import("std");
const lnako = @import("lnako");
const compile_pipeline = @import("compile.zig");

pub fn writeCompatExecutable(allocator: std.mem.Allocator, io: std.Io, executable_path: []const u8, input_path: []const u8, output_path: []const u8, forced_mode: lnako.frontend.token.Mode) !void {
    const resolved_output = try std.fs.path.resolve(allocator, &.{output_path});
    defer allocator.free(resolved_output);
    const resolved_executable = try std.fs.path.resolve(allocator, &.{executable_path});
    defer allocator.free(resolved_executable);
    if (std.mem.eql(u8, resolved_output, resolved_executable)) return error.OutputOverwritesCompiler;

    var package_root: ?[]u8 = null;
    defer if (package_root) |root| allocator.free(root);
    var package_environment: ?lnako.package.import_resolver.Resolver = null;
    defer if (package_environment) |*environment| environment.deinit();
    package_root = lnako.package.import_resolver.findProjectRoot(allocator, io, input_path) catch |err| if (err == error.OutOfMemory) return err else null;
    if (package_root) |root| {
        package_environment = lnako.package.import_resolver.Resolver.load(allocator, io, root) catch |err| if (err == error.OutOfMemory) return err else null;
    }

    var file_provider = lnako.semantic.module_graph.FileProvider{ .io = io };
    var graph = try lnako.semantic.module_graph.load(allocator, input_path, file_provider.sourceProvider(), .{
        .compat_js = true,
        .forced_mode = forced_mode,
        .package_resolver = if (package_environment) |*environment| environment.packageResolver() else null,
    });
    defer graph.deinit();
    if (!graph.succeeded()) return error.InvalidCompatSourceGraph;
    const files = try allocator.alloc(lnako.compat.embedded.SourceFile, graph.modules.len);
    defer allocator.free(files);
    var package_imports: std.ArrayListUnmanaged(lnako.compat.embedded.PackageImport) = .empty;
    defer package_imports.deinit(allocator);
    for (graph.modules, files) |module, *file| {
        file.* = .{ .path = module.path, .source = module.source };
        for (module.imports) |item| {
            const canonical_id = item.canonical_id orelse continue;
            const target = item.target orelse continue;
            try package_imports.append(allocator, .{
                .importer = module.path,
                .specifier = item.requested,
                .path = item.resolved_path,
                .canonical_id = canonical_id,
                .namespace = item.namespace orelse graph.modules[target].name,
            });
        }
    }

    const compiler = try std.Io.Dir.cwd().readFileAlloc(io, executable_path, allocator, .limited(1024 * 1024 * 1024));
    defer allocator.free(compiler);
    const generated = try lnako.compat.embedded.createExecutableWithImports(allocator, compiler, graph.modules[graph.entry].path, files, forced_mode, package_imports.items);
    defer allocator.free(generated);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = generated,
        .flags = .{ .permissions = .executable_file },
    });
}

test "compat-js package import resolverを生成payloadと起動時compileへ引き継ぐ" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/math");
    try temporary.dir.writeFile(io, .{ .sub_path = "main.nako3", .data = "!「.nako/env/gen-test/deps/math/index.nako3」を取り込む\n!「パッケージ:math」を取り込む\nmath__値を表示。\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/math/index.nako3", .data = "値=5\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/math/nako.toml", .data =
        \\[package]
        \\name = "math"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\path = "index.nako3"
        \\
    });
    const lock_bytes = "{\"schemaVersion\":1,\"input\":{\"profile\":\"default\"},\"packages\":{\"pkg:math-id\":{\"id\":\"pkg:math-id\",\"name\":\"math\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/math\"},\"dependencies\":[]}}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock_bytes });
    try temporary.dir.writeFile(io, .{ .sub_path = "compiler.bin", .data = "EXE" });

    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const input_path = try std.fs.path.join(allocator, &.{ root, "main.nako3" });
    defer allocator.free(input_path);
    const executable_path = try std.fs.path.join(allocator, &.{ root, "compiler.bin" });
    defer allocator.free(executable_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "app.bin" });
    defer allocator.free(output_path);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock_bytes, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const environment = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"dependencies\":[{{\"alias\":\"math\",\"package\":\"pkg:math-id\"}}],\"packages\":{{\"pkg:math-id\":{{\"name\":\"math\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/math\",\"exports\":[{{\"name\":\"main\",\"path\":\"index.nako3\"}}],\"dependencies\":[]}}}}}}",
        .{lock_hex},
    );
    defer allocator.free(environment);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = environment });

    try writeCompatExecutable(allocator, io, executable_path, input_path, output_path, .{});
    var package = (try lnako.compat.embedded.readExecutable(allocator, io, output_path)).?;
    defer package.deinit();
    try std.testing.expectEqual(@as(usize, 1), package.package_imports.len);
    try std.testing.expectEqualStrings("math", package.package_imports[0].namespace);

    var stderr: std.Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();
    var ir_program = (try compile_pipeline.compileInputWithProvider(allocator, package.entry_path, .{
        .compat_js = true,
        .package_resolver = package.packageResolver(),
    }, &stderr.writer, package.sourceProvider())) orelse return error.EmbeddedPackageCompileFailed;
    defer ir_program.deinit();
    try std.testing.expectEqual(@as(usize, 2), ir_program.module_names.len);
    try std.testing.expectEqualStrings("index", ir_program.module_names[1]);
}
