//! package の宣言命令 metadata を semantic 解析へ接続する最小スライスの試験
//! （Issue #52）。plugin の初期化・ロード・実行を行わずに、名前・助詞・arity
//! の不一致と未検査範囲を診断できることを固定する。

const std = @import("std");
const diagnostic = @import("../frontend/diagnostic.zig");
const module_graph = @import("module_graph.zig");

const load = module_graph.load;
const PackageResolver = module_graph.PackageResolver;
const ResolvedPackageImport = module_graph.ResolvedPackageImport;
const SourceProvider = module_graph.SourceProvider;
const DeclaredCommands = module_graph.DeclaredCommands;

const MemoryProvider = struct {
    files: []const File,

    const File = struct { suffix: []const u8, source: []const u8 };

    fn sourceProvider(self: *MemoryProvider) SourceProvider {
        return .{ .context = self, .readFn = read };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *MemoryProvider = @ptrCast(@alignCast(context));
        for (self.files) |file| {
            if (pathHasSuffix(path, file.suffix)) return allocator.dupe(u8, file.source);
        }
        return error.FileNotFound;
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
};

/// `pkg:lib` / `pkg:native` を解決するテスト用 resolver。宣言索引は provider
/// から渡す（実環境では `.nako/environment.json` 由来）。
const DeclaredResolver = struct {
    export_path: []const u8 = "packages/lib/index.nako3",
    namespace: []const u8 = "lib",
    canonical_id: []const u8 = "pkg:lib/main",
    package_owner: []const u8 = "pkg:lib",

    fn resolver(self: *DeclaredResolver) PackageResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !ResolvedPackageImport {
        const self: *DeclaredResolver = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, specifier, "pkg:lib") and !std.mem.eql(u8, specifier, "pkg:native")) return error.PackageNotFound;
        return .{
            .path = try std.fs.path.resolve(allocator, &.{self.export_path}),
            .canonical_id = try allocator.dupe(u8, self.canonical_id),
            .namespace = try allocator.dupe(u8, self.namespace),
            .package_owner = try allocator.dupe(u8, self.package_owner),
        };
    }
};

/// 環境 index の代わりに、テストで組み立てた宣言索引を package key で返す。
const DeclaredProvider = struct {
    lib: ?DeclaredCommands = null,

    fn provider(self: *DeclaredProvider) module_graph.DeclaredCommandsProvider {
        return .{ .context = self, .lookupFn = lookup };
    }

    fn lookup(context: *anyopaque, allocator: std.mem.Allocator, package_owner: []const u8) anyerror!?DeclaredCommands {
        _ = allocator;
        const self: *DeclaredProvider = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, package_owner, "pkg:lib")) return self.lib;
        return null;
    }
};

fn declaredAddCommand(arena: std.mem.Allocator, args: []const []const u8, josi: []const []const u8) !DeclaredCommands {
    const commands = try arena.alloc(module_graph.DeclaredCommand, 1);
    commands[0] = .{
        .name = "加算",
        .args = try arena.dupe([]const u8, args),
        .josi = try arena.dupe([]const u8, josi),
    };
    return .{ .available = true, .commands = commands };
}

fn countCode(program: anytype, code: diagnostic.Code) usize {
    var count: usize = 0;
    for (program.diagnostics) |item| {
        if (item.code == code) count += 1;
    }
    return count;
}

test "宣言metadataで名前・助詞・arityの不一致をファイル位置付きで診断する" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var provider = DeclaredProvider{ .lib = try declaredAddCommand(arena, &.{ "A", "B" }, &.{ "を", "に" }) };
    var resolver = DeclaredResolver{};
    var memory = MemoryProvider{
        .files = &.{
            .{ .suffix = "main.nako3", .source =
            \\!「pkg:lib」を取り込む
            \\1を2にlib__未宣言
            \\1と2にlib__加算
            \\lib__加算(1)
            \\
            },
            // ソース側は `と` を受ける定義にして、宣言 metadata が正本であることを
            // 確認する（ソース基準の検査だけでは通ってしまう）。
            .{ .suffix = "packages/lib/index.nako3", .source =
            \\●(AとBに)加算とは
            \\  A+Bで戻る
            \\ここまで
            \\
            },
        },
    };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{
        .package_resolver = resolver.resolver(),
        .declared_commands_provider = provider.provider(),
    });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();

    // 名前不一致: 宣言済み命令名を添えた undefined_symbol。
    try std.testing.expectEqual(@as(usize, 1), countCode(program, .undefined_symbol));
    var name_error: ?diagnostic.Diagnostic = null;
    for (program.diagnostics) |item| {
        if (item.code == .undefined_symbol) name_error = item;
    }
    try std.testing.expect(name_error != null);
    try std.testing.expectEqualStrings("main.nako3", name_error.?.file);
    try std.testing.expect(name_error.?.span.line > 0);
    try std.testing.expect(std.mem.indexOf(u8, name_error.?.message, "未宣言") != null);
    try std.testing.expect(std.mem.indexOf(u8, name_error.?.message, "加算") != null);

    // 助詞不一致: 宣言の `を` スロットに `と` が一致せず未解決語になる。
    try std.testing.expectEqual(@as(usize, 1), countCode(program, .unresolved_word));

    // arity 不一致: C風呼出しの個数が宣言 args と一致しない。
    try std.testing.expectEqual(@as(usize, 1), countCode(program, .invalid_argument_count));
}

