//! `global` binding の入口が公開するソース命令を、無修飾名から取り込み先の
//! 実シンボルへ直接解決することの回帰テスト（先行レビュー #5）。

const std = @import("std");
const module_graph = @import("module_graph.zig");
const analyzer = @import("analyzer.zig");

const Load = module_graph.load;
const ModuleGraph = module_graph.ModuleGraph;
const PackageResolver = module_graph.PackageResolver;
const ResolvedPackageImport = module_graph.ResolvedPackageImport;
const SourceProvider = module_graph.SourceProvider;

const MemoryProvider = struct {
    files: []const File,
    main_source: []const u8 = "",

    const File = struct { suffix: []const u8, source: []const u8 };

    fn provider(self: *MemoryProvider) SourceProvider {
        return .{ .context = self, .readFn = read };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *MemoryProvider = @ptrCast(@alignCast(context));
        if (std.mem.endsWith(u8, path, "main.nako3")) return allocator.dupe(u8, self.main_source);
        for (self.files) |file| {
            if (path.len >= file.suffix.len and
                std.mem.eql(u8, path[path.len - file.suffix.len ..], file.suffix))
            {
                return allocator.dupe(u8, file.source);
            }
        }
        return error.FileNotFound;
    }
};

const gcmd_globals = [_]module_graph.GlobalCommand{.{ .name = "加算確認" }};
const extra_globals = [_]module_graph.GlobalCommand{.{ .name = "別取得" }};
const builtin_globals = [_]module_graph.GlobalCommand{.{ .name = "表示" }};

const Resolver = struct {
    fn resolver(self: *Resolver) PackageResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !ResolvedPackageImport {
        if (!std.mem.startsWith(u8, specifier, "pkg:")) return error.InvalidPackageSpecifier;
        const reference = specifier["pkg:".len..];
        if (std.mem.eql(u8, reference, "gcmd")) {
            return .{
                .path = try std.fs.path.resolve(allocator, &.{"packages/gcmd/index.nako3"}),
                .canonical_id = try allocator.dupe(u8, "pkg:gcmd/main"),
                .namespace = "gcmd",
                .package_root = try std.fs.path.resolve(allocator, &.{"packages/gcmd"}),
                .package_owner = try allocator.dupe(u8, "pkg:gcmd"),
                .global_commands = &gcmd_globals,
            };
        }
        if (std.mem.eql(u8, reference, "gcmd/extra")) {
            return .{
                .path = try std.fs.path.resolve(allocator, &.{"packages/gcmd/extra.nako3"}),
                .canonical_id = try allocator.dupe(u8, "pkg:gcmd/extra"),
                .namespace = "gcmd__extra",
                .package_root = try std.fs.path.resolve(allocator, &.{"packages/gcmd"}),
                .package_owner = try allocator.dupe(u8, "pkg:gcmd"),
                .global_commands = &extra_globals,
            };
        }
        if (std.mem.eql(u8, reference, "scoped")) {
            return .{
                .path = try std.fs.path.resolve(allocator, &.{"packages/gcmd/index.nako3"}),
                .canonical_id = try allocator.dupe(u8, "pkg:scoped/main"),
                .namespace = "scoped",
                .package_root = try std.fs.path.resolve(allocator, &.{"packages/gcmd"}),
                .package_owner = try allocator.dupe(u8, "pkg:scoped"),
            };
        }
        if (std.mem.eql(u8, reference, "builtin")) {
            return .{
                .path = try std.fs.path.resolve(allocator, &.{"packages/builtin/index.nako3"}),
                .canonical_id = try allocator.dupe(u8, "pkg:builtin/main"),
                .namespace = "builtin",
                .package_root = try std.fs.path.resolve(allocator, &.{"packages/builtin"}),
                .package_owner = try allocator.dupe(u8, "pkg:builtin"),
                .global_commands = &builtin_globals,
            };
        }
        return error.PackageNotFound;
    }
};

