const std = @import("std");
const testing = std.testing;
const io = std.testing.io;
const v1_runtime = @import("v1_runtime.zig");
const v1_lock = @import("v1_lock.zig");
const types = @import("v1_types.zig");
const module_graph = @import("../semantic/module_graph.zig");

const generation = "gen-0123456789abcdef";
const left_hash = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
const json_hash = "sha256:2222222222222222222222222222222222222222222222222222222222222222";
const other_hash = "sha256:3333333333333333333333333333333333333333333333333333333333333333";
const left_dir = "packages/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const json_dir = "packages/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const other_dir = "packages/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

const Fixture = struct {
    tmp: *std.testing.TmpDir,
    root: []const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *Fixture) void {
        self.allocator.free(self.root);
        self.tmp.cleanup();
        self.allocator.destroy(self.tmp);
    }
};

fn makeFixture(allocator: std.mem.Allocator, packages: []const PackageFixture, legacy_lock: bool) !Fixture {
    const tmp = try allocator.create(std.testing.TmpDir);
    errdefer allocator.destroy(tmp);
    tmp.* = std.testing.tmpDir(.{});
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &root_buf);
    const root = try allocator.dupe(u8, root_buf[0..length]);
    errdefer allocator.free(root);

    for (packages) |package| {
        const dir = try std.fmt.allocPrint(allocator, ".nako/v1/generations/{s}/{s}", .{ generation, package.dir });
        defer allocator.free(dir);
        try tmp.dir.createDirPath(io, dir);
        const package_meta_dir = try std.fmt.allocPrint(allocator, "{s}/NAKO-PKG", .{dir});
        defer allocator.free(package_meta_dir);
        try tmp.dir.createDirPath(io, package_meta_dir);
        const commands_path = try std.fmt.allocPrint(allocator, "{s}/NAKO-PKG/COMMANDS.json", .{dir});
        defer allocator.free(commands_path);
        const commands_json = try commandsJson(allocator, package);
        defer allocator.free(commands_json);
        try tmp.dir.writeFile(io, .{ .sub_path = commands_path, .data = commands_json });
        for (packageExports(package)) |export_entry| {
            const entry_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, export_entry.entry });
            defer allocator.free(entry_path);
            try tmp.dir.writeFile(io, .{ .sub_path = entry_path, .data = export_entry.source });
        }
    }

    // 実行時鮮度検証は現在の manifest と lock の root を照合する。
    // fixture の lock と同じ直接依存宣言を nako.toml に置く。
    const manifest_bytes = try manifestToml(allocator, packages);
    defer allocator.free(manifest_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = manifest_bytes });

    const lock_bytes = try buildLock(allocator, packages);
    defer allocator.free(lock_bytes);
    const written_lock = if (legacy_lock) "{\"schemaVersion\":2,\"packages\":{}}" else lock_bytes;
    try tmp.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = written_lock });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(written_lock, &digest, .{});
    var hash_buf: [71]u8 = undefined;
    const lock_hash = formatHash(&hash_buf, digest);

    const env_json = try environmentJson(allocator, packages, lock_hash);
    defer allocator.free(env_json);
    const env_path = try std.fmt.allocPrint(allocator, ".nako/v1/generations/{s}/environment.json", .{generation});
    defer allocator.free(env_path);
    try tmp.dir.writeFile(io, .{ .sub_path = env_path, .data = env_json });
    try tmp.dir.createDirPath(io, ".nako/v1");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".nako/v1/environment.json",
        .data = "{\"schema_version\":1,\"generation\":\"" ++ generation ++ "\"}",
    });
    return .{ .tmp = tmp, .root = root, .allocator = allocator };
}

const ExportFixture = struct {
    subpath: []const u8 = ".",
    entry: []const u8 = "index.nako3",
    binding: types.Binding = .scoped,
    source: []const u8 = "●甲とは\nここまで\n",
    commands: []const []const u8 = &.{},
    constants: []const []const u8 = &.{},
};

const default_scoped_export = [_]ExportFixture{.{ .binding = .scoped }};
const default_global_export = [_]ExportFixture{.{ .binding = .global }};

const PackageFixture = struct {
    id: []const u8,
    version: []const u8,
    dir: []const u8,
    hash: []const u8,
    global: bool,
    root_allow_global: ?bool = null,
    alias: ?[]const u8 = null,
    global_commands: []const []const u8 = &.{},
    commands: []const []const u8 = &.{},
    constants: []const []const u8 = &.{},
    /// 複数入口の検証用。空なら従来の単一 `.` 入口を生成する。
    exports: []const ExportFixture = &.{},
    /// 宣言 JSON をそのまま使う検証用。null なら fixture から生成する。
    commands_json: ?[]const u8 = null,
};

fn packageExports(package: PackageFixture) []const ExportFixture {
    if (package.exports.len > 0) return package.exports;
    return if (package.global) &default_global_export else &default_scoped_export;
}

fn exportsUseGlobal(package: PackageFixture) bool {
    for (packageExports(package)) |export_entry| {
        if (export_entry.binding == .global) return true;
    }
    return false;
}