test "宣言metadataに一致するpackage命令呼出しは診断しない（回帰）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var provider = DeclaredProvider{ .lib = try declaredAddCommand(arena, &.{ "A", "B" }, &.{ "を", "に" }) };
    var resolver = DeclaredResolver{};
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source =
        \\!「pkg:lib」を取り込む
        \\1を2にlib__加算
        \\
        },
        .{ .suffix = "packages/lib/index.nako3", .source =
        \\●(AをBに)加算とは
        \\  A+Bで戻る
        \\ここまで
        \\
        },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{
        .package_resolver = resolver.resolver(),
        .declared_commands_provider = provider.provider(),
    });
    defer graph.deinit();
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.succeeded());
    try std.testing.expectEqual(@as(usize, 0), program.diagnostics.len);
    try std.testing.expect(program.packageCommandsInspected());
    var bound = false;
    for (program.bindings) |binding| {
        if (std.mem.eql(u8, binding.name, "lib__加算")) bound = true;
    }
    try std.testing.expect(bound);
}

test "変数宣言命令の参照は正当で、助詞付き参照を誤検知しない" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const commands = try arena.alloc(module_graph.DeclaredCommand, 1);
    commands[0] = .{ .name = "設定", .variable = true };
    var provider = DeclaredProvider{ .lib = .{ .available = true, .commands = commands } };
    var resolver = DeclaredResolver{};
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source =
        \\!「pkg:lib」を取り込む
        \\lib__設定を表示
        \\
        },
        .{ .suffix = "packages/lib/index.nako3", .source = "設定=42\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{
        .package_resolver = resolver.resolver(),
        .declared_commands_provider = provider.provider(),
    });
    defer graph.deinit();
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expectEqual(@as(usize, 0), program.diagnostics.len);
    try std.testing.expect(program.packageCommandsInspected());
}

test "宣言索引に無い非公開シンボルでもaliasで解決できれば誤拒否しない" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 索引は公開命令だけを持つ。非公開の module 変数は載らないが、既存の
    // alias 解決では参照できるため、宣言不一致として拒否してはならない。
    var provider = DeclaredProvider{ .lib = try declaredAddCommand(arena, &.{ "A", "B" }, &.{ "を", "に" }) };
    var resolver = DeclaredResolver{};
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source =
        \\!「pkg:lib」を取り込む
        \\lib__秘密を表示
        \\
        },
        .{ .suffix = "packages/lib/index.nako3", .source = "変数 秘密{非公開}=1\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{
        .package_resolver = resolver.resolver(),
        .declared_commands_provider = provider.provider(),
    });
    defer graph.deinit();
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expectEqual(@as(usize, 0), program.diagnostics.len);
    // 索引の被覆外なので未検査として残る。
    try std.testing.expect(!program.packageCommandsInspected());
}

test "変数宣言命令をC風呼出しした場合は拒否する" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const commands = try arena.alloc(module_graph.DeclaredCommand, 1);
    commands[0] = .{ .name = "設定", .variable = true };
    var provider = DeclaredProvider{ .lib = .{ .available = true, .commands = commands } };
    var resolver = DeclaredResolver{};
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source =
        \\!「pkg:lib」を取り込む
        \\lib__設定(1)
        \\
        },
        .{ .suffix = "packages/lib/index.nako3", .source = "設定=42\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{
        .package_resolver = resolver.resolver(),
        .declared_commands_provider = provider.provider(),
    });
    defer graph.deinit();
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
    try std.testing.expectEqual(@as(usize, 1), countCode(program, .invalid_argument_count));
}

test "argsのみで助詞を欠く宣言は検査済み扱いにせずソース検査へ戻す" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const commands = try arena.alloc(module_graph.DeclaredCommand, 1);
    commands[0] = .{ .name = "加算", .args = try arena.dupe([]const u8, &.{ "A", "B" }) };
    var provider = DeclaredProvider{ .lib = .{ .available = true, .commands = commands } };
    var resolver = DeclaredResolver{};
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source =
        \\!「pkg:lib」を取り込む
        \\1を2にlib__加算
        \\
        },
        .{ .suffix = "packages/lib/index.nako3", .source =
        \\●(AをBに)加算とは
        \\  A+Bで戻る
        \\ここまで
        \\
        },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{
        .package_resolver = resolver.resolver(),
        .declared_commands_provider = provider.provider(),
    });
    defer graph.deinit();
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    // 助詞スロットを構成できない宣言で全引数を未解決語にしない。
    try std.testing.expect(program.succeeded());
    try std.testing.expectEqual(@as(usize, 0), program.diagnostics.len);
    // 宣言を検査に使えなかったので未検査として記録する。
    try std.testing.expect(!program.packageCommandsInspected());
}

