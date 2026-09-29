const std = @import("std");
const diagnostic = @import("../frontend/diagnostic.zig");
const parser = @import("../frontend/parser.zig");
const module_graph = @import("module_graph.zig");

const load = module_graph.load;
const ModuleGraph = module_graph.ModuleGraph;
const ModuleKind = module_graph.ModuleKind;
const PackageResolver = module_graph.PackageResolver;
const ResolvedPackageImport = module_graph.ResolvedPackageImport;
const SourceProvider = module_graph.SourceProvider;

const MemoryProvider = struct {
    files: []const File,

    const File = struct { suffix: []const u8, source: []const u8 };

    fn sourceProvider(self: *MemoryProvider) SourceProvider {
        return .{ .context = self, .readFn = read };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *MemoryProvider = @ptrCast(@alignCast(context));
        for (self.files) |file| if (pathHasSuffix(path, file.suffix)) return allocator.dupe(u8, file.source);
        return error.FileNotFound;
    }
};

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

const PackageTestResolver = struct {
    fn resolver(self: *PackageTestResolver) PackageResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !ResolvedPackageImport {
        const reference = if (std.mem.startsWith(u8, specifier, "パッケージ:"))
            specifier["パッケージ:".len..]
        else if (std.mem.startsWith(u8, specifier, "pkg:"))
            specifier["pkg:".len..]
        else
            return error.InvalidPackageSpecifier;
        const path = if (std.mem.eql(u8, reference, "math") or std.mem.eql(u8, reference, "math-alt") or std.mem.eql(u8, reference, "math/dup"))
            "packages/math/index.nako3"
        else if (std.mem.eql(u8, reference, "foreign-dup"))
            "packages/math/index.nako3"
        else if (std.mem.eql(u8, reference, "util"))
            "packages/util/index.nako3"
        else if (std.mem.eql(u8, reference, "math/vector"))
            "packages/math/vector.nako3"
        else if (std.mem.eql(u8, reference, "geometry"))
            "packages/geometry/index.nako3"
        else if (std.mem.eql(u8, reference, "esm"))
            "packages/esm/plugin.mjs"
        else if (std.mem.eql(u8, reference, "deep"))
            "packages/deep/api/v1.nako3"
        else
            return error.PackageNotFound;
        const namespace = if (std.mem.eql(u8, reference, "math"))
            "math"
        else if (std.mem.eql(u8, reference, "math-alt"))
            "math_alt"
        else if (std.mem.eql(u8, reference, "math/dup"))
            "dup"
        else if (std.mem.eql(u8, reference, "foreign-dup"))
            "foreign"
        else if (std.mem.eql(u8, reference, "util"))
            "util"
        else if (std.mem.eql(u8, reference, "math/vector"))
            "math__vector"
        else if (std.mem.eql(u8, reference, "esm"))
            "esm"
        else if (std.mem.eql(u8, reference, "deep"))
            "deep__api__v1"
        else
            "geometry";
        const canonical_id = if (std.mem.eql(u8, reference, "math") or std.mem.eql(u8, reference, "math-alt"))
            "pkg:math-id/main"
        else if (std.mem.eql(u8, reference, "math/dup"))
            "pkg:math-id/dup"
        else if (std.mem.eql(u8, reference, "foreign-dup"))
            "pkg:foreign-id/main"
        else if (std.mem.eql(u8, reference, "util"))
            "pkg:util-id/main"
        else if (std.mem.eql(u8, reference, "math/vector"))
            "pkg:math-id/vector"
        else if (std.mem.eql(u8, reference, "esm"))
            "pkg:esm-id/main"
        else if (std.mem.eql(u8, reference, "deep"))
            "pkg:deep-id/api/v1"
        else
            "pkg:geometry-id/main";
        const package_owner = if (std.mem.eql(u8, reference, "foreign-dup"))
            "pkg:foreign-id"
        else if (std.mem.eql(u8, reference, "util"))
            "pkg:util-id"
        else if (std.mem.eql(u8, reference, "geometry"))
            "pkg:geometry-id"
        else if (std.mem.eql(u8, reference, "esm"))
            "pkg:esm-id"
        else if (std.mem.eql(u8, reference, "deep"))
            "pkg:deep-id"
        else
            "pkg:math-id";
        const resolved_path = try std.fs.path.resolve(allocator, &.{path});
        // `deep` はexport pathがpackage root直下でない（`api/v1.nako3`）ため
        // rootを明示する。canonical_idからのowner逆算が `pkg:deep-id/api`
        // を返し得る形を再現し、owner/rootの独立伝播を検証できるようにする。
        const package_root = if (std.mem.eql(u8, reference, "deep"))
            try std.fs.path.resolve(allocator, &.{"packages/deep"})
        else
            try allocator.dupe(u8, std.fs.path.dirname(resolved_path).?);
        return .{
            .path = resolved_path,
            .canonical_id = try allocator.dupe(u8, canonical_id),
            .namespace = namespace,
            .package_root = package_root,
            .package_owner = try allocator.dupe(u8, package_owner),
        };
    }
};

const NamespaceCollisionPackageResolver = struct {
    fn resolver(self: *NamespaceCollisionPackageResolver) PackageResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !ResolvedPackageImport {
        const path = if (std.mem.eql(u8, specifier, "pkg:scoped"))
            "packages/scoped/main.nako3"
        else if (std.mem.eql(u8, specifier, "pkg:flat"))
            "packages/flat/main.nako3"
        else
            return error.PackageNotFound;
        const canonical_id = if (std.mem.eql(u8, specifier, "pkg:scoped")) "pkg:scoped/main" else "pkg:flat/main";
        return .{
            .path = try std.fs.path.resolve(allocator, &.{path}),
            .canonical_id = try allocator.dupe(u8, canonical_id),
            .namespace = try allocator.dupe(u8, "alice__tool"),
            .package_owner = try allocator.dupe(u8, if (std.mem.eql(u8, specifier, "pkg:scoped")) "pkg:scoped" else "pkg:flat"),
        };
    }
};

test "正規化後に同じnamespaceとなる別package importを診断する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:scoped」を取り込む\n!「pkg:flat」を取り込む\n" },
        .{ .suffix = "packages/scoped/main.nako3", .source = "値=1\n" },
        .{ .suffix = "packages/flat/main.nako3", .source = "値=2\n" },
    } };
    var package_resolver = NamespaceCollisionPackageResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    var reported_namespace_collision = false;
    for (graph.diagnostics) |item| {
        if (std.mem.indexOf(u8, item.message, "同じ公開namespace") != null) reported_namespace_collision = true;
    }
    try std.testing.expect(reported_namespace_collision);
}

test "日本語パッケージ:とpkg:を注入resolverでsource exportへ解決する" {
    const cases = [_]struct { specifier: []const u8, suffix: []const u8 }{
        .{ .specifier = "パッケージ:math", .suffix = "packages/math/index.nako3" },
        .{ .specifier = "パッケージ:math/vector", .suffix = "packages/math/vector.nako3" },
        .{ .specifier = "pkg:math", .suffix = "packages/math/index.nako3" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "!「{s}」を取り込む\n", .{case.specifier});
        defer std.testing.allocator.free(source);
        var memory = MemoryProvider{ .files = &.{
            .{ .suffix = "main.nako3", .source = source },
            .{ .suffix = case.suffix, .source = "A=1\n" },
        } };
        var package_resolver = PackageTestResolver{};
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
        defer graph.deinit();
        try std.testing.expect(graph.succeeded());
        try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
        try std.testing.expect(pathHasSuffix(graph.modules[1].path, case.suffix));
        const expected_namespace = if (std.mem.eql(u8, case.specifier, "パッケージ:math/vector")) "math__vector" else "math";
        try std.testing.expectEqualStrings(expected_namespace, graph.modules[1].name);
        const expected_id = if (std.mem.eql(u8, case.specifier, "パッケージ:math/vector")) "pkg:math-id/vector" else "pkg:math-id/main";
        try std.testing.expectEqualStrings(expected_id, graph.modules[1].canonical_id.?);
    }
}

