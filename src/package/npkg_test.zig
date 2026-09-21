const std = @import("std");
const manifest_mod = @import("manifest.zig");
const npkg_metadata = @import("npkg_metadata.zig");
const npkg_files = @import("npkg_files.zig");
const npkg_commands = @import("npkg_commands.zig");
const npkg_commands_gen = @import("npkg_commands_gen.zig");
const diag = @import("diagnostics.zig");

const testing = std.testing;

fn parseMetadataOk(allocator: std.mem.Allocator, source: []const u8) !manifest_mod.Manifest {
    var list = diag.List.init(allocator);
    defer list.deinit();
    return manifest_mod.parseNpkgMetadata(allocator, source, &list);
}

fn parseMetadataErrCode(allocator: std.mem.Allocator, source: []const u8, code: []const u8) !void {
    var list = diag.List.init(allocator);
    defer list.deinit();
    try testing.expectError(error.InvalidManifest, manifest_mod.parseNpkgMetadata(allocator, source, &list));
    try testing.expect(list.find(code) != null);
}

fn parseFilesErrCode(allocator: std.mem.Allocator, source: []const u8, code: []const u8) !void {
    var list = diag.List.init(allocator);
    defer list.deinit();
    try testing.expectError(error.InvalidFiles, npkg_files.parse(allocator, source, &list));
    try testing.expect(list.find(code) != null);
}

fn parseCommandsErrCode(allocator: std.mem.Allocator, source: []const u8, code: []const u8) !void {
    var list = diag.List.init(allocator);
    defer list.deinit();
    try testing.expectError(error.InvalidCommands, npkg_commands.parse(allocator, source, &list));
    try testing.expect(list.find(code) != null);
}

fn emitToString(allocator: std.mem.Allocator, comptime emit_fn: anytype, arg: anytype) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try emit_fn(allocator, arg, &buffer.writer);
    return try allocator.dupe(u8, buffer.written());
}

const zero_digest = [_]u8{0} ** 32;

test "FILES.toml をソート済みで決定的に書き出す" {
    const entries = [_]npkg_files.FileEntry{
        .{ .path = "src/lib.nako3", .sha256 = zero_digest, .size = 5 },
        .{ .path = "src/index.nako3", .sha256 = [_]u8{1} ** 32, .size = 10 },
    };
    const allocator = testing.allocator;
    const text = try emitToString(allocator, npkg_files.emit, &entries);
    defer allocator.free(text);

    try testing.expectEqualStrings(
        \\schemaVersion = 1
        \\
        \\[[files]]
        \\path = "src/index.nako3"
        \\sha256 = "sha256:0101010101010101010101010101010101010101010101010101010101010101"
        \\size = 10
        \\
        \\[[files]]
        \\path = "src/lib.nako3"
        \\sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        \\size = 5
        \\
        \\
    , text);
}

test "FILES.toml を解析して往復する" {
    const allocator = testing.allocator;
    const source =
        \\schemaVersion = 1
        \\
        \\[[files]]
        \\path = "src/index.nako3"
        \\sha256 = "sha256:0101010101010101010101010101010101010101010101010101010101010101"
        \\size = 10
        \\
    ;
    var list = diag.List.init(allocator);
    defer list.deinit();
    var files = try npkg_files.parse(allocator, source, &list);
    defer files.deinit();
    try testing.expectEqual(@as(usize, 1), files.entries.len);
    try testing.expectEqualStrings("src/index.nako3", files.entries[0].path);
    try testing.expectEqual(@as(u64, 10), files.entries[0].size);
    try testing.expectEqual([_]u8{1} ** 32, files.entries[0].sha256);
}

test "FILES.toml の不正入力を診断する" {
    const allocator = testing.allocator;

    // 重複 path
    try parseFilesErrCode(allocator,
        \\schemaVersion = 1
        \\[[files]]
        \\path = "a.nako3"
        \\sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        \\size = 1
        \\[[files]]
        \\path = "a.nako3"
        \\sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        \\size = 1
        \\
    , diag.E038_NPKG_DUPLICATE_ENTRY);

    // 非正規 path
    try parseFilesErrCode(allocator,
        \\schemaVersion = 1
        \\[[files]]
        \\path = "../escape.nako3"
        \\sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        \\size = 1
        \\
    , diag.E040_NPKG_NONCANONICAL_PATH);

    // NAKO-PKG 配下は索引対象外
    try parseFilesErrCode(allocator,
        \\schemaVersion = 1
        \\[[files]]
        \\path = "NAKO-PKG/x.txt"
        \\sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        \\size = 1
        \\
    , diag.E040_NPKG_NONCANONICAL_PATH);

    // 不正 sha256
    try parseFilesErrCode(allocator,
        \\schemaVersion = 1
        \\[[files]]
        \\path = "a.nako3"
        \\sha256 = "deadbeef"
        \\size = 1
        \\
    , diag.E029_INVALID_VALUE);

    // size 欠落
    try parseFilesErrCode(allocator,
        \\schemaVersion = 1
        \\[[files]]
        \\path = "a.nako3"
        \\sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        \\
    , diag.E019_REQUIRED_FIELD_MISSING);

    // 未知 schemaVersion
    try parseFilesErrCode(allocator,
        \\schemaVersion = 2
        \\files = []
        \\
    , diag.E035_UNKNOWN_NPKG_SCHEMA);

    // 未知フィールド
    try parseFilesErrCode(allocator,
        \\schemaVersion = 1
        \\extra = 1
        \\files = []
        \\
    , diag.E022_UNKNOWN_FIELD);
}

