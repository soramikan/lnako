const std = @import("std");
const manifest_mod = @import("manifest.zig");
const npkg_metadata = @import("npkg_metadata.zig");
const npkg_files = @import("npkg_files.zig");
const npkg_commands = @import("npkg_commands.zig");
const npkg_commands_gen = @import("npkg_commands_gen.zig");
const npkg_build = @import("npkg_build.zig");
const npkg_verify = @import("npkg_verify.zig");
const semver = @import("semver.zig");
const zip = @import("../archive/zip.zig");
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

    // [package] の include/schema-version は manifest 専用で、配布
    // メタデータ（npkg-metadata.schema.json）では未知フィールド
    try parseMetadataErrCode(allocator,
        \\schemaVersion = 1
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\include = ["src/**"]
        \\
    , diag.E022_UNKNOWN_FIELD);
    try parseMetadataErrCode(allocator,
        \\schemaVersion = 1
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\schema-version = 1
        \\
    , diag.E022_UNKNOWN_FIELD);

    // artifact 宣言の features も feature 名規則で検査する
    try parseMetadataErrCode(allocator,
        \\schemaVersion = 1
        \\nativePluginAbi = "lnako_plugin_v1"
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "p"
        \\native = [{ path = "x.so", features = ["bad name"] }]
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

test "commands.json 生成は文の子孫にある取り込みも辿る" {
    const allocator = testing.allocator;
    var provider = try MapProvider.init(allocator);
    defer provider.deinit();
    // 条件分岐と関数本体内の静的取り込みは module_graph 上も依存辺になる
    // ため、索引の閉包に含める必要がある。
    try provider.put("src/index.nako3",
        \\もし、1=1ならば
        \\  「lib/util.nako3」を取り込む
        \\ここまで
        \\●(AをBと)合計とは
        \\  A+Bで戻る
        \\ここまで
        \\
    );
    try provider.put("src/lib/util.nako3",
        \\●変換とは
        \\ここまで
        \\
    );

    var list = diag.List.init(allocator);
    defer list.deinit();
    var result = try npkg_commands_gen.generate(allocator, provider.provider(), &.{"src/index.nako3"}, &list);
    defer result.deinit();

    var by_name = std.StringHashMap(npkg_commands.Command).init(allocator);
    defer by_name.deinit();
    for (result.commands) |command| try by_name.put(command.name, command);
    try testing.expect(by_name.get("合計") != null);
    try testing.expect(by_name.get("変換") != null);
}

test "commands.json は同名定義の先勝ちを固定する" {
    const allocator = testing.allocator;
    var provider = try MapProvider.init(allocator);
    defer provider.deinit();
    // 索引は識別子参照のため重複を持たず、入口の走査順で最初の定義を採用する。
    try provider.put("a.nako3",
        \\●(AをBに)加算とは
        \\  A+Bで戻る
        \\ここまで
        \\
    );
    try provider.put("b.nako3",
        \\●(Aを)加算とは
        \\  A*2で戻る
        \\ここまで
        \\
    );

    var list = diag.List.init(allocator);
    defer list.deinit();
    var result = try npkg_commands_gen.generate(allocator, provider.provider(), &.{ "a.nako3", "b.nako3" }, &list);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.commands.len);
    try testing.expectEqualStrings("加算", result.commands[0].name);
    try testing.expectEqual(@as(usize, 2), result.commands[0].args.len);
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
    // 絶対パス・バックスラッシュ・空成分は package 相対の規範形式でないため拒否
    try testing.expect((try npkg_commands_gen.resolveImport(allocator, "src/index.nako3", "/util.nako3")) == null);
    try testing.expect((try npkg_commands_gen.resolveImport(allocator, "src/index.nako3", "lib\\util.nako3")) == null);
    try testing.expect((try npkg_commands_gen.resolveImport(allocator, "src/index.nako3", "lib//util.nako3")) == null);
    try testing.expect((try npkg_commands_gen.resolveImport(allocator, "src/index.nako3", "lib/")) == null);
}

fn tmpRoot(temporary: *std.testing.TmpDir, allocator: std.mem.Allocator) ![:0]u8 {
    return temporary.dir.realPathFileAlloc(std.testing.io, "pkg", allocator);
}

fn writeDemoPackage(temporary: *std.testing.TmpDir) !void {
    const io = std.testing.io;
    try temporary.dir.createDirPath(io, "pkg/src");
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/nako.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/index.nako3"
        \\
        ,
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/src/index.nako3",
        .data = "●(AをBと)合計とは\n  A+Bで戻る\nここまで\n",
    });
}