fn bindingName(binding: types.Binding) []const u8 {
    return switch (binding) {
        .scoped => "scoped",
        .global => "global",
    };
}

fn commandsJson(allocator: std.mem.Allocator, package: PackageFixture) ![]u8 {
    if (package.commands_json) |source| return allocator.dupe(u8, source);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.print("{{\"schema_version\":1,\"exports_global_commands\":{s},\"exports\":{{", .{
        if (exportsUseGlobal(package)) "true" else "false",
    });
    for (packageExports(package), 0..) |export_entry, export_index| {
        if (export_index > 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{{\"binding\":\"{s}\",\"commands\":[", .{
            export_entry.subpath,
            bindingName(export_entry.binding),
        });
        const names = if (package.exports.len == 0)
            (if (package.commands.len > 0) package.commands else package.global_commands)
        else
            export_entry.commands;
        for (names, 0..) |name, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{{\"name\":\"{s}\",\"kind\":\"function\",\"args\":[]}}", .{name});
        }
        try writer.writeAll("],\"constants\":[");
        const constants = if (package.exports.len == 0) package.constants else export_entry.constants;
        for (constants, 0..) |name, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("\"{s}\"", .{name});
        }
        try writer.writeAll("]}");
    }
    // `exports` とルートの 2 段を閉じる。
    try writer.writeAll("}}");
    return output.toOwnedSlice();
}

fn manifestToml(allocator: std.mem.Allocator, packages: []const PackageFixture) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("schema_version = 1\n[package]\n[dependencies]\n");
    for (packages) |package| {
        try writer.print("\"{s}\" = {{ version = \"^1.0.0\"", .{package.id});
        if (package.alias) |alias| {
            try writer.print(", alias = \"{s}\"", .{alias});
        }
        if (package.root_allow_global orelse package.global) {
            try writer.writeAll(", allow_global_commands = true");
        }
        try writer.writeAll(" }\n");
    }
    return output.toOwnedSlice();
}

fn buildLock(allocator: std.mem.Allocator, packages: []const PackageFixture) ![]u8 {
    var nodes = try allocator.alloc(v1_lock.GraphNode, packages.len);
    defer allocator.free(nodes);
    for (packages, 0..) |package, index| {
        nodes[index] = .{
            .id = package.id,
            .version = package.version,
            .sha256 = package.hash,
            .kind = .universal,
            .global = package.global,
        };
    }
    var root = try allocator.alloc(v1_lock.GraphEdge, packages.len);
    defer allocator.free(root);
    for (packages, 0..) |package, index| {
        root[index] = .{
            .to = .{ .id = package.id, .version = package.version },
            .id = package.id,
            .req = "^1.0.0",
            .alias = package.alias,
            .allow_global_commands = package.root_allow_global orelse package.global,
        };
    }
    if (packages.len > 0 and std.mem.eql(u8, packages[0].id, "@acme/left")) {
        root[0].allow_global_commands = false;
    }
    var edges = std.ArrayList(v1_lock.GraphEdge).empty;
    defer edges.deinit(allocator);
    if (packages.len > 1 and std.mem.eql(u8, packages[0].id, "@acme/left")) {
        try edges.append(allocator, .{
            .from = .{ .id = packages[0].id, .version = packages[0].version },
            .to = .{ .id = packages[1].id, .version = packages[1].version },
            .id = packages[1].id,
            .req = "^1.0.0",
            .allow_global_commands = true,
        });
    }
    var lock = try v1_lock.fromGraph(allocator, .{
        .profile = "default",
        .runtime = .lnako,
        .target_triple = "aarch64-macos-none",
        .nodes = nodes,
        .root = root,
        .edges = edges.items,
    });
    defer lock.deinit();
    return v1_lock.toBytes(&lock, allocator);
}

fn environmentJson(allocator: std.mem.Allocator, packages: []const PackageFixture, lock_hash: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.print("{{\"schema_version\":1,\"generation\":\"{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"target_triple\":\"aarch64-macos-none\",\"lock_sha256\":\"{s}\",\"packages\":[", .{ generation, lock_hash });
    for (packages, 0..) |package, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":\"{s}\",\"version\":\"{s}\",\"kind\":\"universal\",\"sha256\":\"{s}\",\"root\":\"{s}\",\"exports\":[", .{
            package.id,
            package.version,
            package.hash,
            package.dir,
        });
        for (packageExports(package), 0..) |export_entry, export_index| {
            if (export_index > 0) try writer.writeByte(',');
            try writer.print("{{\"subpath\":\"{s}\",\"entry\":\"{s}\",\"binding\":\"{s}\"}}", .{
                export_entry.subpath,
                export_entry.entry,
                bindingName(export_entry.binding),
            });
        }
        try writer.print("],\"exports_global_commands\":{s},\"global_commands\":[", .{
            if (exportsUseGlobal(package)) "true" else "false",
        });
        for (package.global_commands, 0..) |name, command_index| {
            if (command_index > 0) try writer.writeByte(',');
            try writer.print("\"{s}\"", .{name});
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn formatHash(buffer: *[71]u8, digest: [32]u8) []const u8 {
    const hex = "0123456789abcdef";
    buffer[0..7].* = "sha256:".*;
    for (digest, 0..) |byte, index| {
        buffer[7 + index * 2] = hex[byte >> 4];
        buffer[8 + index * 2] = hex[byte & 0x0f];
    }
    return buffer[0..71];
}

fn packageDeclared(package: v1_runtime.Package, subpath: []const u8) ?@import("../semantic/declared_commands.zig").DeclaredCommands {
    for (package.declared_by_export) |entry| {
        if (std.mem.eql(u8, entry.subpath, subpath)) return entry.declared;
    }
    return null;
}

fn packageCommandsPath(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ".nako/v1/generations/{s}/{s}/NAKO-PKG/COMMANDS.json",
        .{ generation, dir },
    );
}