const files = [_]MemoryProvider.File{
    .{ .suffix = "packages/gcmd/index.nako3", .source = "●(Xを)加算確認とは\nX+2で戻る\nここまで\n" },
    .{ .suffix = "packages/gcmd/extra.nako3", .source = "●別取得とは\n7で戻る\nここまで\n" },
    .{ .suffix = "packages/builtin/index.nako3", .source = "●表示とは\n99で戻る\nここまで\n" },
};

fn loadGraph(allocator: std.mem.Allocator, main_source: []const u8) !ModuleGraph {
    var memory = MemoryProvider{ .files = &files, .main_source = main_source };
    var resolver = Resolver{};
    return Load(allocator, "main.nako3", memory.provider(), .{ .package_resolver = resolver.resolver() });
}

test "global 入口の source 命令は無修飾名から実シンボルへ直接束縛する" {
    const a = std.testing.allocator;
    var graph = try loadGraph(a,
        \\!「pkg:gcmd」を取り込む
        \\加算確認(40)を表示
        \\
    );
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    var program = try graph.analyze(a);
    defer program.deinit();
    try std.testing.expect(program.succeeded());

    var found = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "加算確認")) continue;
        if (binding.kind != .call) continue;
        const symbol_id = binding.symbol orelse return error.TestExpectedSymbol;
        const symbol = program.symbols[symbol_id];
        try std.testing.expectEqual(analyzer.BindingKind.call, binding.kind);
        try std.testing.expectEqual(analyzer.SymbolKind.function, symbol.kind);
        try std.testing.expectEqualStrings(binding.resolved_name, symbol.qualified_name);
        try std.testing.expect(std.mem.startsWith(u8, symbol.qualified_name, "package"));
        found = true;
    }
    try std.testing.expect(found);
}

test "取り込み位置より前の global 命令は解決しない" {
    const a = std.testing.allocator;
    var graph = try loadGraph(a,
        \\加算確認(40)を表示
        \\!「pkg:gcmd」を取り込む
        \\
    );
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    var program = try graph.analyze(a);
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
}

test "scoped 入口の package 関数は無修飾名で見えない" {
    const a = std.testing.allocator;
    var graph = try loadGraph(a,
        \\!「pkg:scoped」を取り込む
        \\加算確認(40)を表示
        \\
    );
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    var program = try graph.analyze(a);
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
}

test "global 入口は取り込んだ subpath の命令だけを可視にする" {
    const a = std.testing.allocator;
    {
        var graph = try loadGraph(a,
            \\!「pkg:gcmd/extra」を取り込む
            \\別取得()を表示
            \\
        );
        defer graph.deinit();
        var program = try graph.analyze(a);
        defer program.deinit();
        try std.testing.expect(program.succeeded());
        var found = false;
        for (program.bindings) |binding| {
            if (!std.mem.eql(u8, binding.name, "別取得")) continue;
            const symbol_id = binding.symbol orelse continue;
            const symbol = program.symbols[symbol_id];
            try std.testing.expect(std.mem.endsWith(u8, symbol.qualified_name, "__別取得"));
            found = true;
        }
        try std.testing.expect(found);
    }
    {
        var graph = try loadGraph(a,
            \\!「pkg:gcmd/extra」を取り込む
            \\加算確認(40)を表示
            \\
        );
        defer graph.deinit();
        var program = try graph.analyze(a);
        defer program.deinit();
        try std.testing.expect(!program.succeeded());
    }
}

test "既定の組み込み命令と同名の global 命令は組み込みを上書きしない" {
    const a = std.testing.allocator;
    var graph = try loadGraph(a,
        \\!「pkg:builtin」を取り込む
        \\表示(1)
        \\
    );
    defer graph.deinit();
    var program = try graph.analyze(a);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var found = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "表示")) continue;
        if (binding.kind == .declaration) continue;
        try std.testing.expectEqual(analyzer.BindingKind.builtin, binding.kind);
        try std.testing.expect(binding.symbol == null);
        found = true;
    }
    try std.testing.expect(found);
}