test "同一packageの別exportが同じ実体fileを指す場合moduleを共有する" {
    // `pkg:math` と `pkg:math/dup` はcanonical_idが異なるが、同一package内の
    // 同じ実体pathを指すため、moduleは一度だけ読み込む（exportごとの重複
    // 評価・plugin初期化の多重化を防ぐ）。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:math」を取り込む\n!「pkg:math/dup」を取り込む\n" },
        .{ .suffix = "packages/math/index.nako3", .source = "A=1\n" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expect(pathHasSuffix(graph.modules[1].path, "packages/math/index.nako3"));
    // 両edgeが同じmoduleを指し、それぞれの公開namespaceを保持する。
    const main_imports = graph.modules[graph.entry].imports;
    try std.testing.expectEqual(@as(usize, 2), main_imports.len);
    try std.testing.expectEqual(main_imports[0].target.?, main_imports[1].target.?);
    try std.testing.expectEqualStrings("math", main_imports[0].namespace.?);
    try std.testing.expectEqualStrings("dup", main_imports[1].namespace.?);
}

test "異なるpackageが同じ実体fileを指す場合moduleを共有しない" {
    // ownerが異なるpackage moduleはpathが一致しても共有しない（別packageの
    // moduleを借用するとpackage境界のsymbol分離が破れる）。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:math」を取り込む\n!「pkg:foreign-dup」を取り込む\n" },
        .{ .suffix = "packages/math/index.nako3", .source = "A=1\n" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    try std.testing.expectEqualStrings("pkg:math-id/main", graph.modules[1].canonical_id.?);
    try std.testing.expectEqualStrings("pkg:foreign-id/main", graph.modules[2].canonical_id.?);
}

test "export名にslashを含むpackageも独立したownerとrootで読み込む" {
    // canonical_id `pkg:deep-id/api/v1` はexport名 `api/v1` のslashを含む。
    // ownerをcanonical_idの末尾slashまでで逆算すると `pkg:deep-id/api`
    // という存在しないpackage keyになるため、ownerはresolverから独立した
    // フィールドとして伝播する必要がある。子孫のpackage境界もこのowner/
    // root（packages/deep）で評価する。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:deep」を取り込む\n" },
        .{ .suffix = "packages/deep/api/v1.nako3", .source = "!「../shared.nako3」を取り込む\n値=1\n" },
        .{ .suffix = "packages/deep/shared.nako3", .source = "S=2\n" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    const export_module = graph.modules[1];
    try std.testing.expectEqualStrings("pkg:deep-id/api/v1", export_module.canonical_id.?);
    try std.testing.expectEqualStrings("pkg:deep-id", export_module.package_owner.?);
    try std.testing.expect(pathHasSuffix(export_module.package_root.?, "packages/deep"));
    const descendant = graph.modules[2];
    try std.testing.expect(pathHasSuffix(descendant.path, "packages/deep/shared.nako3"));
    try std.testing.expectEqualStrings("pkg:deep-id", descendant.package_owner.?);
    try std.testing.expectEqualStrings(export_module.package_root.?, descendant.package_root.?);
}

test "package resolver未設定ではpackage specifierを拒否する" {
    var memory = MemoryProvider{ .files = &.{.{ .suffix = "main.nako3", .source = "!「パッケージ:missing」を取り込む\n" }} };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.len);
    try std.testing.expect(std.mem.indexOf(u8, graph.diagnostics[0].message, "パッケージ参照") != null);
}

const TestLocalPackageResolver = struct {
    fn resolver(self: *TestLocalPackageResolver) PackageResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !ResolvedPackageImport {
        if (!std.mem.eql(u8, specifier, "パッケージ:lib")) return error.PackageNotFound;
        return .{
            .path = try std.fs.path.resolve(allocator, &.{"lib/index.nako3"}),
            .canonical_id = try allocator.dupe(u8, "pkg:lib/main"),
            .namespace = "lib",
            .package_owner = try allocator.dupe(u8, "pkg:lib"),
        };
    }
};

test "package namespace aliasは取り込み順に関係なく同名local moduleより優先する" {
    const import_orders = [_][]const u8{
        "!「lib/util.nako3」を取り込む\n!「pkg:util」を取り込む\nutil__値を表示\n",
        "!「pkg:util」を取り込む\n!「lib/util.nako3」を取り込む\nutil__値を表示\n",
    };
    for (import_orders) |main_source| {
        var memory = MemoryProvider{ .files = &.{
            .{ .suffix = "main.nako3", .source = main_source },
            .{ .suffix = "lib/util.nako3", .source = "値=1\n" },
            .{ .suffix = "packages/util/index.nako3", .source = "値=2\n" },
        } };
        var package_resolver = PackageTestResolver{};
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
        defer graph.deinit();
        try std.testing.expect(graph.succeeded());
        const package_module = if (std.mem.eql(u8, graph.modules[1].canonical_id orelse "", "pkg:util-id/main")) graph.modules[1] else graph.modules[2];
        var program = try graph.analyze(std.testing.allocator);
        defer program.deinit();
        try std.testing.expect(program.succeeded());
        var found_package_binding = false;
        for (program.bindings) |binding| {
            if (!std.mem.eql(u8, binding.name, "util__値")) continue;
            const symbol_id = binding.symbol orelse continue;
            found_package_binding = program.symbols[symbol_id].module_index == package_module.index;
            break;
        }
        try std.testing.expect(found_package_binding);
    }
}

test "canonical package exportは複数aliasから同じmoduleと状態を共有する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:math」を取り込む\n!「pkg:math-alt」を取り込む\nmath__値を表示\nmath_alt__値を表示\n" },
        .{ .suffix = "packages/math/index.nako3", .source = "値=1\n" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqual(graph.modules[0].imports[0].target, graph.modules[0].imports[1].target);
    try std.testing.expect(graph.modules[0].imports[0].effective != graph.modules[0].imports[1].effective);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var math_resolved: ?[]const u8 = null;
    var math_alt_resolved: ?[]const u8 = null;
    for (program.bindings) |binding| {
        if (std.mem.eql(u8, binding.name, "math__値")) math_resolved = binding.resolved_name;
        if (std.mem.eql(u8, binding.name, "math_alt__値")) math_alt_resolved = binding.resolved_name;
    }
    try std.testing.expect(math_resolved != null and math_alt_resolved != null);
    try std.testing.expectEqualStrings(math_resolved.?, math_alt_resolved.?);
}

test "package importは相対取り込み済みmoduleの名前を変えずloading中の循環辺を認識する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「other/index.nako3」を取り込む\n!「lib/index.nako3」を取り込む\n!「パッケージ:lib」を取り込む\nlib__値を表示。\n" },
        .{ .suffix = "other/index.nako3", .source = "値=20\n" },
        .{ .suffix = "lib/index.nako3", .source = "!「パッケージ:lib」を取り込む\n値=7\n" },
    } };
    var package_resolver = TestLocalPackageResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    // ownerスコープ別のmodule共有: 相対importの`lib/index.nako3`（owner無し）と
    // `パッケージ:lib`が解決するmodule（owner=pkg:lib）は同じpathでも別moduleになる。
    // 相対側の`パッケージ:lib`辺は循環せずpackage側moduleを指し、
    // package側moduleの自己参照だけが循環辺になる。
    try std.testing.expectEqual(@as(usize, 4), graph.modules.len);
    const other_module = graph.modules[1];
    const local_module = graph.modules[2];
    const package_module = graph.modules[3];
    try std.testing.expectEqualStrings("index", other_module.name);
    try std.testing.expectEqualStrings("index", local_module.name);
    try std.testing.expect(local_module.canonical_id == null);
    try std.testing.expect(local_module.package_owner == null);
    try std.testing.expectEqualStrings("pkg:lib", package_module.package_owner.?);
    try std.testing.expectEqual(@as(usize, 1), local_module.imports.len);
    try std.testing.expect(!local_module.imports[0].cyclic);
    try std.testing.expectEqual(@as(u32, package_module.index), local_module.imports[0].target.?);
    try std.testing.expectEqual(@as(u32, package_module.index), graph.modules[0].imports[2].target.?);
    try std.testing.expect(package_module.imports[0].cyclic);
    try std.testing.expectEqual(@as(u32, package_module.index), package_module.imports[0].target.?);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var resolved_package_alias = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "lib__値")) continue;
        const symbol_id = binding.symbol orelse continue;
        const symbol = program.symbols[symbol_id];
        if (std.mem.startsWith(u8, symbol.qualified_name, "package__") and
            std.mem.endsWith(u8, symbol.qualified_name, "__値") and symbol.module_index == package_module.index) resolved_package_alias = true;
    }
    try std.testing.expect(resolved_package_alias);
}