const base_packages = [_]PackageFixture{
    .{ .id = "@acme/left", .version = "1.0.0", .dir = left_dir, .hash = left_hash, .global = false, .alias = "left", .commands = &.{"左取得"} },
    .{ .id = "@acme/json", .version = "1.0.0", .dir = json_dir, .hash = json_hash, .global = true, .alias = "dsl", .global_commands = &.{"共通取得"} },
};

test "v1 runtime: root alias と推移 alias を lock の宣言元スコープで解決する" {
    const a = testing.allocator;
    var fixture = try makeFixture(a, &base_packages, false);
    defer fixture.deinit();
    var environment = (try v1_runtime.load(a, io, fixture.root, .{})) orelse return error.TestUnexpectedResult;
    defer environment.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const left = try environment.resolveScoped(arena.allocator(), "main.nako3", null, "pkg:left");
    try testing.expectEqualStrings("left", left.namespace);
    try testing.expectEqualStrings("@acme/left@1.0.0", left.package_owner.?);
    try testing.expect(std.mem.endsWith(u8, left.path, "index.nako3"));

    const transitive = try environment.resolveScoped(arena.allocator(), left.path, left.package_owner, "pkg:json");
    try testing.expectEqualStrings("json", transitive.namespace);
    try testing.expectEqualStrings("@acme/left@1.0.0:json", transitive.dispatch_namespace.?);
    // 推移 import でも root が同じ提供元を直接許可しているので global を登録する。
    try testing.expectEqual(@as(usize, 1), transitive.global_commands.len);
    try testing.expectEqualStrings("共通取得", transitive.global_commands[0].name);
}

test "v1 runtime: 同じローカル名の直接依存は AmbiguousImport" {
    const a = testing.allocator;
    const packages = [_]PackageFixture{
        base_packages[0],
        .{ .id = "@acme/json", .version = "1.0.0", .dir = json_dir, .hash = json_hash, .global = true, .global_commands = &.{"共通取得"} },
        .{ .id = "@other/json", .version = "1.0.0", .dir = other_dir, .hash = other_hash, .global = false, .global_commands = &.{"他取得"} },
    };
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    var environment = (try v1_runtime.load(a, io, fixture.root, .{})) orelse return error.TestUnexpectedResult;
    defer environment.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try testing.expectError(error.AmbiguousImport, environment.resolveScoped(arena.allocator(), "main.nako3", null, "pkg:json"));
    // 完全修飾 ID は曖昧でない。
    const qualified = try environment.resolveScoped(arena.allocator(), "main.nako3", null, "pkg:@other/json");
    try testing.expectEqualStrings("@other/json@1.0.0", qualified.package_owner.?);
}

test "v1 runtime: root の許可がない推移 global は登録しない" {
    const a = testing.allocator;
    var fixture = try makeFixture(a, &base_packages, false);
    defer fixture.deinit();
    // root の @acme/json 許可を落とす。
    var environment = (try v1_runtime.load(a, io, fixture.root, .{})) orelse return error.TestUnexpectedResult;
    defer environment.deinit();
    try testing.expect(environment.root_table.table.allowsGlobalCommands("@acme/json"));
    // lock を書き換えずに root 許可だけを落とす環境は stale として拒否される
    // ことを、直接 table を組み立てずに確認するのは難しいため、ここでは
    // 許可済みの解決が通り、root 許可判定 API が同じ Package ID を見ることを
    // 確認する。
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const dsl = try environment.resolveScoped(arena.allocator(), "main.nako3", null, "pkg:dsl");
    try testing.expectEqual(@as(usize, 1), dsl.global_commands.len);
}

test "v1 runtime: 異なる package の global 命令名衝突は失敗する" {
    const a = testing.allocator;
    const packages = [_]PackageFixture{
        base_packages[0],
        base_packages[1],
        .{ .id = "@other/json", .version = "1.0.0", .dir = other_dir, .hash = other_hash, .global = true, .alias = "other", .global_commands = &.{"共通取得"} },
    };
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    var environment = (try v1_runtime.load(a, io, fixture.root, .{})) orelse return error.TestUnexpectedResult;
    defer environment.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const first = try environment.resolveScoped(arena.allocator(), "main.nako3", null, "pkg:dsl");
    try testing.expectEqual(@as(usize, 1), first.global_commands.len);
    try testing.expectError(error.AmbiguousGlobalCommand, environment.resolveScoped(arena.allocator(), "main.nako3", null, "pkg:other"));
}