test "npkg build は決定的なアーカイブを生成する" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeDemoPackage(&temporary);
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = try npkg_build.build(allocator, io, root, &list, .{});
    defer built.deinit();
    var rebuilt = try npkg_build.build(allocator, io, root, &list, .{});
    defer rebuilt.deinit();
    try testing.expectEqualStrings(built.archive, rebuilt.archive);

    // 必須エントリと payload が格納されている。
    for ([_][]const u8{
        "NAKO-PKG/METADATA.toml",
        "NAKO-PKG/FILES.toml",
        "NAKO-PKG/commands.json",
        "nako.toml",
        "src/index.nako3",
    }) |name| {
        try testing.expect(std.mem.indexOf(u8, built.archive, name) != null);
    }
    try testing.expectEqual(@as(usize, 2), built.files.len);

    // 展開して commands.json の内容を確認する。
    try temporary.dir.writeFile(io, .{ .sub_path = "out.npkg", .data = built.archive });
    const archive_path = try temporary.dir.realPathFileAlloc(io, "out.npkg", allocator);
    defer allocator.free(archive_path);
    const extract_root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(extract_root);
    const extracted = try std.fs.path.join(allocator, &.{ extract_root, "extracted" });
    defer allocator.free(extracted);
    try zip.extract(io, archive_path, extracted);
    const commands_path = try std.fs.path.join(allocator, &.{ extracted, "NAKO-PKG", "commands.json" });
    defer allocator.free(commands_path);
    const commands_bytes = try std.Io.Dir.cwd().readFileAlloc(io, commands_path, allocator, .limited(1 << 20));
    defer allocator.free(commands_bytes);
    var parsed = try npkg_commands.parse(allocator, commands_bytes, &list);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.commands.len);
    try testing.expectEqualStrings("合計", parsed.commands[0].name);
}

test "npkg build は include 指定で対象を絞る" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeDemoPackage(&temporary);
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/extra.txt", .data = "x" });
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = try npkg_build.build(allocator, io, root, &list, .{});
    defer built.deinit();
    // include 未指定: nako.toml・src/index.nako3・extra.txt の3件。
    try testing.expectEqual(@as(usize, 3), built.files.len);

    const include_source =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\include = ["src/**"]
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/index.nako3"
        \\
    ;
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/nako.toml", .data = include_source });
    var narrowed = try npkg_build.build(allocator, io, root, &list, .{});
    defer narrowed.deinit();
    try testing.expectEqual(@as(usize, 1), narrowed.files.len);
    try testing.expectEqualStrings("src/index.nako3", narrowed.files[0].path);
}

test "npkg build は宣言 export の未収録と境界外 path 依存を拒否する" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg");
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/nako.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\sibling = { path = "../sibling" }
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/missing.nako3"
        \\
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/index.nako3", .data = "" });
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = npkg_build.build(allocator, io, root, &list, .{}) catch |err| {
        try testing.expectEqual(error.InvalidPackage, err);
        try testing.expect(list.find(diag.E036_NPKG_MISSING_ENTRY) != null);
        try testing.expect(list.find(diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY) != null);
        return;
    };
    defer built.deinit();
    return error.TestUnexpectedResult;
}

fn emitFilesToml(allocator: std.mem.Allocator, entries: []const npkg_files.FileEntry) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try npkg_files.emit(allocator, entries, &buffer.writer);
    return buffer.toOwnedSlice();
}

fn sha256Of(data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return digest;
}

const minimal_metadata =
    \\schemaVersion = 1
    \\
    \\[package]
    \\name = "x"
    \\version = "1.0.0"
    \\license = "MIT"
    \\
;

const empty_commands = "{\"schemaVersion\":1,\"commands\":[]}\n";

test "npkg verify は build 生成物を受理する" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeDemoPackage(&temporary);
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = try npkg_build.build(allocator, io, root, &list, .{});
    defer built.deinit();

    var verified = try npkg_verify.verify(allocator, built.archive, .{
        .runtime = "lnako",
        .os = "macos",
        .cpu = "aarch64",
        .abi = "gnu",
    }, &list);
    defer verified.deinit();
    try testing.expectEqualStrings("demo", verified.manifest.package.name);
    try testing.expectEqual(@as(usize, 2), verified.files.len);
    try testing.expectEqual(@as(usize, 1), verified.commands.len);
    try testing.expectEqualStrings("合計", verified.commands[0].name);
}

test "npkg verify は hash 不一致を拒否する" {
    const allocator = testing.allocator;
    var list = diag.List.init(allocator);
    defer list.deinit();

    const files_toml = try emitFilesToml(allocator, &.{
        .{ .path = "a.txt", .sha256 = sha256Of("tampered"), .size = 5 },
    });
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = minimal_metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
        .{ .name = "a.txt", .data = "hello" },
    });
    defer allocator.free(archive);

    try testing.expectError(error.InvalidPackage, npkg_verify.verify(allocator, archive, .{}, &list));
    try testing.expect(list.find(diag.E009_HASH_MISMATCH) != null);
}