test "規範 path 判定" {
    try testing.expect(npkg_files.isCanonicalPath("a/b/c.txt"));
    try testing.expect(npkg_files.isCanonicalPath("src/index.nako3"));
    try testing.expect(!npkg_files.isCanonicalPath(""));
    try testing.expect(!npkg_files.isCanonicalPath("/abs"));
    try testing.expect(!npkg_files.isCanonicalPath("a/"));
    try testing.expect(!npkg_files.isCanonicalPath("a//b"));
    try testing.expect(!npkg_files.isCanonicalPath("a/./b"));
    try testing.expect(!npkg_files.isCanonicalPath("a/../b"));
    try testing.expect(!npkg_files.isCanonicalPath("a\\b"));
    try testing.expect(!npkg_files.isCanonicalPath("a/b\x01"));
    try testing.expect(!npkg_files.isCanonicalPath("a/b\x7f"));
    try testing.expect(npkg_files.isMetadataPath("NAKO-PKG/METADATA.toml"));
    try testing.expect(!npkg_files.isMetadataPath("nako-pkg/x"));
}

test "commands.json をソート済みで決定的に書き出す" {
    const allocator = testing.allocator;
    const commands = [_]npkg_commands.Command{
        .{ .name = "足す", .args = &.{ "a", "b" }, .josi = &.{ "と", "に" } },
        .{ .name = "フラグ", .variable = true },
        .{ .name = "引く", .args = &.{"x"}, .josi = &.{"から"} },
    };
    const text = try emitToString(allocator, npkg_commands.emit, &commands);
    defer allocator.free(text);

    try testing.expectEqualStrings(
        "{\"schemaVersion\":1,\"commands\":[" ++
            "{\"name\":\"フラグ\",\"variable\":true}," ++
            "{\"name\":\"引く\",\"args\":[\"x\"],\"josi\":[\"から\"]}," ++
            "{\"name\":\"足す\",\"args\":[\"a\",\"b\"],\"josi\":[\"と\",\"に\"]}" ++
            "]}\n",
        text,
    );
}

test "commands.json を解析して検証する" {
    const allocator = testing.allocator;
    var list = diag.List.init(allocator);
    defer list.deinit();
    var commands = try npkg_commands.parse(allocator,
        \\{"schemaVersion":1,"commands":[
        \\  {"name":"引く","args":["x"],"josi":["から"]},
        \\  {"name":"フラグ","variable":true}
        \\]}
        \\
    , &list);
    defer commands.deinit();
    try testing.expectEqual(@as(usize, 2), commands.commands.len);
    try testing.expectEqualStrings("引く", commands.commands[0].name);
    try testing.expectEqualStrings("x", commands.commands[0].args[0]);
    try testing.expect(commands.commands[1].variable);
}

test "commands.json の不正入力を診断する" {
    const allocator = testing.allocator;

    // 未知 schemaVersion
    try parseCommandsErrCode(allocator,
        \\{"schemaVersion":2,"commands":[]}
        \\
    , diag.E035_UNKNOWN_NPKG_SCHEMA);

    // variable に args
    try parseCommandsErrCode(allocator,
        \\{"schemaVersion":1,"commands":[{"name":"x","variable":true,"args":["a"]}]}
        \\
    , diag.E029_INVALID_VALUE);

    // josi 数不一致
    try parseCommandsErrCode(allocator,
        \\{"schemaVersion":1,"commands":[{"name":"x","args":["a"],"josi":["と","に"]}]}
        \\
    , diag.E029_INVALID_VALUE);

    // name 欠落
    try parseCommandsErrCode(allocator,
        \\{"schemaVersion":1,"commands":[{"args":[]}]}
        \\
    , diag.E019_REQUIRED_FIELD_MISSING);

    // 未知フィールド
    try parseCommandsErrCode(allocator,
        \\{"schemaVersion":1,"commands":[{"name":"x","bogus":1}]}
        \\
    , diag.E022_UNKNOWN_FIELD);

    // JSON 構文エラー
    var list = diag.List.init(allocator);
    defer list.deinit();
    try testing.expectError(error.InvalidJson, npkg_commands.parse(allocator, "{not json", &list));
}