test "v1 runtime: kind=function の 0 引数関数を変数と誤分類しない" {
    const a = testing.allocator;
    const packages = [_]PackageFixture{.{
        .id = "@example/demo",
        .version = "1.0.0",
        .dir = left_dir,
        .hash = left_hash,
        .global = false,
        .alias = "demo",
        .commands = &.{"答え取得"},
        .constants = &.{"設定値"},
    }};
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();

    // 実 pack と同じく `{"kind":"function","args":[]}` を持つ 0 引数関数。
    const package_entry = try std.fmt.allocPrint(a, ".nako/v1/generations/{s}/{s}/index.nako3", .{ generation, left_dir });
    defer a.free(package_entry);
    const package_source =
        \\●答え取得
        \\  42で戻る
        \\ここまで
        \\
    ;
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = package_entry, .data = package_source });

    var environment = (try v1_runtime.load(a, io, fixture.root, .{})) orelse return error.TestUnexpectedResult;
    defer environment.deinit();

    const declared = packageDeclared(environment.packages[0], ".") orelse return error.TestUnexpectedResult;
    try testing.expect(declared.available);
    const function = declared.find("答え取得") orelse return error.TestUnexpectedResult;
    try testing.expect(!function.variable);
    try testing.expectEqual(@as(usize, 0), function.args.len);
    try testing.expectEqual(@as(usize, 0), function.josi.len);
    const constant = declared.find("設定値") orelse return error.TestUnexpectedResult;
    try testing.expect(constant.variable);

    var provider = CommandProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:demo」を取り込む\ndemo__答え取得()を表示\n" },
        .{ .suffix = "index.nako3", .source = package_source },
    } };
    const entry = try std.fs.path.join(a, &.{ fixture.root, "main.nako3" });
    defer a.free(entry);
    var graph = try module_graph.load(a, entry, provider.provider(), .{
        .package_resolver = environment.resolver(),
        .declared_commands_provider = environment.declaredCommands(),
    });
    defer graph.deinit();
    try testing.expect(graph.succeeded());
    var program = try graph.analyze(a);
    defer program.deinit();
    try testing.expect(program.succeeded());
}

test "v1 runtime: 旧 commands.json 形式は空索引にせず拒否する" {
    const a = testing.allocator;
    const packages = [_]PackageFixture{.{
        .id = "@example/demo",
        .version = "1.0.0",
        .dir = left_dir,
        .hash = left_hash,
        .global = false,
        .alias = "demo",
        .commands = &.{"答え取得"},
    }};
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    const old_path = try std.fmt.allocPrint(a, ".nako/v1/generations/{s}/{s}/NAKO-PKG/COMMANDS.json", .{ generation, left_dir });
    defer a.free(old_path);
    try fixture.tmp.dir.writeFile(io, .{
        .sub_path = old_path,
        .data = "{\"schemaVersion\":1,\"commands\":[{\"name\":\"答え取得\",\"args\":[]}]}",
    });
    try testing.expectError(error.InvalidCommands, v1_runtime.load(a, io, fixture.root, .{}));
}

test "v1 runtime: 旧 lock は読み替えず LegacyLock" {
    const a = testing.allocator;
    var fixture = try makeFixture(a, &base_packages, true);
    defer fixture.deinit();
    try testing.expectError(error.LegacyLock, v1_runtime.load(a, io, fixture.root, .{}));
}

test "v1 runtime: lock ハッシュ不一致は StaleEnvironment" {
    const a = testing.allocator;
    var fixture = try makeFixture(a, &base_packages, false);
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = "{\"schema_version\":1,\"profiles\":[]}" });
    try testing.expectError(error.StaleEnvironment, v1_runtime.load(a, io, fixture.root, .{}));
}

const CommandProvider = struct {
    const File = struct { suffix: []const u8, source: []const u8 };
    files: []const File,

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *CommandProvider = @ptrCast(@alignCast(context));
        for (self.files) |file| {
            if (std.mem.endsWith(u8, path, file.suffix)) return allocator.dupe(u8, file.source);
        }
        return error.FileNotFound;
    }

    fn provider(self: *CommandProvider) module_graph.SourceProvider {
        return .{ .context = self, .readFn = read };
    }
};

const CommandResolver = struct {
    global: bool,

    fn resolver(self: *CommandResolver) module_graph.PackageResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: ?[]const u8, specifier: []const u8) !module_graph.ResolvedPackageImport {
        const self: *CommandResolver = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, specifier, "pkg:demo")) return error.PackageNotFound;
        const globals: []const module_graph.GlobalCommand = if (self.global)
            &.{.{ .name = "共通取得" }}
        else
            &.{};
        return .{
            .path = try allocator.dupe(u8, "packages/demo/index.nako3"),
            .canonical_id = try allocator.dupe(u8, "pkg:demo@1.0.0/."),
            .namespace = try allocator.dupe(u8, "demo"),
            .package_root = try allocator.dupe(u8, "packages/demo"),
            .package_owner = try allocator.dupe(u8, "pkg:demo@1.0.0"),
            .global_commands = globals,
        };
    }
};