test "package import後の相対importはファイル名namespaceを維持する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「パッケージ:lib」を取り込む\n!「lib/index.nako3」を取り込む\nindex__値を表示。\n" },
        .{ .suffix = "lib/index.nako3", .source = "値=7\n" },
    } };
    var package_resolver = TestLocalPackageResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    // package所有moduleと同じpathでもowner無しの相対importは別moduleとして
    // local scopeに読み込まれ、ファイル名namespaceを維持する。
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    const package_module = graph.modules[1];
    const local_module = graph.modules[2];
    try std.testing.expectEqualStrings("lib", package_module.name);
    try std.testing.expectEqualStrings("pkg:lib", package_module.package_owner.?);
    try std.testing.expect(local_module.package_owner == null);
    try std.testing.expectEqual(@as(usize, 2), graph.modules[0].imports.len);
    try std.testing.expectEqualStrings("lib", graph.modules[0].imports[0].namespace.?);
    try std.testing.expectEqualStrings("index", graph.modules[0].imports[1].namespace.?);
    try std.testing.expectEqual(@as(u32, local_module.index), graph.modules[0].imports[1].target.?);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var found_binding = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "index__値")) continue;
        const symbol_id = binding.symbol orelse continue;
        const symbol = program.symbols[symbol_id];
        found_binding = std.mem.eql(u8, binding.resolved_name, symbol.qualified_name) and
            std.mem.startsWith(u8, symbol.qualified_name, "index__") and symbol.module_index == local_module.index;
    }
    try std.testing.expect(found_binding);
}

test "package内の相対import先は所有packageを引き継ぎ修飾名で外部へ漏れない" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:math」を取り込む\nhelper__内部値を表示\n" },
        .{ .suffix = "packages/math/index.nako3", .source = "!「./helper.nako3」を取り込む\n●報告とは\nhelper__内部値を表示\nここまで\n" },
        .{ .suffix = "packages/math/helper.nako3", .source = "内部値=7\n" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    const index_module = graph.modules[1];
    const helper_module = graph.modules[2];
    try std.testing.expectEqualStrings("pkg:math-id", index_module.package_owner.?);
    try std.testing.expect(index_module.package_root != null);
    // helperはcanonical exportではないが、package root内の相対子孫として
    // 不透明なownerを引き継ぐ。
    try std.testing.expect(helper_module.canonical_id == null);
    try std.testing.expectEqualStrings(index_module.package_owner.?, helper_module.package_owner.?);
    try std.testing.expectEqualStrings(index_module.package_root.?, helper_module.package_root.?);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    // mainの `helper__内部値` はpackage所有moduleのシンボルへ解決されず、
    // main自身のモジュール変数として新規宣言される。package index側の正当な
    // 参照は引き続きhelperのシンボルへ解決される。
    var main_declared = false;
    var index_resolved_to_helper = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "helper__内部値")) continue;
        const symbol_id = binding.symbol orelse continue;
        const symbol = program.symbols[symbol_id];
        if (symbol.module_index == helper_module.index) {
            index_resolved_to_helper = true;
        } else {
            main_declared = true;
        }
    }
    try std.testing.expect(main_declared);
    try std.testing.expect(index_resolved_to_helper);
}

test "package内helperの修飾名は無関係なpackageからも解決されない" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:math」を取り込む\n!「pkg:util」を取り込む\n" },
        .{ .suffix = "packages/math/index.nako3", .source = "!「./helper.nako3」を取り込む\n●入口とは\nhelper__内部処理()\nここまで\n" },
        .{ .suffix = "packages/math/helper.nako3", .source = "●内部処理とは\nここまで\n" },
        .{ .suffix = "packages/util/index.nako3", .source = "helper__内部処理()\n" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 4), graph.modules.len);
    const helper_module = graph.modules[2];
    const util_module = graph.modules[3];

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    // math所有のhelperはmath indexの参照には解決されるが、無関係なutil
    // packageのindexからは解決されずutilスコープの新規宣言に落ちる。
    var math_resolved_to_helper = false;
    var util_declared_own = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "helper__内部処理")) continue;
        const symbol_id = binding.symbol orelse continue;
        const symbol = program.symbols[symbol_id];
        if (symbol.module_index == helper_module.index) {
            math_resolved_to_helper = true;
        } else if (symbol.module_index == util_module.index) {
            util_declared_own = true;
        }
    }
    try std.testing.expect(math_resolved_to_helper);
    try std.testing.expect(util_declared_own);
}

test "packageより先に相対importされたhelperはowner無しのまま直接参照を維持する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「packages/math/helper.nako3」を取り込む\n!「pkg:math」を取り込む\nhelper__内部値を表示\n" },
        .{ .suffix = "packages/math/helper.nako3", .source = "内部値=7\n" },
        .{ .suffix = "packages/math/index.nako3", .source = "!「./helper.nako3」を取り込む\n" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    // 同じ実体fileでもowner scopeが異なればmoduleは共有しない。先にlocal
    // moduleとして読み込まれたhelperはowner無しのまま残り、package indexの
    // 相対importはpackage所有の別moduleとして読み込まれる（順序非依存）。
    try std.testing.expectEqual(@as(usize, 4), graph.modules.len);
    const local_helper = graph.modules[1];
    const index_module = graph.modules[2];
    const package_helper = graph.modules[3];
    try std.testing.expect(local_helper.canonical_id == null);
    try std.testing.expect(local_helper.package_owner == null);
    try std.testing.expectEqualStrings("pkg:math-id", index_module.package_owner.?);
    try std.testing.expectEqualStrings("pkg:math-id", package_helper.package_owner.?);
    try std.testing.expectEqualStrings(local_helper.path, package_helper.path);
    try std.testing.expectEqual(@as(u32, package_helper.index), index_module.imports[0].target.?);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    // mainの暗黙alias `helper__` 経由の参照はlocal側moduleへ解決される。
    var resolved_to_helper = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "helper__内部値")) continue;
        const symbol_id = binding.symbol orelse continue;
        if (program.symbols[symbol_id].module_index == local_helper.index) resolved_to_helper = true;
    }
    try std.testing.expect(resolved_to_helper);
}

test "package所有moduleからroot外への相対・絶対importは診断され読み込まれない" {
    for ([_][]const u8{
        "!「../outside.nako3」を取り込む\n",
        "!「/packages/outside.nako3」を取り込む\n",
    }) |escaping_source| {
        var memory = MemoryProvider{
            .files = &.{
                .{ .suffix = "main.nako3", .source = "!「pkg:math」を取り込む\n" },
                .{ .suffix = "packages/math/index.nako3", .source = escaping_source },
                // 境界外のfileは存在しても読み込んではいけない。
                .{ .suffix = "packages/outside.nako3", .source = "秘密値=7\n" },
            },
        };
        var package_resolver = PackageTestResolver{};
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
        defer graph.deinit();
        try std.testing.expect(!graph.succeeded());
        // 境界外fileはmodule graphへ追加されない。
        try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
        var reported_escape = false;
        for (graph.diagnostics) |item| {
            if (std.mem.indexOf(u8, item.message, "package rootの外") != null) reported_escape = true;
        }
        try std.testing.expect(reported_escape);
    }
}

test "package内symlink経由のroot外importは診断され読み込まれない" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "packages/math");
    try temporary.dir.createDirPath(io, "packages/sibling");
    try temporary.dir.writeFile(io, .{ .sub_path = "main.nako3", .data = "!「pkg:math」を取り込む\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "packages/math/index.nako3", .data = "!「./link/secret.nako3」を取り込む\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "packages/sibling/secret.nako3", .data = "秘密値=7\n" });
    temporary.dir.symLink(io, "../sibling", "packages/math/link", .{ .is_directory = true }) catch return error.SkipZigTest;
    const root = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const TestResolver = struct {
        root_path: []const u8,
        fn resolve(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !ResolvedPackageImport {
            const self: *const @This() = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, specifier, "pkg:math")) return error.PackageNotFound;
            return .{
                .path = try std.fs.path.join(allocator, &.{ self.root_path, "packages/math/index.nako3" }),
                .canonical_id = try allocator.dupe(u8, "pkg:math-id/main"),
                .namespace = "math",
                .package_root = try std.fs.path.join(allocator, &.{ self.root_path, "packages/math" }),
                .package_owner = try allocator.dupe(u8, "pkg:math-id"),
            };
        }
    };
    const test_resolver = TestResolver{ .root_path = root };
    const package_resolver = PackageResolver{ .context = @constCast(&test_resolver), .resolveFn = TestResolver.resolve };
    var provider = module_graph.FileProvider{ .io = io };
    const entry = try std.fs.path.join(std.testing.allocator, &.{ root, "main.nako3" });
    defer std.testing.allocator.free(entry);
    var graph = try load(std.testing.allocator, entry, provider.sourceProvider(), .{ .package_resolver = package_resolver });
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    // symlink 経由で root 外を指す target は module graphへ追加されない。
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    var reported_escape = false;
    for (graph.diagnostics) |item| {
        if (std.mem.indexOf(u8, item.message, "package rootの外") != null) reported_escape = true;
    }
    try std.testing.expect(reported_escape);
}