test "npkg verify は未収録 payload を拒否する" {
    const allocator = testing.allocator;
    var list = diag.List.init(allocator);
    defer list.deinit();

    const files_toml = try emitFilesToml(allocator, &.{});
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = minimal_metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
        .{ .name = "unlisted.txt", .data = "x" },
    });
    defer allocator.free(archive);

    try testing.expectError(error.InvalidPackage, npkg_verify.verify(allocator, archive, .{}, &list));
    try testing.expect(list.find(diag.E037_NPKG_UNLISTED_ENTRY) != null);
}

test "npkg verify は必須エントリの欠落を拒否する" {
    const allocator = testing.allocator;
    var list = diag.List.init(allocator);
    defer list.deinit();

    const files_toml = try emitFilesToml(allocator, &.{});
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = minimal_metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
    });
    defer allocator.free(archive);

    try testing.expectError(error.InvalidPackage, npkg_verify.verify(allocator, archive, .{}, &list));
    try testing.expect(list.find(diag.E036_NPKG_MISSING_ENTRY) != null);
}

test "npkg verify は runtime 不適合を拒否する" {
    const allocator = testing.allocator;
    var list = diag.List.init(allocator);
    defer list.deinit();

    const metadata =
        \\schemaVersion = 1
        \\
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\runtimes = ["cnako"]
        \\
    ;
    const payload = "x";
    const files_toml = try emitFilesToml(allocator, &.{
        .{ .path = "a.txt", .sha256 = sha256Of(payload), .size = payload.len },
    });
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
        .{ .name = "a.txt", .data = payload },
    });
    defer allocator.free(archive);

    try testing.expectError(error.InvalidPackage, npkg_verify.verify(allocator, archive, .{ .runtime = "lnako" }, &list));
    try testing.expect(list.find(diag.E031_UNSUPPORTED_RUNTIME) != null);
}

/// cwd から上方向に conformance fixture ルートを探す（manifest_test と同規則）。
fn openRepoRoot(io: std.Io) !std.Io.Dir {
    const probe = "tools/package-system/conformance/valid/manifest/minimal/nako.toml";
    var prefix: []const u8 = ".";
    for (0..8) |_| {
        var candidate = try std.Io.Dir.cwd().openDir(io, prefix, .{});
        if (candidate.openFile(io, probe, .{})) |file| {
            file.close(io);
            return candidate;
        } else |_| {
            candidate.close(io);
        }
        prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}/..", .{prefix});
    }
    return error.FileNotFound;
}

test "npkg適合fixtureを解析できる" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var repo = try openRepoRoot(io);
    defer repo.close(io);

    const metadata_cases = [_][]const u8{
        "tools/package-system/conformance/valid/npkg/source-only/METADATA.toml",
        "tools/package-system/conformance/valid/npkg/native/METADATA.toml",
        "tools/package-system/conformance/valid/npkg/esm/METADATA.toml",
    };
    for (metadata_cases) |case| {
        const source = try repo.readFileAlloc(io, case, allocator, .limited(1 << 20));
        defer allocator.free(source);
        var list = diag.List.init(allocator);
        defer list.deinit();
        var manifest = npkg_metadata.parse(allocator, source, &list) catch |err| {
            for (list.items.items) |item| std.debug.print("{s}: {s} {s}\n", .{ case, item.code, item.message });
            return err;
        };
        defer manifest.deinit();
        try testing.expect(manifest.npkg != null);
    }

    const files_cases = [_][]const u8{
        "tools/package-system/conformance/valid/npkg/source-only/FILES.toml",
        "tools/package-system/conformance/valid/npkg/files/FILES.toml",
    };
    for (files_cases) |case| {
        const source = try repo.readFileAlloc(io, case, allocator, .limited(1 << 20));
        defer allocator.free(source);
        var list = diag.List.init(allocator);
        defer list.deinit();
        var files = try npkg_files.parse(allocator, source, &list);
        defer files.deinit();
        try testing.expect(files.entries.len > 0);
    }

    const commands_cases = [_][]const u8{
        "tools/package-system/conformance/valid/npkg/source-only/commands.json",
        "tools/package-system/conformance/valid/npkg/commands/commands.json",
    };
    for (commands_cases) |case| {
        const source = try repo.readFileAlloc(io, case, allocator, .limited(1 << 20));
        defer allocator.free(source);
        var list = diag.List.init(allocator);
        defer list.deinit();
        var commands = try npkg_commands.parse(allocator, source, &list);
        defer commands.deinit();
        try testing.expect(commands.commands.len > 0);
    }
}