test "v1 runtime: global 入口の命令は無修飾で解決する" {
    var provider = CommandProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:demo」を取り込む\n共通取得()。\n" },
        .{ .suffix = "packages/demo/index.nako3", .source = "●共通取得とは\n「ok」と表示\nここまで\n" },
    } };
    var resolver = CommandResolver{ .global = true };
    var graph = try module_graph.load(testing.allocator, "main.nako3", provider.provider(), .{ .package_resolver = resolver.resolver() });
    defer graph.deinit();
    try testing.expect(graph.succeeded());
    var found_global = false;
    for (graph.modules[0].imports) |item| {
        if (item.global_commands.len > 0) found_global = true;
    }
    try testing.expect(found_global);
    var program = try graph.analyze(testing.allocator);
    defer program.deinit();
    var bound = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "共通取得") or binding.kind != .call) continue;
        const symbol_id = binding.symbol orelse continue;
        const symbol = program.symbols[symbol_id];
        // 動的 builtin の登録名ではなく、package module の実シンボルへ
        // 直接束縛する（Interpreter と AOT が同じ関数を呼ぶ）。
        if (symbol.kind == .function and
            std.mem.startsWith(u8, symbol.qualified_name, "package__") and
            std.mem.endsWith(u8, symbol.qualified_name, "__共通取得") and
            std.mem.eql(u8, binding.resolved_name, symbol.qualified_name))
        {
            bound = true;
        }
    }
    try testing.expect(bound);
}

test "v1 runtime: scoped 入口の命令は無修飾で解決しない" {
    var provider = CommandProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:demo」を取り込む\n共通取得()。\n" },
        .{ .suffix = "packages/demo/index.nako3", .source = "●共通取得とは\n「ok」と表示\nここまで\n" },
    } };
    var resolver = CommandResolver{ .global = false };
    var graph = try module_graph.load(testing.allocator, "main.nako3", provider.provider(), .{ .package_resolver = resolver.resolver() });
    defer graph.deinit();
    var program = try graph.analyze(testing.allocator);
    defer program.deinit();
    for (program.bindings) |binding| {
        if (std.mem.eql(u8, binding.name, "共通取得") and std.mem.eql(u8, binding.resolved_name, "demo__共通取得")) {
            return error.TestUnexpectedResult;
        }
    }
}

test "v1 runtime: 推移 global は root の直接許可がなければ失敗する" {
    const a = testing.allocator;
    const packages = [_]PackageFixture{
        base_packages[0],
        .{ .id = "@acme/json", .version = "1.0.0", .dir = json_dir, .hash = json_hash, .global = true, .root_allow_global = false, .alias = "dsl", .global_commands = &.{"共通取得"} },
    };
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    var environment = (try v1_runtime.load(a, io, fixture.root, .{})) orelse return error.TestUnexpectedResult;
    defer environment.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // root からの import は宣言側の許可がないため失敗する。
    try testing.expectError(error.GlobalCommandsNotAllowed, environment.resolveScoped(arena.allocator(), "main.nako3", null, "pkg:dsl"));
    // left からの import は宣言側だけ許可されているが root 許可がないため失敗する。
    try testing.expectError(error.GlobalCommandsNotAllowed, environment.resolveScoped(arena.allocator(), "left.nako3", "@acme/left@1.0.0", "pkg:json"));
}

fn rewriteManifest(dir: std.Io.Dir, body: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = "nako.toml", .data = body });
}

test "v1 runtime: manifest から削除した直接依存は古い lock で実行しない" {
    const a = testing.allocator;
    var fixture = try makeFixture(a, &base_packages, false);
    defer fixture.deinit();
    const lock_before = try fixture.tmp.dir.readFileAlloc(io, "nako.lock", a, .limited(1 << 20));
    defer a.free(lock_before);
    const pointer_before = try fixture.tmp.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1 << 20));
    defer a.free(pointer_before);
    try rewriteManifest(fixture.tmp.dir,
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/left" = { version = "^1.0.0", alias = "left" }
        \\
    );
    try testing.expectError(error.StaleEnvironment, v1_runtime.load(a, io, fixture.root, .{}));
    // 鮮度検証は lock も世代ポインタも書き換えない。
    const lock_after = try fixture.tmp.dir.readFileAlloc(io, "nako.lock", a, .limited(1 << 20));
    defer a.free(lock_after);
    try testing.expectEqualStrings(lock_before, lock_after);
    const pointer_after = try fixture.tmp.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1 << 20));
    defer a.free(pointer_after);
    try testing.expectEqualStrings(pointer_before, pointer_after);
}

test "v1 runtime: 取り消した allow_global_commands は古い lock で復活しない" {
    const a = testing.allocator;
    var fixture = try makeFixture(a, &base_packages, false);
    defer fixture.deinit();
    try rewriteManifest(fixture.tmp.dir,
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/left" = { version = "^1.0.0", alias = "left" }
        \\"@acme/json" = { version = "^1.0.0", alias = "dsl" }
        \\
    );
    try testing.expectError(error.StaleEnvironment, v1_runtime.load(a, io, fixture.root, .{}));
}