test "合成されたlocal module名は自然なbasenameとも衝突しない" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「one/lib.nako3」を取り込む\n!「two/lib.nako3」を取り込む\n!「lib__lnako_local_1.nako3」を取り込む\n" },
        .{ .suffix = "one/lib.nako3", .source = "値=1\n" },
        .{ .suffix = "two/lib.nako3", .source = "値=2\n" },
        .{ .suffix = "lib__lnako_local_1.nako3", .source = "値=3\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    for (program.modules, 0..) |module, index| {
        for (program.modules[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, module.name, other.name));
        }
    }
}

test "同名index.nako3を持つ2 packageを別moduleとして同時取り込める" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「パッケージ:math」を取り込む\n!「パッケージ:geometry」を取り込む\n" },
        .{ .suffix = "packages/math/index.nako3", .source = "●MathValueとは\n  1で戻る\nここまで\n" },
        .{ .suffix = "packages/geometry/index.nako3", .source = "●GeometryValueとは\n  2で戻る\nここまで\n" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    try std.testing.expect(!std.mem.eql(u8, graph.modules[1].path, graph.modules[2].path));
    try std.testing.expect(pathHasSuffix(graph.modules[1].path, "packages/math/index.nako3"));
    try std.testing.expect(pathHasSuffix(graph.modules[2].path, "packages/geometry/index.nako3"));
    try std.testing.expectEqualStrings("math", graph.modules[1].name);
    try std.testing.expectEqualStrings("geometry", graph.modules[2].name);
    try std.testing.expectEqualStrings("pkg:math-id/main", graph.modules[1].canonical_id.?);
    try std.testing.expectEqualStrings("pkg:geometry-id/main", graph.modules[2].canonical_id.?);
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
}

fn checkInvalidModuleCleanup(allocator: std.mem.Allocator, imported: bool) !void {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「invalid.nako3」を取り込む\n!「invalid.nako3」を取り込む\n" },
        .{ .suffix = "invalid.nako3", .source = "\xff\xff\xff" },
    } };
    var graph = load(allocator, if (imported) "main.nako3" else "invalid.nako3", memory.sourceProvider(), .{}) catch |err| {
        if (err == error.InvalidUtf8 and !imported) return;
        return err;
    };
    defer graph.deinit();
    try std.testing.expect(imported);
    try std.testing.expect(!graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expect(graph.modules[1].parsed == null);
}

test "不正UTF8のentryと取り込み先を一度だけ解放する" {
    try checkInvalidModuleCleanup(std.testing.allocator, false);
    try checkInvalidModuleCleanup(std.testing.allocator, true);
}

test "モジュール読込み失敗の全割り当て境界で所有権を保持する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInvalidModuleCleanup, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInvalidModuleCleanup, .{true});
}

test "相対取り込みを再帰ロードし重複と循環を抑止する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「./lib.nako3」を取り込む\n!「lib.nako3」を取り込む\n3を二倍して表示\n" },
        .{ .suffix = "lib.nako3", .source = "!「./cycle.nako3」を取り込む\n●(Aを)二倍とは\nA*2で戻る\nここまで\n" },
        .{ .suffix = "cycle.nako3", .source = "!「./lib.nako3」を取り込む\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    try std.testing.expectEqual(graph.modules[0].imports[0].target, graph.modules[0].imports[1].target);
    try std.testing.expect(graph.modules[2].imports[0].cyclic);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(program.findSymbol("lib__二倍") != null);
}

test "JS取り込みは互換モードを必須にする" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「plugin.mjs」を取り込む\n" },
        .{ .suffix = "plugin.mjs", .source = "export default {}" },
    } };
    var rejected = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer rejected.deinit();
    try std.testing.expect(!rejected.succeeded());
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true });
    defer graph.deinit();
    try std.testing.expectEqual(ModuleKind.javascript, graph.modules[1].kind);
}

test "JavaScriptの相対依存を再帰ロードする" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「plugin.mjs」を取り込む\n" },
        .{ .suffix = "plugin.mjs", .source = "import { value } from './helper.mjs'; export default { value };" },
        .{ .suffix = "helper.mjs", .source = "export const value = 1;" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    try std.testing.expectEqual(ModuleKind.javascript, graph.modules[1].kind);
    try std.testing.expectEqual(@as(usize, 1), graph.modules[1].imports.len);
    try std.testing.expectEqual(@as(?u32, 2), graph.modules[1].imports[0].target);
    try std.testing.expectEqualStrings("./helper.mjs", graph.modules[1].imports[0].requested);
}

test "package内JSのリテラル動的importを収集しpackage所有を継承する" {
    // `import("./extra.mjs")` は静的宣言ではないため以前は収集されず、
    // package root外への相対指定が境界検査をすり抜けていた。リテラル指定は
    // 収集して通常のrelative importと同じくpackage境界で検査する。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
        .{ .suffix = "packages/esm/plugin.mjs", .source = "export default async () => (await import('./extra.mjs')).value;" },
        .{ .suffix = "packages/esm/extra.mjs", .source = "export const value = 1;" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    const plugin = graph.modules[1];
    try std.testing.expectEqual(ModuleKind.javascript, plugin.kind);
    try std.testing.expectEqual(@as(usize, 1), plugin.imports.len);
    try std.testing.expectEqualStrings("./extra.mjs", plugin.imports[0].requested);
    try std.testing.expectEqual(@as(?u32, 2), plugin.imports[0].target);
    // 動的importの子孫もpackage所有（owner/root）を継承する
    const descendant = graph.modules[2];
    try std.testing.expectEqualStrings("pkg:esm-id", descendant.package_owner.?);
    try std.testing.expectEqualStrings(plugin.package_root.?, descendant.package_root.?);
}

test "package内JSのリテラル動的importがpackage root外を指す場合は拒否する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
        .{ .suffix = "packages/esm/plugin.mjs", .source = "export default async () => (await import('../outside.mjs')).value;" },
        .{ .suffix = "packages/outside.mjs", .source = "export const value = 1;" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    var reported = false;
    for (graph.diagnostics) |item| {
        if (std.mem.indexOf(u8, item.message, "package rootの外") != null) reported = true;
    }
    try std.testing.expect(reported);
}

test "package内JSの非リテラル動的importは拒否し直接importでは許容する" {
    // package所有moduleでは `import(expr)` の解決先が静的に定まらず
    // QuickJS loaderのFS fallbackがroot外を読み得るため明示的に拒否する。
    var package_memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
        .{ .suffix = "packages/esm/plugin.mjs", .source = "export default async (name) => import(name);" },
    } };
    var package_resolver = PackageTestResolver{};
    var rejected = try load(std.testing.allocator, "main.nako3", package_memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
    defer rejected.deinit();
    try std.testing.expect(!rejected.succeeded());
    var reported = false;
    for (rejected.diagnostics) |item| {
        if (std.mem.indexOf(u8, item.message, "静的に解決できない") != null) reported = true;
    }
    try std.testing.expect(reported);

    // 直接path取り込みの非package moduleでは従来挙動を維持する。
    var direct_memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「plugin.mjs」を取り込む\n" },
        .{ .suffix = "plugin.mjs", .source = "export default async (name) => import(name);" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", direct_memory.sourceProvider(), .{ .compat_js = true });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
}

test "package内JSの部分リテラル動的importは誤った辺を記録せず拒否する" {
    // `import("./ok.mjs" + name)` の先頭リテラルを記録すると、graphは
    // `./ok.mjs` の辺を作り境界検査を通過するが、実行時の実指定は別値に
    // なりpackage root外を読み得る。リテラルの次が `)`/`,` でない場合は
    // 収集せずopaqueとして拒否する。
    const opaque_sources = [_][]const u8{
        "export default async (name) => import('./ok.mjs' + name);",
        "export default async () => import('./ok.mjs' './also.mjs');",
        "export default async () => import();",
        "export default async () => import('./ok.mjs'",
        "export default async () => import(`./ok.mjs`);",
    };
    for (opaque_sources) |plugin_source| {
        var memory = MemoryProvider{ .files = &.{
            .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
            .{ .suffix = "packages/esm/plugin.mjs", .source = plugin_source },
            .{ .suffix = "packages/esm/ok.mjs", .source = "export const value = 1;" },
        } };
        var package_resolver = PackageTestResolver{};
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
        defer graph.deinit();
        try std.testing.expect(!graph.succeeded());
        // 先頭リテラルがedgeとして誤記録されていないことも確認する
        try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
        try std.testing.expectEqual(@as(usize, 0), graph.modules[1].imports.len);
        var reported = false;
        for (graph.diagnostics) |item| {
            if (std.mem.indexOf(u8, item.message, "静的に解決できない") != null) reported = true;
        }
        try std.testing.expect(reported);
    }
}

test "package内JSの動的importは第二引数付きリテラルを受理する" {
    // `import("./x.mjs", { with: {...} })` の第二引数はoptions objectであり
    // specifierには影響しない。`,` で閉じるリテラルは収集・境界検査の対象にする。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
        .{ .suffix = "packages/esm/plugin.mjs", .source = "export default async () => (await import('./extra.mjs', { with: { type: 'js' } })).value;" },
        .{ .suffix = "packages/esm/extra.mjs", .source = "export const value = 1;" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 1), graph.modules[1].imports.len);
    try std.testing.expectEqualStrings("./extra.mjs", graph.modules[1].imports[0].requested);
}