test "npkg verify は宣言 export の未収録を拒否する" {
    const allocator = testing.allocator;
    var list = diag.List.init(allocator);
    defer list.deinit();

    // export は src/missing.nako3 と lib/x.so を宣言するが、索引と
    // payload には無関係な a.txt のみ存在する。
    const metadata =
        \\schemaVersion = 1
        \\nativePluginAbi = "lnako_plugin_v1"
        \\
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "main"
        \\path = "src/missing.nako3"
        \\
        \\[[exports]]
        \\name = "plugin"
        \\native = "lib/x.so"
        \\
    ;
    const payload = "x";
    const files_toml = try emitFilesToml(allocator, &.{
        .{ .path = "a.txt", .sha256 = sha256Of(payload), .size = payload.len },
    });
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
        .{ .name = "a.txt", .data = payload },
    });
    defer allocator.free(archive);

    try testing.expectError(error.InvalidPackage, npkg_verify.verify(allocator, archive, .{}, &list));
    try testing.expect(list.find(diag.E036_NPKG_MISSING_ENTRY) != null);
}

/// `name` を持つ local header のオフセットを返す。
fn findLocalHeader(archive: []u8, name: []const u8) ?usize {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, archive, offset, "\x50\x4b\x03\x04")) |lh| {
        const name_len = std.mem.readInt(u16, archive[lh + 26 ..][0..2], .little);
        if (std.mem.eql(u8, archive[lh + 30 .. lh + 30 + name_len], name)) return lh;
        offset = lh + 1;
    }
    return null;
}

/// `name` を持つ central directory エントリのオフセットを返す。
fn findCentralEntry(archive: []u8, name: []const u8) ?usize {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, archive, offset, "\x50\x4b\x01\x02")) |cd| {
        const name_len = std.mem.readInt(u16, archive[cd + 28 ..][0..2], .little);
        if (std.mem.eql(u8, archive[cd + 46 .. cd + 46 + name_len], name)) return cd;
        offset = cd + 1;
    }
    return null;
}

fn verifyArchive(allocator: std.mem.Allocator, archive: []const u8) !diag.List {
    var list = diag.List.init(allocator);
    errdefer list.deinit();
    try testing.expectError(error.InvalidPackage, npkg_verify.verify(allocator, archive, .{}, &list));
    return list;
}

fn minimalArchive(allocator: std.mem.Allocator) ![]u8 {
    const payload = "x";
    const files_toml = try emitFilesToml(allocator, &.{
        .{ .path = "a.txt", .sha256 = sha256Of(payload), .size = payload.len },
    });
    defer allocator.free(files_toml);
    return zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = minimal_metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
        .{ .name = "a.txt", .data = payload },
    });
}

test "npkg verify は local header 名と central 名の不一致を拒否する" {
    const allocator = testing.allocator;
    const archive = try minimalArchive(allocator);
    defer allocator.free(archive);

    // a.txt の local header 名だけを同長の b.txt へ書き換える。
    const lh = findLocalHeader(archive, "a.txt").?;
    @memcpy(archive[lh + 30 .. lh + 30 + 5], "b.txt");

    var list = try verifyArchive(allocator, archive);
    defer list.deinit();
    try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
}

test "npkg verify は stored 以外の圧縮を拒否する" {
    const allocator = testing.allocator;
    const archive = try minimalArchive(allocator);
    defer allocator.free(archive);

    // a.txt の method を deflate(8) へ書き換える（local + central 双方）。
    const cd = findCentralEntry(archive, "a.txt").?;
    std.mem.writeInt(u16, archive[cd + 10 ..][0..2], 8, .little);
    const lh = findLocalHeader(archive, "a.txt").?;
    std.mem.writeInt(u16, archive[lh + 8 ..][0..2], 8, .little);

    var list = try verifyArchive(allocator, archive);
    defer list.deinit();
    try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
}