test "metadataの無いpackage alias経由の呼出しは未検査として記録する" {
    var resolver = DeclaredResolver{};
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source =
        \\!「pkg:lib」を取り込む
        \\1を2にlib__加算
        \\
        },
        .{ .suffix = "packages/lib/index.nako3", .source =
        \\●(AをBに)加算とは
        \\  A+Bで戻る
        \\ここまで
        \\
        },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = resolver.resolver() });
    defer graph.deinit();
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();

    // ソースシンボルへは解決できるが、宣言 metadata が無いので「検査済み」
    // とは扱わない。
    try std.testing.expect(program.succeeded());
    var bound = false;
    for (program.bindings) |binding| {
        if (std.mem.eql(u8, binding.name, "lib__加算")) bound = true;
    }
    try std.testing.expect(bound);
    try std.testing.expect(!program.packageCommandsInspected());
    try std.testing.expectEqual(@as(usize, 1), program.uninspected_package_commands.len);
    try std.testing.expectEqualStrings("lib", program.uninspected_package_commands[0].namespace);
}

test "metadataの無いpackage aliasの未解決呼出しに未検査警告を出す" {
    var resolver = DeclaredResolver{};
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source =
        \\!「pkg:lib」を取り込む
        \\lib__未定義
        \\
        },
        .{ .suffix = "packages/lib/index.nako3", .source = "A=1\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = resolver.resolver() });
    defer graph.deinit();
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 1), countCode(program, .uninspected_package_command));
    for (program.diagnostics) |item| {
        if (item.code != .uninspected_package_command) continue;
        try std.testing.expectEqual(diagnostic.Severity.warning, item.severity);
        try std.testing.expect(std.mem.indexOf(u8, item.message, "未検査") != null);
    }
    try std.testing.expect(!program.packageCommandsInspected());
}

test "semantic解析はpackageの初期化コードもnative pluginも実行しない" {
    // 副作用つきの package source と、存在しない native artifact。どちらも
    // 静的解析だけを行い、初期化・dlopen・実行はしない。
    const io = std.testing.io;
    const marker = "SIDE_EFFECT_DECLARED_COMMANDS.txt";
    std.Io.Dir.cwd().deleteFile(io, marker) catch {};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var provider = DeclaredProvider{ .lib = try declaredAddCommand(arena, &.{ "A", "B" }, &.{ "を", "に" }) };

    const MultiResolver = struct {
        lib: DeclaredResolver,
        native: DeclaredResolver,

        fn resolver(self: *@This()) PackageResolver {
            return .{ .context = self, .resolveFn = resolve };
        }

        fn resolve(context: *anyopaque, allocator: std.mem.Allocator, importer: []const u8, owner: ?[]const u8, specifier: []const u8) !ResolvedPackageImport {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, specifier, "pkg:lib")) return DeclaredResolver.resolve(&self.lib, allocator, importer, owner, specifier);
            if (std.mem.eql(u8, specifier, "pkg:native")) return DeclaredResolver.resolve(&self.native, allocator, importer, owner, specifier);
            return error.PackageNotFound;
        }
    };
    var multi = MultiResolver{
        .lib = DeclaredResolver{},
        .native = DeclaredResolver{
            .export_path = "packages/native/missing-plugin.dylib",
            .namespace = "native",
            .canonical_id = "pkg:native/main",
            .package_owner = "pkg:native",
        },
    };
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source =
        \\!「pkg:lib」を取り込む
        \\!「pkg:native」を取り込む
        \\1を2にlib__加算
        \\native__何か
        \\
        },
        .{ .suffix = "packages/lib/index.nako3", .source =
        \\「ran」を「SIDE_EFFECT_DECLARED_COMMANDS.txt」に保存
        \\●(AをBに)加算とは
        \\  A+Bで戻る
        \\ここまで
        \\
        },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{
        .package_resolver = multi.resolver(),
        .declared_commands_provider = provider.provider(),
    });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    // native artifact は存在しないが、semantic 段階では読み込み・ロードしない。
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    // native package の索引は無いので未検査が残る。
    try std.testing.expect(!program.packageCommandsInspected());

    // 初期化コードが実行されていれば marker が残る。
    std.Io.Dir.cwd().access(io, marker, .{}) catch |err| {
        try std.testing.expect(err == error.FileNotFound);
        return;
    };
    try std.testing.expect(false);
}
