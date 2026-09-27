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

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, specifier: []const u8) !ResolvedPackageImport {
        const reference = if (std.mem.startsWith(u8, specifier, "パッケージ:"))
            specifier["パッケージ:".len..]
        else if (std.mem.startsWith(u8, specifier, "pkg:"))
            specifier["pkg:".len..]
        else
            return error.InvalidPackageSpecifier;
        const path = if (std.mem.eql(u8, reference, "math") or std.mem.eql(u8, reference, "math-alt"))
            "packages/math/index.nako3"
        else if (std.mem.eql(u8, reference, "util"))
            "packages/util/index.nako3"
        else if (std.mem.eql(u8, reference, "math/vector"))
            "packages/math/vector.nako3"
        else if (std.mem.eql(u8, reference, "geometry"))
            "packages/geometry/index.nako3"
        else
            return error.PackageNotFound;
        const namespace = if (std.mem.eql(u8, reference, "math"))
            "math"
        else if (std.mem.eql(u8, reference, "math-alt"))
            "math_alt"
        else if (std.mem.eql(u8, reference, "util"))
            "util"
        else if (std.mem.eql(u8, reference, "math/vector"))
            "math__vector"
        else
            "geometry";
        const canonical_id = if (std.mem.eql(u8, reference, "math") or std.mem.eql(u8, reference, "math-alt"))
            "pkg:math-id/main"
        else if (std.mem.eql(u8, reference, "util"))
            "pkg:util-id/main"
        else if (std.mem.eql(u8, reference, "math/vector"))
            "pkg:math-id/vector"
        else
            "pkg:geometry-id/main";
        const resolved_path = try std.fs.path.resolve(allocator, &.{path});
        return .{
            .path = resolved_path,
            .canonical_id = try allocator.dupe(u8, canonical_id),
            .namespace = namespace,
            .package_root = try allocator.dupe(u8, std.fs.path.dirname(resolved_path).?),
        };
    }
};

const NamespaceCollisionPackageResolver = struct {
    fn resolver(self: *NamespaceCollisionPackageResolver) PackageResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, specifier: []const u8) !ResolvedPackageImport {
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

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, specifier: []const u8) !ResolvedPackageImport {
        if (!std.mem.eql(u8, specifier, "パッケージ:lib")) return error.PackageNotFound;
        return .{
            .path = try std.fs.path.resolve(allocator, &.{"lib/index.nako3"}),
            .canonical_id = try allocator.dupe(u8, "pkg:lib/main"),
            .namespace = "lib",
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
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    const other_module = graph.modules[1];
    const local_module = graph.modules[2];
    try std.testing.expectEqualStrings("index", other_module.name);
    try std.testing.expectEqualStrings("index", local_module.name);
    try std.testing.expect(local_module.canonical_id == null);
    try std.testing.expectEqual(@as(usize, 1), local_module.imports.len);
    try std.testing.expect(local_module.imports[0].cyclic);
    try std.testing.expectEqual(@as(u32, local_module.index), local_module.imports[0].target.?);
    try std.testing.expectEqual(@as(u32, local_module.index), graph.modules[0].imports[2].target.?);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var resolved_local_alias = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "lib__値")) continue;
        const symbol_id = binding.symbol orelse continue;
        const symbol = program.symbols[symbol_id];
        if (std.mem.startsWith(u8, binding.resolved_name, "index__lnako_local_") and
            std.mem.endsWith(u8, binding.resolved_name, "__値") and symbol.module_index == local_module.index) resolved_local_alias = true;
    }
    try std.testing.expect(resolved_local_alias);
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
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    const package_module = graph.modules[1];
    try std.testing.expectEqualStrings("lib", package_module.name);
    try std.testing.expectEqual(@as(usize, 2), graph.modules[0].imports.len);
    try std.testing.expectEqualStrings("lib", graph.modules[0].imports[0].namespace.?);
    try std.testing.expectEqualStrings("index", graph.modules[0].imports[1].namespace.?);
    try std.testing.expectEqual(@as(u32, package_module.index), graph.modules[0].imports[1].target.?);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var found_binding = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "index__値")) continue;
        const symbol_id = binding.symbol orelse continue;
        const symbol = program.symbols[symbol_id];
        found_binding = std.mem.eql(u8, binding.resolved_name, symbol.qualified_name) and
            std.mem.startsWith(u8, symbol.qualified_name, "package__") and symbol.module_index == package_module.index;
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

test "packageより先に相対importされたhelperは後から所有へ取り込まれても直接参照を維持する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「packages/math/helper.nako3」を取り込む\n!「pkg:math」を取り込む\nhelper__内部値を表示\n" },
        .{ .suffix = "packages/math/helper.nako3", .source = "内部値=7\n" },
        .{ .suffix = "packages/math/index.nako3", .source = "!「./helper.nako3」を取り込む\n" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    const helper_module = graph.modules[1];
    // 先にlocal moduleとして読み込まれたhelperも、package indexの相対
    // 取り込みで同一moduleが再利用された時点で所有へ引き上げられる。
    try std.testing.expect(helper_module.canonical_id == null);
    try std.testing.expectEqualStrings("pkg:math-id", helper_module.package_owner.?);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    // 取り込み元が持つ直接辺（暗黙alias）経由の参照は所有化後も解決できる。
    var resolved_to_helper = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "helper__内部値")) continue;
        const symbol_id = binding.symbol orelse continue;
        if (program.symbols[symbol_id].module_index == helper_module.index) resolved_to_helper = true;
    }
    try std.testing.expect(resolved_to_helper);
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