test "METADATA.toml を manifest から emit して往復する" {
    const allocator = testing.allocator;
    var list = diag.List.init(allocator);
    defer list.deinit();
    var manifest = try manifest_mod.parse(allocator,
        \\[package]
        \\name = "hello-pkg"
        \\version = "1.2.3"
        \\license = "MIT"
        \\description = "sample"
        \\authors = ["alice", "bob"]
        \\keywords = ["util"]
        \\nako-version = "3.7.24"
        \\runtimes = ["lnako", "cnako"]
        \\
        \\[package.engines]
        \\nako = ">=3.7.0"
        \\lnako = ">=0.1.0"
        \\
        \\[features]
        \\extra = ["dep"]
        \\
        \\[dependencies.pkg]
        \\dep = { version = "^1.0", features = ["f1"], prefer-native = true }
        \\
        \\[dependencies.path]
        \\local = { path = "vendor/local" }
        \\
        \\[dependencies.git]
        \\upstream = { url = "https://example.com/repo.git", commit = "0123456789abcdef0123456789abcdef01234567" }
        \\
        \\[dependencies.http]
        \\blob = { url = "https://example.com/blob.tar.gz", hash = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
        \\
        \\[[exports]]
        \\name = "main"
        \\path = "src/index.nako3"
        \\
        \\[[exports]]
        \\name = "plugin"
        \\native = [
        \\  { path = "lib/a.so", when = "os == 'linux'", libc = "gnu" },
        \\  { path = "lib/a.dylib", when = "os == 'macos'", min-os = "14.0" },
        \\]
        \\esm = "dist/x.mjs"
        \\
    , &list);
    defer manifest.deinit();

    const text = try npkg_metadata.toBytes(allocator, &manifest);
    defer allocator.free(text);

    var reparsed = try parseMetadataOk(allocator, text);
    defer reparsed.deinit();

    try testing.expect(reparsed.npkg != null);
    try testing.expectEqualStrings(manifest_mod.known_native_plugin_abi, reparsed.npkg.?.native_plugin_abi.?);
    try testing.expectEqualStrings("hello-pkg", reparsed.package.name);
    try testing.expectEqualStrings("MIT", reparsed.package.license);
    try testing.expectEqualStrings("sample", reparsed.package.description.?);
    try testing.expectEqual(@as(usize, 2), reparsed.package.authors.len);
    try testing.expectEqual(@as(usize, 2), reparsed.exports.len);
    // exports は名前順（main → plugin）
    try testing.expectEqualStrings("main", reparsed.exports[0].name);
    try testing.expectEqualStrings("plugin", reparsed.exports[1].name);
    const plugin = reparsed.exports[1];
    try testing.expectEqual(@as(usize, 2), plugin.native.len);
    try testing.expectEqualStrings("lib/a.so", plugin.native[0].path);
    try testing.expectEqualStrings("os == 'linux'", plugin.native[0].when.?);
    try testing.expectEqualStrings("gnu", plugin.native[0].libc.?);
    try testing.expectEqualStrings("14.0", plugin.native[1].min_os.?);
    try testing.expectEqual(@as(usize, 1), plugin.esm.len);
    try testing.expectEqualStrings("dist/x.mjs", plugin.esm[0].path);

    // 往復で同一バイト列になること
    const text2 = try npkg_metadata.toBytes(allocator, &reparsed);
    defer allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "METADATA.toml の .npkg 固有検証" {
    const allocator = testing.allocator;

    // schemaVersion 欠落
    try parseMetadataErrCode(allocator,
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
    , diag.E019_REQUIRED_FIELD_MISSING);

    // 未知 schemaVersion
    try parseMetadataErrCode(allocator,
        \\schemaVersion = 2
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
    , diag.E035_UNKNOWN_NPKG_SCHEMA);

    // dev-dependencies は .npkg メタデータの文法にない
    try parseMetadataErrCode(allocator,
        \\schemaVersion = 1
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dev-dependencies.pkg]
        \\dep = { version = "^1.0" }
        \\
    , diag.E022_UNKNOWN_FIELD);

    // native 宣言があるのに nativePluginAbi が無い
    try parseMetadataErrCode(allocator,
        \\schemaVersion = 1
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "p"
        \\native = "lib/x.so"
        \\
    , diag.E019_REQUIRED_FIELD_MISSING);

    // 未知 ABI
    try parseMetadataErrCode(allocator,
        \\schemaVersion = 1
        \\nativePluginAbi = "other_abi"
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
    , diag.E029_INVALID_VALUE);

    // native 宣言なしなら nativePluginAbi 不要
    var manifest = try parseMetadataOk(allocator,
        \\schemaVersion = 1
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
    );
    defer manifest.deinit();
    try testing.expect(manifest.npkg != null);
    try testing.expectEqual(@as(u32, 1), manifest.npkg.?.schema_version);
    try testing.expect(manifest.npkg.?.native_plugin_abi == null);
}

const MapProvider = struct {
    map: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator) !MapProvider {
        return .{ .map = std.StringHashMap([]const u8).init(allocator) };
    }

    fn deinit(self: *MapProvider) void {
        self.map.deinit();
    }

    fn put(self: *MapProvider, path: []const u8, source: []const u8) !void {
        try self.map.put(path, source);
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
        const self: *MapProvider = @ptrCast(@alignCast(context));
        const text = self.map.get(path) orelse return null;
        return try allocator.dupe(u8, text);
    }

    fn provider(self: *MapProvider) npkg_commands_gen.SourceProvider {
        return .{ .context = self, .readFn = read };
    }
};