test "npkg verify は非正規形の ZIP を拒否する" {
    const allocator = testing.allocator;

    // UTF-8 フラグを落とした central エントリは正規形でない。
    {
        const archive = try minimalArchive(allocator);
        defer allocator.free(archive);
        const cd = findCentralEntry(archive, "a.txt").?;
        std.mem.writeInt(u16, archive[cd + 8 ..][0..2], 0, .little);
        var list = try verifyArchive(allocator, archive);
        defer list.deinit();
        try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
    }
    // timestamp がゼロでないエントリは正規形でない。
    {
        const archive = try minimalArchive(allocator);
        defer allocator.free(archive);
        const cd = findCentralEntry(archive, "a.txt").?;
        std.mem.writeInt(u16, archive[cd + 12 ..][0..2], 1, .little);
        var list = try verifyArchive(allocator, archive);
        defer list.deinit();
        try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
    }
    // EOCD 後の余剰バイトは正規形でない。
    {
        const archive = try minimalArchive(allocator);
        defer allocator.free(archive);
        const padded = try allocator.alloc(u8, archive.len + 4);
        defer allocator.free(padded);
        @memcpy(padded[0..archive.len], archive);
        @memcpy(padded[archive.len..], "junk");
        var list = try verifyArchive(allocator, padded);
        defer list.deinit();
        try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
    }
    // 細工された local_offset（u32 上限付近）でパニックせず診断を返す。
    {
        const archive = try minimalArchive(allocator);
        defer allocator.free(archive);
        const cd = findCentralEntry(archive, "a.txt").?;
        std.mem.writeInt(u32, archive[cd + 42 ..][0..4], 0xfffffff0, .little);
        var list = try verifyArchive(allocator, archive);
        defer list.deinit();
        try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
    }
}

test "npkg verify は言語版と処理系版を独立に検査する" {
    const allocator = testing.allocator;
    const metadata =
        \\schemaVersion = 1
        \\
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[package.engines]
        \\nako = ">=3.7.0"
        \\lnako = ">=0.1.0"
        \\
    ;
    const payload = "x";
    const files_toml = try emitFilesToml(allocator, &.{
        .{ .path = "a.txt", .sha256 = sha256Of(payload), .size = payload.len },
    });
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
        .{ .name = "a.txt", .data = payload },
    });
    defer allocator.free(archive);

    // lnako 0.2.0 向けに処理系版だけ指定すれば、言語版制約（>=3.7.0）は
    // 未検査で通る。同じ値を両方へ流用すると 0.2.0 が nako 制約で誤拒否
    // される（回帰）。
    var list = diag.List.init(allocator);
    defer list.deinit();
    var verified = try npkg_verify.verify(allocator, archive, .{
        .runtime = "lnako",
        .lnako_version = try semver.Version.parse("0.2.0"),
    }, &list);
    defer verified.deinit();

    // 言語版が制約未満なら処理系版を満たしても拒否される。
    var failing = diag.List.init(allocator);
    defer failing.deinit();
    try testing.expectError(error.InvalidPackage, npkg_verify.verify(allocator, archive, .{
        .runtime = "lnako",
        .nako_version = try semver.Version.parse("3.0.0"),
        .lnako_version = try semver.Version.parse("0.2.0"),
    }, &failing));
    try testing.expect(failing.find(diag.E032_ENGINE_MISMATCH) != null);
}

test "npkg verify は directory エントリを拒否する" {
    const allocator = testing.allocator;
    const payload = "x";
    const files_toml = try emitFilesToml(allocator, &.{
        .{ .path = "a.txt", .sha256 = sha256Of(payload), .size = payload.len },
    });
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = minimal_metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
        .{ .name = "a.txt", .data = payload },
        .{ .name = "sub/", .data = "", .is_directory = true },
    });
    defer allocator.free(archive);

    var list = try verifyArchive(allocator, archive);
    defer list.deinit();
    try testing.expect(list.find(diag.E040_NPKG_NONCANONICAL_PATH) != null);
}

test "npkg build は出力予定の .npkg を収録しない" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeDemoPackage(&temporary);
    // 前回ビルドの残存成果物を root 内へ置く。
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/demo-1.0.0.npkg", .data = "stale" });
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    const output = try std.fs.path.join(allocator, &.{ root, "demo-1.0.0.npkg" });
    defer allocator.free(output);
    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = try npkg_build.build(allocator, io, root, &list, .{ .output = output });
    defer built.deinit();

    // 出力先は除外され nako.toml・src/index.nako3 の2件のみ。
    try testing.expectEqual(@as(usize, 2), built.files.len);
    for (built.files) |file| {
        try testing.expect(!std.mem.endsWith(u8, file.path, ".npkg"));
    }
}

test "npkg build は include 指定時に既定除外を適用しない" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeDemoPackage(&temporary);
    try temporary.dir.createDirPath(io, "pkg/.nako");
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/.nako/data.json", .data = "{}" });
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/nako.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\include = ["src/**", ".nako/**"]
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/index.nako3"
        \\
        ,
    });
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = try npkg_build.build(allocator, io, root, &list, .{});
    defer built.deinit();

    // 明示 include により既定除外の .nako 配下も収録される。
    try testing.expectEqual(@as(usize, 2), built.files.len);
    try testing.expectEqualStrings(".nako/data.json", built.files[0].path);
    try testing.expectEqualStrings("src/index.nako3", built.files[1].path);
}