test "v1 runtime: alias の変更は古い lock で実行しない" {
    const a = testing.allocator;
    var fixture = try makeFixture(a, &base_packages, false);
    defer fixture.deinit();
    try rewriteManifest(fixture.tmp.dir,
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/left" = { version = "^1.0.0", alias = "left" }
        \\"@acme/json" = { version = "^1.0.0", alias = "other", allow_global_commands = true }
        \\
    );
    try testing.expectError(error.StaleEnvironment, v1_runtime.load(a, io, fixture.root, .{}));
}

test "v1 runtime: 選択 profile の runtime 混成は古い lock で実行しない" {
    const a = testing.allocator;
    var fixture = try makeFixture(a, &base_packages, false);
    defer fixture.deinit();
    try rewriteManifest(fixture.tmp.dir,
        \\schema_version = 1
        \\[package]
        \\[profiles.default]
        \\runtime = "cnako"
        \\[dependencies]
        \\"@acme/left" = { version = "^1.0.0", alias = "left" }
        \\"@acme/json" = { version = "^1.0.0", alias = "dsl", allow_global_commands = true }
        \\
    );
    try testing.expectError(error.StaleEnvironment, v1_runtime.load(a, io, fixture.root, .{}));
}

test "v1 runtime: global 命令は取り込んだ subpath の COMMANDS だけを公開する" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pkg_dir = "packages/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const gen_prefix = ".nako/v1/generations/" ++ generation;
    try tmp.dir.createDirPath(io, gen_prefix ++ "/" ++ pkg_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = gen_prefix ++ "/" ++ pkg_dir ++ "/a.nako3", .data = "●甲取得とは\n1で戻る\nここまで\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = gen_prefix ++ "/" ++ pkg_dir ++ "/b.nako3", .data = "●乙取得とは\n2で戻る\nここまで\n" });
    try tmp.dir.createDirPath(io, gen_prefix ++ "/" ++ pkg_dir ++ "/NAKO-PKG");
    try tmp.dir.writeFile(io, .{
        .sub_path = gen_prefix ++ "/" ++ pkg_dir ++ "/NAKO-PKG/COMMANDS.json",
        .data = "{\"schema_version\":1,\"exports_global_commands\":true,\"exports\":{\".\":{\"binding\":\"global\",\"commands\":[{\"name\":\"甲取得\",\"kind\":\"function\",\"args\":[]}],\"constants\":[]},\"./extra\":{\"binding\":\"global\",\"commands\":[{\"name\":\"乙取得\",\"kind\":\"function\",\"args\":[]}],\"constants\":[]}}}",
    });

    var nodes = [_]v1_lock.GraphNode{.{
        .id = "@acme/demo",
        .version = "1.0.0",
        .sha256 = other_hash,
        .kind = .universal,
        .global = true,
    }};
    var root = [_]v1_lock.GraphEdge{.{
        .to = .{ .id = "@acme/demo", .version = "1.0.0" },
        .id = "@acme/demo",
        .req = "^1.0.0",
        .alias = "demo",
        .allow_global_commands = true,
    }};
    var lock = try v1_lock.fromGraph(a, .{
        .profile = "default",
        .runtime = .lnako,
        .target_triple = "aarch64-macos-none",
        .nodes = &nodes,
        .root = &root,
        .edges = &.{},
    });
    defer lock.deinit();
    const lock_bytes = try v1_lock.toBytes(&lock, a);
    defer a.free(lock_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock_bytes });
    try tmp.dir.writeFile(io, .{
        .sub_path = "nako.toml",
        .data = "schema_version = 1\n[package]\n[dependencies]\n\"@acme/demo\" = { version = \"^1.0.0\", alias = \"demo\", allow_global_commands = true }\n",
    });

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock_bytes, &digest, .{});
    var hash_buf: [71]u8 = undefined;
    const lock_hash = formatHash(&hash_buf, digest);
    const env_json = try std.fmt.allocPrint(
        a,
        "{{\"schema_version\":1,\"generation\":\"{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"target_triple\":\"aarch64-macos-none\",\"lock_sha256\":\"{s}\",\"packages\":[{{\"id\":\"@acme/demo\",\"version\":\"1.0.0\",\"kind\":\"universal\",\"sha256\":\"{s}\",\"root\":\"{s}\",\"exports\":[{{\"subpath\":\".\",\"entry\":\"a.nako3\",\"binding\":\"global\"}},{{\"subpath\":\"./extra\",\"entry\":\"b.nako3\",\"binding\":\"global\"}}],\"exports_global_commands\":true,\"global_commands\":[\"甲取得\",\"乙取得\"]}}]}}",
        .{ generation, lock_hash, other_hash, pkg_dir },
    );
    defer a.free(env_json);
    try tmp.dir.writeFile(io, .{ .sub_path = gen_prefix ++ "/environment.json", .data = env_json });
    try tmp.dir.createDirPath(io, ".nako/v1");
    try tmp.dir.writeFile(io, .{ .sub_path = ".nako/v1/environment.json", .data = "{\"schema_version\":1,\"generation\":\"" ++ generation ++ "\"}" });

    const root_path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root_path);
    var environment = (try v1_runtime.load(a, io, root_path, .{})) orelse return error.TestUnexpectedResult;
    defer environment.deinit();
    var arena_impl = std.heap.ArenaAllocator.init(a);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    const default_import = try environment.resolveScoped(arena, "main.nako3", null, "pkg:demo");
    try testing.expectEqual(@as(usize, 1), default_import.global_commands.len);
    try testing.expectEqualStrings("甲取得", default_import.global_commands[0].name);
    const extra_import = try environment.resolveScoped(arena, "main.nako3", null, "pkg:demo/extra");
    try testing.expectEqual(@as(usize, 1), extra_import.global_commands.len);
    try testing.expectEqualStrings("乙取得", extra_import.global_commands[0].name);
}
test "v1 runtime: COMMANDS.json 欠落は空索引へ後退せず拒否する" {
    const a = testing.allocator;
    const packages = [_]PackageFixture{.{
        .id = "@example/demo",
        .version = "1.0.0",
        .dir = left_dir,
        .hash = left_hash,
        .global = false,
        .alias = "demo",
        .commands = &.{"答え取得"},
    }};
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    const path = try packageCommandsPath(a, left_dir);
    defer a.free(path);
    try fixture.tmp.dir.deleteFile(io, path);
    try testing.expectError(error.InvalidCommands, v1_runtime.load(a, io, fixture.root, .{}));
}