test "直接importのJSの部分リテラル動的importは収集を諦めても失敗しない" {
    // 非package moduleでは動的importの非リテラルformは従来挙動（収集せず
    // QuickJS側の解決へ委譲）を維持する。先頭リテラルの誤記録だけは防ぐ。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「plugin.mjs」を取り込む\n" },
        .{ .suffix = "plugin.mjs", .source = "export default async (name) => import('./ok.mjs' + name);" },
        .{ .suffix = "ok.mjs", .source = "export const value = 1;" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 0), graph.modules[1].imports.len);
}

test "package内JSのtemplate literal補間内の動的importもpackage境界で検査する" {
    // tokenizerがtemplate literalをtextごとskipすると `${...}` 内の式まで
    // 見えなくなり、`` `${await import('../outside.mjs')}` `` のimportが
    // graphへ記録されず実行時のFS fallbackがroot外を読み得た。補間内の式は
    // token化して通常の動的importとして収集・検査する。
    var escaped = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
        .{ .suffix = "packages/esm/plugin.mjs", .source = "export default async () => `${await import('../outside.mjs')}`;" },
        .{ .suffix = "packages/outside.mjs", .source = "export const value = 1;" },
    } };
    var package_resolver = PackageTestResolver{};
    var rejected = try load(std.testing.allocator, "main.nako3", escaped.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
    defer rejected.deinit();
    try std.testing.expect(!rejected.succeeded());
    try std.testing.expectEqual(@as(usize, 2), rejected.modules.len);
    try std.testing.expectEqual(@as(usize, 0), rejected.modules[1].imports.len);
    var reported = false;
    for (rejected.diagnostics) |item| {
        if (std.mem.indexOf(u8, item.message, "package rootの外") != null) reported = true;
    }
    try std.testing.expect(reported);

    // 補間内のin-rootリテラルは通常どおり収集して辺を作る。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
        .{ .suffix = "packages/esm/plugin.mjs", .source = "export default async () => `outer${`nested${await import('./extra.mjs')}`}`;" },
        .{ .suffix = "packages/esm/extra.mjs", .source = "export const value = 1;" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 1), graph.modules[1].imports.len);
    try std.testing.expectEqualStrings("./extra.mjs", graph.modules[1].imports[0].requested);
}

test "package内JSのtemplate補間内の非リテラル動的importは拒否する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
        .{ .suffix = "packages/esm/plugin.mjs", .source = "export default async (name) => `${await import(name)}`;" },
    } };
    var package_resolver = PackageTestResolver{};
    var rejected = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
    defer rejected.deinit();
    try std.testing.expect(!rejected.succeeded());
    var reported = false;
    for (rejected.diagnostics) |item| {
        if (std.mem.indexOf(u8, item.message, "静的に解決できない") != null) reported = true;
    }
    try std.testing.expect(reported);
}

test "export式中の動的importも収集してpackage境界で検査する" {
    // `export const p = import('./x')` はexport文の走査が `import` tokenを
    // 消費し、その後の `(` で打ち切るため動的form全体が未検出だった。
    // object key `{import: 1}` の直後の `import()` も同様に呑まれる。
    // 式中の `import`/`export` は内側走査で巻き戻して外側loopへ返す。
    const escaping_sources = [_][]const u8{
        "export const p = import('../outside.mjs');",
        "export default await import('../outside.mjs');",
        "const o = {import: 1, f: () => import('../outside.mjs')}; export default o;",
    };
    for (escaping_sources) |plugin_source| {
        var memory = MemoryProvider{ .files = &.{
            .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
            .{ .suffix = "packages/esm/plugin.mjs", .source = plugin_source },
            .{ .suffix = "packages/outside.mjs", .source = "export const value = 1;" },
        } };
        var package_resolver = PackageTestResolver{};
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
        defer graph.deinit();
        try std.testing.expect(!graph.succeeded());
        // edgeが記録されて境界検査で止まっている（未収集のsilent missではない）
        try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
        var reported = false;
        for (graph.diagnostics) |item| {
            if (std.mem.indexOf(u8, item.message, "package rootの外") != null) reported = true;
        }
        try std.testing.expect(reported);
    }
}

test "escape列を含む取り込み指定は診断にしsilentな成功にしない" {
    // `import x from '\x2e\x2e/outside.mjs'` は復号しないと実pathが定まら
    // ない。以前はUnsupportedJavaScriptImportEscapeがnested loadの
    // `else => null` catchで黙殺され、診断なしの成功＋未検査のまま実行時
    // fallbackへ到達していた。escape列は所有の有無に関わらず診断する。
    const escaped_sources = [_][]const u8{
        "import x from '\\x2e\\x2e/outside.mjs'; export default x;",
        "export default async () => import('\\x2e\\x2e/outside.mjs');",
        "export * from '\\x2e\\x2e/outside.mjs';",
    };
    for (escaped_sources) |plugin_source| {
        var memory = MemoryProvider{ .files = &.{
            .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
            .{ .suffix = "packages/esm/plugin.mjs", .source = plugin_source },
            .{ .suffix = "packages/outside.mjs", .source = "export const value = 1;" },
        } };
        var package_resolver = PackageTestResolver{};
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
        defer graph.deinit();
        try std.testing.expect(!graph.succeeded());
        try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
        try std.testing.expectEqual(@as(usize, 0), graph.modules[1].imports.len);
        var reported = false;
        for (graph.diagnostics) |item| {
            if (std.mem.indexOf(u8, item.message, "escape列") != null) reported = true;
        }
        try std.testing.expect(reported);
    }

    // 直接path取り込みの非package moduleでも診断は同じく出る — nested load
    // で黙殺されていたため、これまでsilentな成功になり得た。
    var direct_memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「plugin.mjs」を取り込む\n" },
        .{ .suffix = "plugin.mjs", .source = "import x from '\\x2e\\x2e/outside.mjs'; export default x;" },
        .{ .suffix = "outside.mjs", .source = "export const value = 1;" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", direct_memory.sourceProvider(), .{ .compat_js = true });
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    var reported = false;
    for (graph.diagnostics) |item| {
        if (std.mem.indexOf(u8, item.message, "escape列") != null) reported = true;
    }
    try std.testing.expect(reported);
}

test "多数のnamed bindingを持つ静的importでもspecifierを収集する" {
    // 以前の内側走査は256tokenで打ち切るため、多数のnamed bindingを持つ
    // `import {…} from '../x'` のspecifierが未走査のままsilentに消え、
    // package境界検査がすり抜けていた。上限は撤廃し、走査不能な場合のみ
    // fail-closedで報告する。
    const many_bindings = comptime blk: {
        @setEvalBranchQuota(200_000);
        var out: []const u8 = "import {";
        for (0..160) |i| out = out ++ std.fmt.comptimePrint("n{d} as m{d},", .{ i, i });
        break :blk out ++ "z} from '../outside.mjs'; export default null;";
    };
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
        .{ .suffix = "packages/esm/plugin.mjs", .source = many_bindings },
        .{ .suffix = "packages/outside.mjs", .source = "export const value = 1;" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    var reported = false;
    for (graph.diagnostics) |item| {
        if (std.mem.indexOf(u8, item.message, "package rootの外") != null) reported = true;
    }
    try std.testing.expect(reported);
}

test "未終了のtemplate literalは収集不能なimportを残し得るためpackage内で拒否する" {
    // `` `abc${expr `` のようにsource終端まで閉じないtemplate/
    // interpolationは残りを未走査にする。閉じ欠落をsilentに成功扱いすると
    // その先のimportが一切記録されないため、opaqueとして報告する。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
        .{ .suffix = "packages/esm/plugin.mjs", .source = "export default `abc${value" },
    } };
    var package_resolver = PackageTestResolver{};
    var rejected = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
    defer rejected.deinit();
    try std.testing.expect(!rejected.succeeded());
    var reported = false;
    for (rejected.diagnostics) |item| {
        if (std.mem.indexOf(u8, item.message, "静的に解決できない") != null) reported = true;
    }
    try std.testing.expect(reported);
}