test "npkg build は絶対パスの依存を拒否する" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg");
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/nako.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\local = { path = "/opt/localdep" }
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/index.nako3"
        \\
        ,
    });
    try temporary.dir.createDirPath(io, "pkg/src");
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/src/index.nako3", .data = "" });
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = npkg_build.build(allocator, io, root, &list, .{}) catch |err| {
        try testing.expectEqual(error.InvalidPackage, err);
        try testing.expect(list.find(diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY) != null);
        return;
    };
    defer built.deinit();
    return error.TestUnexpectedResult;
}

test "npkg build は export されないソースの命令を索引しない" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeDemoPackage(&temporary);
    // export されず import もされない内部補助ソース。
    try temporary.dir.createDirPath(io, "pkg/tests");
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/tests/helper.nako3",
        .data = "●補助とは\nここまで\n",
    });
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = try npkg_build.build(allocator, io, root, &list, .{});
    defer built.deinit();

    // tests/helper.nako3 は payload に収録されるが commands.json の
    // 索引対象にはならない。
    try testing.expectEqual(@as(usize, 3), built.files.len);
    try temporary.dir.writeFile(io, .{ .sub_path = "out2.npkg", .data = built.archive });
    const archive_path = try temporary.dir.realPathFileAlloc(io, "out2.npkg", allocator);
    defer allocator.free(archive_path);
    const extract_root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(extract_root);
    const extracted = try std.fs.path.join(allocator, &.{ extract_root, "extracted2" });
    defer allocator.free(extracted);
    try zip.extract(io, archive_path, extracted);
    const commands_path = try std.fs.path.join(allocator, &.{ extracted, "NAKO-PKG", "commands.json" });
    defer allocator.free(commands_path);
    const commands_bytes = try std.Io.Dir.cwd().readFileAlloc(io, commands_path, allocator, .limited(1 << 20));
    defer allocator.free(commands_bytes);
    var parsed = try npkg_commands.parse(allocator, commands_bytes, &list);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.commands.len);
    try testing.expectEqualStrings("合計", parsed.commands[0].name);
}

test "npkg build は include で除外された import 先を拒否する" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/nako.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\include = ["src/index.nako3"]
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/index.nako3"
        \\
        ,
    });
    // src/util.nako3 は include に合致せず payload へ入らない。
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/src/index.nako3",
        .data = "「src/util.nako3」を取り込む\n",
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/src/util.nako3",
        .data = "●補助とは\nここまで\n",
    });
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = npkg_build.build(allocator, io, root, &list, .{}) catch |err| {
        try testing.expectEqual(error.InvalidPackage, err);
        try testing.expect(list.find(diag.E036_NPKG_MISSING_ENTRY) != null);
        return;
    };
    defer built.deinit();
    return error.TestUnexpectedResult;
}

test "npkg verify は CRC-32 の不一致を拒否する" {
    const allocator = testing.allocator;

    // central directory 側だけ壊した場合（local header との不一致）。
    {
        const archive = try minimalArchive(allocator);
        defer allocator.free(archive);
        const cd = findCentralEntry(archive, "a.txt").?;
        std.mem.writeInt(u32, archive[cd + 16 ..][0..4], 0xdeadbeef, .little);
        var list = try verifyArchive(allocator, archive);
        defer list.deinit();
        try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
    }
    // local と central を同じ不正値へ揃えても実データの CRC と不一致。
    // SHA-256 が正しくても展開側は CRC を検査するため受理できない。
    {
        const archive = try minimalArchive(allocator);
        defer allocator.free(archive);
        const cd = findCentralEntry(archive, "a.txt").?;
        std.mem.writeInt(u32, archive[cd + 16 ..][0..4], 0xdeadbeef, .little);
        const lh = findLocalHeader(archive, "a.txt").?;
        std.mem.writeInt(u32, archive[lh + 14 ..][0..4], 0xdeadbeef, .little);
        var list = try verifyArchive(allocator, archive);
        defer list.deinit();
        try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
    }
}