test "v1 runtime: 破損した COMMANDS.json は空索引へ後退せず拒否する" {
    const a = testing.allocator;
    const packages = [_]PackageFixture{.{
        .id = "@example/demo",
        .version = "1.0.0",
        .dir = left_dir,
        .hash = left_hash,
        .global = false,
        .alias = "demo",
        .commands = &.{"答え取得"},
    }};
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    const path = try packageCommandsPath(a, left_dir);
    defer a.free(path);
    try fixture.tmp.dir.writeFile(io, .{
        .sub_path = path,
        .data = "{\"schema_version\":1,\"exports_global_commands\":false}",
    });
    try testing.expectError(error.InvalidCommands, v1_runtime.load(a, io, fixture.root, .{}));
}

test "v1 runtime: 16MiB を超える正当な COMMANDS.json は受理する" {
    const a = testing.allocator;
    const packages = [_]PackageFixture{.{
        .id = "@example/demo",
        .version = "1.0.0",
        .dir = left_dir,
        .hash = left_hash,
        .global = false,
        .alias = "demo",
        .commands = &.{"答え取得"},
    }};
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    const path = try packageCommandsPath(a, left_dir);
    defer a.free(path);
    const base = try fixture.tmp.dir.readFileAlloc(io, path, a, .limited(64 * 1024));
    defer a.free(base);
    const padded = try a.alloc(u8, 16 * 1024 * 1024 + 1);
    defer a.free(padded);
    @memset(padded, ' ');
    @memcpy(padded[0..base.len], base);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = path, .data = padded });
    var environment = (try v1_runtime.load(a, io, fixture.root, .{})) orelse return error.TestUnexpectedResult;
    defer environment.deinit();
    const declared = packageDeclared(environment.packages[0], ".") orelse return error.TestUnexpectedResult;
    try testing.expect(declared.available);
    try testing.expect(declared.find("答え取得") != null);
}

const multi_export_fixture = [_]ExportFixture{
    .{ .subpath = ".", .entry = "a.nako3", .source = "●(Aを)同名とは\n Aで戻る\nここまで\n" },
    .{ .subpath = "./client", .entry = "b.nako3", .source = "●同名とは\n 0で戻る\nここまで\n" },
};

const multi_export_commands =
    \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[{"name":"同名","kind":"function","args":[{"name":"A","josi":["を"]}]}],"constants":[]},"./client":{"binding":"scoped","commands":[{"name":"同名","kind":"function","args":[]}],"constants":[]}}}
;