test "obj.importメンバ呼出しとimport.metaは取り込みとして扱わない" {
    // `o.import('./x')` はメンバ呼出しであってmoduleを読み込まない。
    // `import` と誤認するとphantomなedgeやpackage codeの誤拒否になる。
    // `import.meta` も同様にspecifierを持たない。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
        .{ .suffix = "packages/esm/plugin.mjs", .source = "const o = {import: (s) => s}; export const v = o.import('./missing.mjs'); export const u = import.meta.url;" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 0), graph.modules[1].imports.len);
}

test "export式内のtemplate補間importはrewind後も文脈を維持して収集する" {
    // 文内側の走査が `import`/`export` でindexだけ巻き戻すと、その `next`
    // 呼出し内で行われた文脈遷移（`${` push・`}` pop・template text消費）
    // が残り、文脈stackが読み位置と不整合になる — `${import('./x')}` で
    // pushが残ってEOFでtruncated扱いされたり、ASI区切りの後続import文が
    // template textとして丸ごと呑まれたりしていた。以下はいずれも
    // 「収集できてopaqueにしない」べき形。
    const sources = [_][]const u8{
        // template補間内のimport — 辺を記録しopaqueにしない
        "export const x = `${import('./extra.mjs')}`;",
        // 補間内のimport.meta — 辺を作らずopaqueにしない
        "export const u = `${import.meta.url}`;",
        // ASI: `export default `...`` の後に `;` なしで続くimport文
        "export default `${x}`\nimport { v } from './extra.mjs';",
        // template直後のASIでも同一
        "export default `${x}`;\nimport { v } from './extra.mjs';",
    };
    const expected_edges = [_]usize{ 1, 0, 1, 1 };
    for (sources, expected_edges) |plugin_source, edge_count| {
        var memory = MemoryProvider{ .files = &.{
            .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
            .{ .suffix = "packages/esm/plugin.mjs", .source = plugin_source },
            .{ .suffix = "packages/esm/extra.mjs", .source = "export const v = 1;" },
        } };
        var package_resolver = PackageTestResolver{};
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
        defer graph.deinit();
        try std.testing.expect(graph.succeeded());
        try std.testing.expectEqual(@as(usize, 2 + edge_count), graph.modules.len);
        try std.testing.expectEqual(edge_count, graph.modules[1].imports.len);
    }
}

test "regex literal内の記号で文脈が崩れず後続のimportを収集する" {
    // `/}`・`/['"`}]/` のように `}`・quote・backtickを含むregex literalは
    // token化すると文脈stackや文字列走査を崩す。operand直後でない `/` は
    // regexとして一括skipし、中身に含まれるimportらしき文字列も拾わない。
    const sources = [_][]const u8{
        // 補間式内のregex引数 — `/}/g` の `}` が文脈を壊さないこと
        "export default async () => `${s.replace(/}/g, await import('./extra.mjs'))}`;",
        // statement位置のregexと後続import — regex中の `` ` `` が後続を呑まないこと
        "const re = /[\"'`}]/g;\nexport default () => import('./extra.mjs');",
        // 除算とregexの混在 — `a / b / c` は除算として透過すること
        "const d = a / b / c; const re = /x{2}/g; export default () => import('./extra.mjs');",
        // 閉じたtemplate literalはoperand — 直後の `/` は除算
        "const t = `x` / import('./extra.mjs') / y;",
        // regex token自体もoperand — 直後の `/` は除算
        "const r = /re/ / import('./extra.mjs') / y;",
        // 補閂式の先頭はregexが来得る — `` ` `` を含むregexがnested template
        // と誤認されて残り全体を呑まないこと
        "const v = `${/`/}`; const w = import('./extra.mjs');",
        // 補閂を閉じたtemplateもoperand — 直後の `/` は除算
        "const u = `${x}` / import('./extra.mjs') / y;",
    };
    for (sources) |plugin_source| {
        var memory = MemoryProvider{ .files = &.{
            .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
            .{ .suffix = "packages/esm/plugin.mjs", .source = plugin_source },
            .{ .suffix = "packages/esm/extra.mjs", .source = "export const v = 1;" },
        } };
        var package_resolver = PackageTestResolver{};
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
        defer graph.deinit();
        try std.testing.expect(graph.succeeded());
        try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
        try std.testing.expectEqual(@as(usize, 1), graph.modules[1].imports.len);
        try std.testing.expectEqualStrings("./extra.mjs", graph.modules[1].imports[0].requested);
    }
}

test "export default regexはキーワード位置として解釈し誤って文脈を崩さない" {
    // `export default /re/g` は有効なES文法 — `default` がキーワード表に
    // 無いと `/` が除算扱いになり、regex中身がtoken化されて文脈を崩す
    // （`"`/`}`/`` ` `` を含むとtruncated→package moduleの誤拒否）。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:esm」を取り込む\n" },
        .{ .suffix = "packages/esm/plugin.mjs", .source = "export default /[\"'}`]/g;" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true, .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 0), graph.modules[1].imports.len);
}

test "ネイティブプラグインをソース読込なしで登録する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「plugin.so」を取り込む\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqual(ModuleKind.native_plugin, graph.modules[1].kind);
    try std.testing.expectEqual(@as(usize, 0), graph.modules[1].source.len);
}

test "ネイティブプラグイン命令を厳格モードでも動的解決する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!厳しくチェック\n!「plugin.so」を取り込む\n外部追加()\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var found = false;
    for (program.bindings) |binding| if (binding.kind == .builtin and std.mem.eql(u8, binding.name, "外部追加")) {
        found = true;
    };
    try std.testing.expect(found);
}

test "ネイティブプラグインを取り込んでも厳格モードの未知変数を警告にする" {
    // 公式`!厳しくチェック`は未知変数を`logger.warn`で警告するだけで、
    // コンパイルと実行を継続する（終了0・`undefined`表示）。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!厳しくチェック\n!「plugin.so」を取り込む\n未知値を表示\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var found = false;
    for (program.diagnostics) |item| if (item.code == .undefined_symbol) {
        try std.testing.expectEqual(@import("../frontend/diagnostic.zig").Severity.warning, item.severity);
        found = true;
    };
    try std.testing.expect(found);
}

test "ネイティブ化した公式JavaScriptプラグインは通常モードで取り込む" {
    const cases = [_][]const u8{
        "!「plugin_httpserver.mjs」を取り込む\n",
        "!「plugin_markup.js」を取り込む\n",
        "!「plugin_caniuse.mjs」を取り込む\n",
        "!「plugin_kansuji.js」を取り込む\n",
        "!「plugin_datetime.mjs」を取り込む\n",
    };
    for (cases) |source| {
        var memory = MemoryProvider{ .files = &.{.{ .suffix = "main.nako3", .source = source }} };
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
        defer graph.deinit();
        try std.testing.expect(graph.succeeded());
        try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
        try std.testing.expectEqual(ModuleKind.javascript, graph.modules[1].kind);
        try std.testing.expectEqual(@as(usize, 0), graph.modules[1].source.len);
    }
}

test "存在しない取り込みを位置付き診断にする" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「missing.nako3」を取り込む\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics[0].span.line);
}