test "npkg verify は local record の非正規配置を拒否する" {
    const allocator = testing.allocator;
    const payload = "x";
    const files_toml = try emitFilesToml(allocator, &.{
        .{ .path = "a.txt", .sha256 = sha256Of(payload), .size = payload.len },
        .{ .path = "b.txt", .sha256 = sha256Of(payload), .size = payload.len },
    });
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = minimal_metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
        .{ .name = "a.txt", .data = payload },
        .{ .name = "b.txt", .data = payload },
    });
    defer allocator.free(archive);

    // a.txt と b.txt の local record（同じ 36 バイト）を物理的に入れ替え、
    // central directory の local_offset だけ追随させる。名前・CRC・hash は
    // 全て正しいままだが、local record が名前順でない正規形違反。
    const la = findLocalHeader(archive, "a.txt").?;
    const lb = findLocalHeader(archive, "b.txt").?;
    const record_len = 30 + 5 + 1;
    var swap_buffer: [64]u8 = undefined;
    @memcpy(swap_buffer[0..record_len], archive[la .. la + record_len]);
    @memcpy(archive[la .. la + record_len], archive[lb .. lb + record_len]);
    @memcpy(archive[lb .. lb + record_len], swap_buffer[0..record_len]);
    const ca = findCentralEntry(archive, "a.txt").?;
    std.mem.writeInt(u32, archive[ca + 42 ..][0..4], @intCast(lb), .little);
    const cb = findCentralEntry(archive, "b.txt").?;
    std.mem.writeInt(u32, archive[cb + 42 ..][0..4], @intCast(la), .little);

    var list = try verifyArchive(allocator, archive);
    defer list.deinit();
    try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
}

test "npkg verify は payload を持たないアーカイブを拒否する" {
    const allocator = testing.allocator;
    // メタデータ3エントリのみ・索引も空の構造的に正しいアーカイブ。
    const files_toml = try emitFilesToml(allocator, &.{});
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = minimal_metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
    });
    defer allocator.free(archive);

    var list = try verifyArchive(allocator, archive);
    defer list.deinit();
    try testing.expect(list.find(diag.E036_NPKG_MISSING_ENTRY) != null);
}

test "npkg verify は索引に無い path 依存を拒否する" {
    const allocator = testing.allocator;
    const metadata =
        \\schemaVersion = 1
        \\
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.path]
        \\local = { path = "vendor/local" }
        \\
    ;
    const payload = "x";
    const files_toml = try emitFilesToml(allocator, &.{
        .{ .path = "a.txt", .sha256 = sha256Of(payload), .size = payload.len },
    });
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
        .{ .name = "a.txt", .data = payload },
    });
    defer allocator.free(archive);

    var list = try verifyArchive(allocator, archive);
    defer list.deinit();
    try testing.expect(list.find(diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY) != null);
}

test "npkg verify は feature 要求を推移展開して artifact を照合する" {
    const allocator = testing.allocator;
    const metadata =
        \\schemaVersion = 1
        \\nativePluginAbi = "lnako_plugin_v1"
        \\
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[features]
        \\full = ["child"]
        \\child = []
        \\
        \\[[exports]]
        \\name = "plugin"
        \\native = [{ path = "lib/x.so", features = ["child"] }]
        \\
    ;
    const payload = "x";
    const files_toml = try emitFilesToml(allocator, &.{
        .{ .path = "lib/x.so", .sha256 = sha256Of(payload), .size = payload.len },
    });
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
        .{ .name = "lib/x.so", .data = payload },
    });
    defer allocator.free(archive);

    // "full" の推移展開で "child" が有効になり native artifact が適合する。
    var list = diag.List.init(allocator);
    defer list.deinit();
    var verified = try npkg_verify.verify(allocator, archive, .{
        .features = &.{"full"},
    }, &list);
    defer verified.deinit();

    // 展開しない要求名だけでは "child" を満たせず不適合。
    var failing = diag.List.init(allocator);
    defer failing.deinit();
    try testing.expectError(error.InvalidPackage, npkg_verify.verify(allocator, archive, .{}, &failing));
    try testing.expect(failing.find(diag.E015_NATIVE_FOR_INCOMPATIBLE_TARGET) != null);
}

test "npkg verify は default feature を有効化・無効化できる" {
    const allocator = testing.allocator;
    const metadata =
        \\schemaVersion = 1
        \\nativePluginAbi = "lnako_plugin_v1"
        \\
        \\[package]
        \\name = "x"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[features]
        \\default = ["child"]
        \\child = []
        \\
        \\[[exports]]
        \\name = "plugin"
        \\native = [{ path = "lib/x.so", features = ["child"] }]
        \\
    ;
    const payload = "x";
    const files_toml = try emitFilesToml(allocator, &.{
        .{ .path = "lib/x.so", .sha256 = sha256Of(payload), .size = payload.len },
    });
    defer allocator.free(files_toml);
    const archive = try zip.writeEntries(allocator, &.{
        .{ .name = "NAKO-PKG/METADATA.toml", .data = metadata },
        .{ .name = "NAKO-PKG/FILES.toml", .data = files_toml },
        .{ .name = "NAKO-PKG/commands.json", .data = empty_commands },
        .{ .name = "lib/x.so", .data = payload },
    });
    defer allocator.free(archive);

    // 既定では default が有効化され "child" 要件を満たす。
    var list = diag.List.init(allocator);
    defer list.deinit();
    var verified = try npkg_verify.verify(allocator, archive, .{}, &list);
    defer verified.deinit();

    // default を無効化すれば要件を満たせず不適合。
    var failing = diag.List.init(allocator);
    defer failing.deinit();
    try testing.expectError(error.InvalidPackage, npkg_verify.verify(allocator, archive, .{
        .default_features = false,
    }, &failing));
    try testing.expect(failing.find(diag.E015_NATIVE_FOR_INCOMPATIBLE_TARGET) != null);
}