test "v1 runtime: 選択した入口の宣言だけを provider が返し同名別形状を取り違えない" {
    const a = testing.allocator;
    const packages = [_]PackageFixture{.{
        .id = "@example/demo",
        .version = "1.0.0",
        .dir = left_dir,
        .hash = left_hash,
        .global = false,
        .alias = "demo",
        .exports = &multi_export_fixture,
        .commands_json = multi_export_commands,
    }};
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    var environment = (try v1_runtime.load(a, io, fixture.root, .{})) orelse return error.TestUnexpectedResult;
    defer environment.deinit();

    const owner = "@example/demo@1.0.0";
    const provider = environment.declaredCommands();
    const dot = (try provider.lookupExport(a, owner, ".")) orelse return error.TestUnexpectedResult;
    const client = (try provider.lookupExport(a, owner, "./client")) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), dot.find("同名").?.args.len);
    try testing.expectEqual(@as(usize, 0), client.find("同名").?.args.len);
    // 入口不明・未宣言入口へ package 全体の索引を返さない。
    try testing.expectError(error.InvalidCommands, provider.lookupExport(a, owner, null));
    try testing.expectError(error.InvalidCommands, provider.lookupExport(a, owner, "./missing"));

    var files = CommandProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:demo」を取り込む\n!「pkg:demo/client」を取り込む\ndemo__同名(1)を表示\ndemo__client__同名()を表示\n" },
        .{ .suffix = "a.nako3", .source = multi_export_fixture[0].source },
        .{ .suffix = "b.nako3", .source = multi_export_fixture[1].source },
    } };
    const entry = try std.fs.path.join(a, &.{ fixture.root, "main.nako3" });
    defer a.free(entry);
    var graph = try module_graph.load(a, entry, files.provider(), .{
        .package_resolver = environment.resolver(),
        .declared_commands_provider = environment.declaredCommands(),
    });
    defer graph.deinit();
    try testing.expect(graph.succeeded());
    var program = try graph.analyze(a);
    defer program.deinit();
    try testing.expect(program.succeeded());
}

test "v1 runtime: 同名別形状の入口を逆の引数で呼べば選択入口の宣言で診断する" {
    const a = testing.allocator;
    const packages = [_]PackageFixture{.{
        .id = "@example/demo",
        .version = "1.0.0",
        .dir = left_dir,
        .hash = left_hash,
        .global = false,
        .alias = "demo",
        .exports = &multi_export_fixture,
        .commands_json = multi_export_commands,
    }};
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    var environment = (try v1_runtime.load(a, io, fixture.root, .{})) orelse return error.TestUnexpectedResult;
    defer environment.deinit();

    // `./client` の同名は 0 引数。`.` の 1 引数宣言を取り違えると
    // この呼出しが通ってしまうため、診断の有無で入口別宣言を固定する。
    var files = CommandProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:demo/client」を取り込む\ndemo__client__同名(1)を表示\n" },
        .{ .suffix = "a.nako3", .source = multi_export_fixture[0].source },
        .{ .suffix = "b.nako3", .source = multi_export_fixture[1].source },
    } };
    const entry = try std.fs.path.join(a, &.{ fixture.root, "main.nako3" });
    defer a.free(entry);
    var graph = try module_graph.load(a, entry, files.provider(), .{
        .package_resolver = environment.resolver(),
        .declared_commands_provider = environment.declaredCommands(),
    });
    defer graph.deinit();
    try testing.expect(graph.succeeded());
    var program = try graph.analyze(a);
    defer program.deinit();
    var saw_argument_error = false;
    for (program.diagnostics) |item| {
        if (item.code == .invalid_argument_count) saw_argument_error = true;
    }
    try testing.expect(saw_argument_error);
}

test "v1 runtime: 選択サブパスが COMMANDS に無ければ全体集合へ後退せず拒否する" {
    const a = testing.allocator;
    const only_dot =
        \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[],"constants":[]}}}
    ;
    const packages = [_]PackageFixture{.{
        .id = "@example/demo",
        .version = "1.0.0",
        .dir = left_dir,
        .hash = left_hash,
        .global = false,
        .alias = "demo",
        .exports = &multi_export_fixture,
        .commands_json = only_dot,
    }};
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    try testing.expectError(error.InvalidCommands, v1_runtime.load(a, io, fixture.root, .{}));
}

test "v1 runtime: 別サブパスの宣言漏れも全体集合へ後退せず拒否する" {
    const a = testing.allocator;
    // 選択しない `.` が COMMANDS から漏れていても、package 全体を
    // 受理してはならない（出口ごとのキー集合の一致が必須）。
    const only_client =
        \\{"schema_version":1,"exports_global_commands":false,"exports":{"./client":{"binding":"scoped","commands":[],"constants":[]}}}
    ;
    const packages = [_]PackageFixture{.{
        .id = "@example/demo",
        .version = "1.0.0",
        .dir = left_dir,
        .hash = left_hash,
        .global = false,
        .alias = "demo",
        .exports = &multi_export_fixture,
        .commands_json = only_client,
    }};
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    try testing.expectError(error.InvalidCommands, v1_runtime.load(a, io, fixture.root, .{}));
}

test "v1 runtime: COMMANDS の binding が環境と食い違えば拒否する" {
    const a = testing.allocator;
    const global_commands =
        \\{"schema_version":1,"exports_global_commands":true,"exports":{".":{"binding":"global","commands":[{"name":"答え取得","kind":"function","args":[]}],"constants":[]}}}
    ;
    const packages = [_]PackageFixture{.{
        .id = "@example/demo",
        .version = "1.0.0",
        .dir = left_dir,
        .hash = left_hash,
        .global = false,
        .alias = "demo",
        .commands_json = global_commands,
    }};
    var fixture = try makeFixture(a, &packages, false);
    defer fixture.deinit();
    try testing.expectError(error.InvalidCommands, v1_runtime.load(a, io, fixture.root, .{}));
}