test "関数内取り込みの展開で合成AST深さが上限を超えたら位置付き診断にする" {
    // `A=1+1+…`（2,044項）は単体では深さ2,046で受理されるが、関数内の
    // 取り込み位置へ展開すると合成深さが `parser.max_ast_depth` を超える。
    var lib_source: std.ArrayList(u8) = .empty;
    defer lib_source.deinit(std.testing.allocator);
    try lib_source.appendSlice(std.testing.allocator, "A=1");
    var index: usize = 0;
    while (index < 2043) : (index += 1) try lib_source.appendSlice(std.testing.allocator, "+1");
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "●(Aを)Fとは\n!「./lib.nako3」を取り込む\nAで戻る\nここまで\nF(1)を表示\n" },
        .{ .suffix = "lib.nako3", .source = lib_source.items },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    try std.testing.expect(graph.diagnostics.len >= 1);
    try std.testing.expectEqual(diagnostic.Code.nesting_too_deep, graph.diagnostics[0].code);
    // 診断は取り込み元ファイル内の関数内取り込み文（2行目）を指す。
    try std.testing.expect(std.mem.endsWith(u8, graph.diagnostics[0].file, "main.nako3"));
    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics[0].span.line);
}

test "関数内取り込みの展開連鎖で合成AST深さが上限を超えたら位置付き診断にする" {
    // main→mid→deep の取り込み連鎖。各ファイル単体は上限内だが、main側の
    // 関数内取り込み位置＋コピー内の取り込み文位置＋deepの深さの合計が
    // `parser.max_ast_depth` を超える。
    var deep_source: std.ArrayList(u8) = .empty;
    defer deep_source.deinit(std.testing.allocator);
    try deep_source.appendSlice(std.testing.allocator, "A=1");
    var index: usize = 0;
    while (index < 2042) : (index += 1) try deep_source.appendSlice(std.testing.allocator, "+1");
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "●(Aを)Fとは\n!「./mid.nako3」を取り込む\nBで戻る\nここまで\nF(1)を表示\n" },
        .{ .suffix = "mid.nako3", .source = "!「./deep.nako3」を取り込む\nB=2\n" },
        .{ .suffix = "deep.nako3", .source = deep_source.items },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    try std.testing.expect(graph.diagnostics.len >= 1);
    try std.testing.expectEqual(diagnostic.Code.nesting_too_deep, graph.diagnostics[0].code);
    // 診断はコピー元モジュール（mid）側の取り込み文（1行目）を指す。
    try std.testing.expect(std.mem.endsWith(u8, graph.diagnostics[0].file, "mid.nako3"));
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics[0].span.line);
}

test ".dncl/.dncl2拡張子でDNCL系モードを強制する" {
    var memory = MemoryProvider{
        .files = &.{
            // .dncl は DNCLモード(v1)。「を実行し、そうでなければ」が動くことを確認する
            .{ .suffix = "main.dncl", .source = "A←3\nもしA=3ならば\n|「ok」と表示\nを実行し、そうでなければ\n|「ng」と表示\nを実行する\n" },
            .{ .suffix = "main.dncl2", .source = "B=0\nもし(not 真)ならば:\n　B=1\nそうでなければ:\n　B=2\n" },
            .{ .suffix = "plain.nako3", .source = "A←3\n" },
        },
    };
    var dncl_graph = try load(std.testing.allocator, "main.dncl", memory.sourceProvider(), .{});
    defer dncl_graph.deinit();
    try std.testing.expect(dncl_graph.succeeded());
    var dncl2_graph = try load(std.testing.allocator, "main.dncl2", memory.sourceProvider(), .{});
    defer dncl2_graph.deinit();
    try std.testing.expect(dncl2_graph.succeeded());
    var plain_graph = try load(std.testing.allocator, "plain.nako3", memory.sourceProvider(), .{});
    defer plain_graph.deinit();
    try std.testing.expect(!plain_graph.succeeded());
}

test "エントリ拡張子と反対側のDNCL強制フラグは競合エラーにする" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.dncl", .source = "A←3\n" },
        .{ .suffix = "main.dncl2", .source = "B=0\n" },
    } };
    // .dncl+--dncl2 / .dncl2+--dncl は両方言の同時有効化になるため拒否する
    try std.testing.expectError(error.ConflictingDnclModes, load(std.testing.allocator, "main.dncl", memory.sourceProvider(), .{ .forced_mode = .{ .dncl2 = true } }));
    try std.testing.expectError(error.ConflictingDnclModes, load(std.testing.allocator, "main.dncl2", memory.sourceProvider(), .{ .forced_mode = .{ .dncl = true } }));
    // 同方向の組合せ（拡張子と同じ方言のフラグ）は引き続き受理する
    var same = try load(std.testing.allocator, "main.dncl", memory.sourceProvider(), .{ .forced_mode = .{ .dncl = true } });
    defer same.deinit();
    try std.testing.expect(same.succeeded());
    // 拡張子がないエントリへの強制フラグも従来通り受理する
    var forced = MemoryProvider{ .files = &.{.{ .suffix = "main.nako3", .source = "A←3\n" }} };
    var forced_graph = try load(std.testing.allocator, "main.nako3", forced.sourceProvider(), .{ .forced_mode = .{ .dncl2 = true } });
    defer forced_graph.deinit();
    try std.testing.expect(forced_graph.succeeded());
}

fn variantCount(graph: *const ModuleGraph, path: []const u8) usize {
    for (graph.modules) |module| {
        if (std.mem.endsWith(u8, module.path, path)) return module.variants.items.len;
    }
    return 0;
}

test "循環取り込みの再展開は文脈のモードで別パースした変体を生成する" {
    // モードを含まない通常の循環取り込みはコピーの解析モードが本体と
    // 一致するため変体を作らず共有本体で再展開する
    var matching = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "「M1」と表示\n!「./lib.nako3」を取り込む\n「M2」と表示\n" },
        .{ .suffix = "lib.nako3", .source = "「L1」と表示\n!「./main.nako3」を取り込む\n「L2」と表示\n" },
    } };
    var matching_graph = try load(std.testing.allocator, "main.nako3", matching.sourceProvider(), .{});
    defer matching_graph.deinit();
    try std.testing.expect(matching_graph.succeeded());
    try std.testing.expectEqual(@as(usize, 0), variantCount(&matching_graph, "main.nako3"));

    // 強制モードが開始から有効なエントリ(.dncl)へ、そのモードの位置から
    // 循環取り込みされる場合もコピーと本体の解析モードが一致する
    var dncl = MemoryProvider{ .files = &.{
        .{ .suffix = "main.dncl", .source = "「M1」と表示\n!「./lib.nako3」を取り込む\n「M2」と表示\n" },
        .{ .suffix = "lib.nako3", .source = "「L1」と表示\n!「./main.dncl」を取り込む\n「L2」と表示\n" },
    } };
    var dncl_graph = try load(std.testing.allocator, "main.dncl", dncl.sourceProvider(), .{});
    defer dncl_graph.deinit();
    try std.testing.expect(dncl_graph.succeeded());
    try std.testing.expectEqual(@as(usize, 0), variantCount(&dncl_graph, "main.dncl"));

    // 循環位置より後でモードが有効になる場合、コピーには取り込み展開が
    // 含まれないためtailモードが欠けた解析になる。Issue #73 では共有
    // 本体の代わりに文脈のモードで解析した変体を生成して受理する。
    var mismatching = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "A=[10,20]\n「M1」と表示\n!「./lib.nako3」を取り込む\n「M3:」&A[1]と表示\n" },
        .{ .suffix = "lib.nako3", .source = "「L1」と表示\n!「./main.nako3」を取り込む\n!DNCLモード\n「L2」と表示\n" },
    } };
    var mismatching_graph = try load(std.testing.allocator, "main.nako3", mismatching.sourceProvider(), .{});
    defer mismatching_graph.deinit();
    try std.testing.expect(mismatching_graph.succeeded());
    try std.testing.expectEqual(@as(usize, 1), variantCount(&mismatching_graph, "main.nako3"));

    // 循環取り込み位置のモードがエントリの解析開始モードと異なる場合は
    // コピーの先行文の意味づけが変わる。これも文脈のモードで解析した
    // 変体で表現する（#73）。
    var diverging_initial = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "A=[10,20]\n「M1:」&A[0]と表示\nDNCLモード\n!「./lib.nako3」を取り込む\n「M3:」&A[1]と表示\n" },
        .{ .suffix = "lib.nako3", .source = "「L1」と表示\nDNCLモード\n!「./main.nako3」を取り込む\n「L2」と表示\n" },
    } };
    var diverging_graph = try load(std.testing.allocator, "main.nako3", diverging_initial.sourceProvider(), .{});
    defer diverging_graph.deinit();
    try std.testing.expect(diverging_graph.succeeded());
    try std.testing.expectEqual(@as(usize, 1), variantCount(&diverging_graph, "main.nako3"));
}