test "commands.json を AST から生成する" {
    const allocator = testing.allocator;
    var provider = try MapProvider.init(allocator);
    defer provider.deinit();
    try provider.put("src/index.nako3",
        \\●(AをBと)合計とは
        \\  A+Bで戻る
        \\ここまで
        \\●{非公開}内部とは
        \\ここまで
        \\定数 公開フラグ{公開}=2
        \\変数 秘密{非公開}=1
        \\「lib/util.nako3」を取り込む
        \\
    );
    try provider.put("src/lib/util.nako3",
        \\●差分とは
        \\ここまで
        \\
    );

    var list = diag.List.init(allocator);
    defer list.deinit();
    var result = try npkg_commands_gen.generate(allocator, provider.provider(), &.{"src/index.nako3"}, &list);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.commands.len);
    var by_name = std.StringHashMap(npkg_commands.Command).init(allocator);
    defer by_name.deinit();
    for (result.commands) |command| try by_name.put(command.name, command);
    const add = by_name.get("合計").?;
    try testing.expectEqual(@as(usize, 2), add.args.len);
    try testing.expectEqualStrings("A", add.args[0]);
    try testing.expectEqualStrings("B", add.args[1]);
    try testing.expectEqual(@as(usize, 2), add.josi.len);
    try testing.expectEqualStrings("を", add.josi[0]);
    try testing.expectEqualStrings("と", add.josi[1]);
    try testing.expect(by_name.get("公開フラグ").?.variable);
    try testing.expect(by_name.get("差分") != null);
    try testing.expect(by_name.get("内部") == null);
    try testing.expect(by_name.get("秘密") == null);
}

test "commands.json 生成はルート外 import を拒否する" {
    const allocator = testing.allocator;
    var provider = try MapProvider.init(allocator);
    defer provider.deinit();
    try provider.put("index.nako3",
        \\「../outside.nako3」を取り込む
        \\
    );
    var list = diag.List.init(allocator);
    defer list.deinit();
    try testing.expectError(
        error.InvalidCommands,
        npkg_commands_gen.generate(allocator, provider.provider(), &.{"index.nako3"}, &list),
    );
    try testing.expect(list.find(diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY) != null);
}

test "commands.json 生成は欠落ソースとパース失敗を診断する" {
    const allocator = testing.allocator;
    var provider = try MapProvider.init(allocator);
    defer provider.deinit();
    var list = diag.List.init(allocator);
    defer list.deinit();
    try testing.expectError(
        error.InvalidCommands,
        npkg_commands_gen.generate(allocator, provider.provider(), &.{"missing.nako3"}, &list),
    );
    try testing.expect(list.find(diag.E036_NPKG_MISSING_ENTRY) != null);
}

test "import path をパッケージ相対へ解決する" {
    const allocator = testing.allocator;
    const resolved = (try npkg_commands_gen.resolveImport(allocator, "src/index.nako3", "lib/./util.nako3")).?;
    defer allocator.free(resolved);
    try testing.expectEqualStrings("src/lib/util.nako3", resolved);
    const up = (try npkg_commands_gen.resolveImport(allocator, "src/sub/a.nako3", "../b.nako3")).?;
    defer allocator.free(up);
    try testing.expectEqualStrings("src/b.nako3", up);
    try testing.expect((try npkg_commands_gen.resolveImport(allocator, "a.nako3", "../x.nako3")) == null);
}