test "npkg build は include 対象外の symlink を無視する" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try temporary.dir.createDirPath(io, "pkg/docs");
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/nako.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\include = ["src/**"]
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/index.nako3"
        \\
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/src/index.nako3", .data = "" });
    // include に合致しない docs/latest は symlink。収録対象の判定を先に
    // 行うため「通常ファイルでない」診断にならず build が成功する。
    temporary.dir.symLink(io, "../src/index.nako3", "pkg/docs/latest", .{}) catch |err| switch (err) {
        // Windows等でlink作成権限がない環境では検証を省略する。
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = try npkg_build.build(allocator, io, root, &list, .{});
    defer built.deinit();
    try testing.expectEqual(@as(usize, 1), built.files.len);
    try testing.expectEqualStrings("src/index.nako3", built.files[0].path);
}

test "npkg build は記号を含む literal directory を include で収録する" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try temporary.dir.createDirPath(io, "pkg/assets[old]");
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/nako.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\include = ["src/**", "assets[old]"]
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/index.nako3"
        \\
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/src/index.nako3", .data = "" });
    // `[`/`{` は glob 構文ではなく literal のため、`assets[old]` は
    // directory 接頭辞として配下を収録する。
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/assets[old]/icon.png", .data = "x" });
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = try npkg_build.build(allocator, io, root, &list, .{});
    defer built.deinit();
    try testing.expectEqual(@as(usize, 2), built.files.len);
    try testing.expectEqualStrings("assets[old]/icon.png", built.files[0].path);
    try testing.expectEqualStrings("src/index.nako3", built.files[1].path);
}

test "npkg verify は未定義の要求 feature を拒否する" {
    const allocator = testing.allocator;
    const archive = try minimalArchive(allocator);
    defer allocator.free(archive);

    var list = diag.List.init(allocator);
    defer list.deinit();
    try testing.expectError(error.InvalidPackage, npkg_verify.verify(allocator, archive, .{
        .features = &.{"typoed-name"},
    }, &list));
    try testing.expect(list.find(diag.E028_UNKNOWN_FEATURE) != null);
}

test "npkg build は payload に無い path 依存を拒否する" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/nako.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\local = { path = "vendor/local" }
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/index.nako3"
        \\
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/src/index.nako3", .data = "" });
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    // vendor/local が payload に無い宣言は拒否される。
    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = npkg_build.build(allocator, io, root, &list, .{}) catch |err| {
        try testing.expectEqual(error.InvalidPackage, err);
        try testing.expect(list.find(diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY) != null);
        return;
    };
    defer built.deinit();
    return error.TestUnexpectedResult;
}

test "npkg build は payload 内の path 依存を受理する" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try temporary.dir.createDirPath(io, "pkg/vendor/local");
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/nako.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\local = { path = "vendor/local" }
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/index.nako3"
        \\
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/src/index.nako3", .data = "" });
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/vendor/local/nako.toml",
        .data =
        \\[package]
        \\name = "local"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        ,
    });
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = try npkg_build.build(allocator, io, root, &list, .{});
    defer built.deinit();
    try testing.expectEqual(@as(usize, 3), built.files.len);
}

test "npkg build は profile 付き依存を拒否する" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/nako.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[profiles.linux]
        \\os = "linux"
        \\cpu = "x86_64"
        \\abi = "gnu"
        \\
        \\[dependencies.pkg]
        \\dep = { version = "^1.0", profile = "linux" }
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/index.nako3"
        \\
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/src/index.nako3", .data = "" });
    const root = try tmpRoot(&temporary, allocator);
    defer allocator.free(root);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = npkg_build.build(allocator, io, root, &list, .{}) catch |err| {
        try testing.expectEqual(error.InvalidPackage, err);
        try testing.expect(list.find(diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY) != null);
        return;
    };
    defer built.deinit();
    return error.TestUnexpectedResult;
}