test "エントリの.nako3へ--dncl/--dncl2相当のモードを強制する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "A←3\n" },
        .{ .suffix = "main2.nako3", .source = "B=0\nもし(not 真)ならば:\n　B=1\n" },
    } };
    var dncl_graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .forced_mode = .{ .dncl = true } });
    defer dncl_graph.deinit();
    try std.testing.expect(dncl_graph.succeeded());
    var dncl2_graph = try load(std.testing.allocator, "main2.nako3", memory.sourceProvider(), .{ .forced_mode = .{ .dncl2 = true } });
    defer dncl2_graph.deinit();
    try std.testing.expect(dncl2_graph.succeeded());
    // 強制モードはエントリのみで、取り込み先の.nako3へは波及しない
    var imported = MemoryProvider{ .files = &.{
        .{ .suffix = "entry.nako3", .source = "!「./lib.nako3」を取り込む\n" },
        .{ .suffix = "lib.nako3", .source = "A←3\n" },
    } };
    var imported_graph = try load(std.testing.allocator, "entry.nako3", imported.sourceProvider(), .{ .forced_mode = .{ .dncl = true } });
    defer imported_graph.deinit();
    try std.testing.expect(!imported_graph.succeeded());
}

test "『{非公開}』属性のモジュール変数を他モジュールの名前解決から隠す" {
    // 公式findVarはmodList検索で `isExport === false` のモジュール変数を
    // 除外する。`{公開}` と無属性は既定どおり公開される。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「lib.nako3」を取り込む\n秘密を表示\n公開値を表示\n既定値を表示\n" },
        .{ .suffix = "lib.nako3", .source = "変数 秘密{非公開}=1\n変数 公開値{公開}=2\n変数 既定値=3\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(!program.findSymbol("lib__秘密").?.is_export);
    try std.testing.expect(program.findSymbol("lib__公開値").?.is_export);
    try std.testing.expect(program.findSymbol("lib__既定値").?.is_export);

    var hidden_resolved = false;
    var public_resolved = false;
    var default_resolved = false;
    for (program.bindings) |binding| {
        if (binding.kind != .reference) continue;
        if (std.mem.eql(u8, binding.name, "秘密")) hidden_resolved = std.mem.eql(u8, binding.resolved_name, "main__秘密");
        if (std.mem.eql(u8, binding.name, "公開値")) public_resolved = std.mem.eql(u8, binding.resolved_name, "lib__公開値");
        if (std.mem.eql(u8, binding.name, "既定値")) default_resolved = std.mem.eql(u8, binding.resolved_name, "lib__既定値");
    }
    try std.testing.expect(hidden_resolved);
    try std.testing.expect(public_resolved);
    try std.testing.expect(default_resolved);
}

test "『!モジュール公開既定値』が取り込み先のモジュール変数の公開を決める" {
    // 公式yExportDefaultはモジュール単位の既定を作り、findVarのmodList検索が
    // `isExport===false` の変数を除外する。属性付きの宣言は常に優先する。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「lib.nako3」を取り込む\n秘密を表示\n公開値を表示\n一覧を表示\n" },
        .{ .suffix = "lib.nako3", .source = "!モジュール公開既定値=「非公開」\n変数 秘密=1\n変数 公開値{公開}=2\n変数 [一覧]=[7]\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(!program.findSymbol("lib__秘密").?.is_export);
    try std.testing.expect(program.findSymbol("lib__公開値").?.is_export);
    try std.testing.expect(!program.findSymbol("lib__一覧").?.is_export);
    for (program.bindings) |binding| {
        if (binding.kind != .reference) continue;
        if (std.mem.eql(u8, binding.name, "秘密")) try std.testing.expectEqualStrings("main__秘密", binding.resolved_name);
        if (std.mem.eql(u8, binding.name, "公開値")) try std.testing.expectEqualStrings("lib__公開値", binding.resolved_name);
        if (std.mem.eql(u8, binding.name, "一覧")) try std.testing.expectEqualStrings("main__一覧", binding.resolved_name);
    }
}

const NativePluginPackageResolver = struct {
    fn resolver(self: *NativePluginPackageResolver) PackageResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !ResolvedPackageImport {
        const reference = if (std.mem.startsWith(u8, specifier, "pkg:"))
            specifier["pkg:".len..]
        else
            return error.InvalidPackageSpecifier;
        if (!std.mem.eql(u8, reference, "nativepkg")) return error.PackageNotFound;
        const resolved_path = try std.fs.path.resolve(allocator, &.{"packages/nativepkg/plugin.so"});
        return .{
            .path = resolved_path,
            .canonical_id = try allocator.dupe(u8, "pkg:nativepkg/main"),
            .namespace = "nativepkg",
            .package_root = try allocator.dupe(u8, std.fs.path.dirname(resolved_path).?),
        };
    }
};

test "package経由のnative plugin命令は公開namespace修飾名のみ動的解決する" {
    // P1回帰: package経由のnative pluginは無修飾名をimport側のグローバル
    // 命令空間へ露出させない。`nativepkg__外部追加`のみ動的builtinに束縛し、
    // 無修飾の`外部追加`は未定義名（local宣言）へ落ちる。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:nativepkg」を取り込む\nnativepkg__外部追加(1, 2)\n外部追加(1, 2)\n" },
    } };
    var package_resolver = NativePluginPackageResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqual(module_graph.ModuleKind.native_plugin, graph.modules[1].kind);
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var qualified_dynamic = false;
    var unqualified_dynamic = false;
    for (program.bindings) |binding| {
        if (binding.kind == .builtin and binding.dynamic_builtin) {
            if (std.mem.eql(u8, binding.resolved_name, "nativepkg__外部追加")) qualified_dynamic = true;
            if (std.mem.eql(u8, binding.resolved_name, "外部追加")) unqualified_dynamic = true;
        }
    }
    try std.testing.expect(qualified_dynamic);
    try std.testing.expect(!unqualified_dynamic);
}

test "直接path取り込みのnative plugin命令は従来どおり無修飾で動的解決する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「plugin.so」を取り込む\n外部追加(1, 2)\n" },
        .{ .suffix = "plugin.so", .source = "" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(module_graph.ModuleKind.native_plugin, graph.modules[1].kind);
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var unqualified_dynamic = false;
    for (program.bindings) |binding| {
        if (binding.kind == .builtin and binding.dynamic_builtin and std.mem.eql(u8, binding.resolved_name, "外部追加")) unqualified_dynamic = true;
    }
    try std.testing.expect(unqualified_dynamic);
}

test "plugin命令の動的解決はimport文より前の呼出しには適用しない" {
    // P2回帰: 取り込み文より前の `外部追加(...)` はpluginを導入したimportが
    // まだ存在しない時点の呼出しであり、preinstalled pluginや将来の同名
    // builtinへ誤配送してはいけない。alias/直接importともにimport位置で
    // ゲートする（NamespaceAliasの位置規則と同じ）。
    var before_memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "外部追加(1, 2)\n!「plugin.so」を取り込む\n" },
        .{ .suffix = "plugin.so", .source = "" },
    } };
    var before_graph = try load(std.testing.allocator, "main.nako3", before_memory.sourceProvider(), .{});
    defer before_graph.deinit();
    var before_program = try before_graph.analyze(std.testing.allocator);
    defer before_program.deinit();
    var pre_import_dynamic = false;
    for (before_program.bindings) |binding| {
        if (binding.kind == .builtin and binding.dynamic_builtin and std.mem.eql(u8, binding.resolved_name, "外部追加")) pre_import_dynamic = true;
    }
    try std.testing.expect(!pre_import_dynamic);

    // package alias修飾名も同じくimport位置より前では束縛しない。
    var package_memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "nativepkg__外部追加(1, 2)\n!「pkg:nativepkg」を取り込む\n" },
    } };
    var package_resolver = NativePluginPackageResolver{};
    var package_graph = try load(std.testing.allocator, "main.nako3", package_memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer package_graph.deinit();
    var package_program = try package_graph.analyze(std.testing.allocator);
    defer package_program.deinit();
    var pre_import_qualified = false;
    for (package_program.bindings) |binding| {
        if (binding.kind == .builtin and binding.dynamic_builtin and std.mem.eql(u8, binding.resolved_name, "nativepkg__外部追加")) pre_import_qualified = true;
    }
    try std.testing.expect(!pre_import_qualified);
}
