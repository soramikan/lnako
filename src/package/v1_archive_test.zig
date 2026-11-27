//! v1 `.npkg` の pack/verify 単体テスト。適合性フィクスチャ Z-01・Z-05・
//! Z-06・Z-09〜Z-16 と、全 kind の生成・再現性・制御ファイルの交叉検査を
//! 扱う。

const std = @import("std");
const testing = std.testing;
const toml = @import("toml.zig");
const types = @import("v1_types.zig");
const zip = @import("v1_zip.zig");
const meta = @import("v1_metadata.zig");
const mfiles = @import("v1_metadata_files.zig");
const archive = @import("v1_archive.zig");

const Allocator = std.mem.Allocator;

const z0_metadata =
    \\schema_version = 1
    \\
    \\[package]
    \\id = "@example/demo"
    \\version = "1.0.0"
    \\license = "MIT"
    \\capabilities = ["pure-nako"]
    \\
    \\[artifact]
    \\kind = "universal"
    \\runtimes = ["lnako", "cnako", "wnako"]
    \\
    \\[exports]
    \\"." = { entry = "src/main.nako3", binding = "scoped" }
    \\
;

const z0_commands =
    \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[],"constants":[]}}}
;

const z0_payload = "# fixture\n";

/// 旧来の 16 MiB 固有上限を超えても、ZIP の既定上限内なら正当な
/// COMMANDS.json として受理されることを確かめるためのサイズ。
const commands_probe_bytes: usize = 16 * 1024 * 1024 + 1;

/// 末尾の合法な JSON 空白で `commands_probe_bytes` まで埋めた COMMANDS.json。
fn paddedCommands(allocator: Allocator, source: []const u8) ![]u8 {
    const padded = try allocator.alloc(u8, commands_probe_bytes);
    @memset(padded, ' ');
    @memcpy(padded[0..source.len], source);
    return padded;
}

const Extra = struct {
    path: []const u8,
    data: []const u8,
    listed: bool = true,
};

fn parseDocument(allocator: Allocator, source: []const u8) !toml.Document {
    const parsed = try toml.parse(allocator, source);
    return switch (parsed) {
        .ok => |document| document,
        .err => error.InvalidManifest,
    };
}

/// メタデータ・commands・payload・追加ファイルから、FILES.json を含む
/// 正規形 ZIP を組み立てる。`listed = false` の追加ファイルは索引に載せない
/// （Z-06 の入力）。
fn buildFixture(
    allocator: Allocator,
    metadata_text: []const u8,
    commands_text: []const u8,
    payload: []const u8,
    extras: []const Extra,
) ![]u8 {
    var entries: std.ArrayList(zip.SourceEntry) = .empty;
    defer entries.deinit(allocator);
    var file_entries: std.ArrayList(mfiles.Entry) = .empty;
    defer file_entries.deinit(allocator);

    try entries.append(allocator, .{ .path = "src/main.nako3", .data = payload });
    try file_entries.append(allocator, mfiles.entryFor("src/main.nako3", payload));
    try entries.append(allocator, .{ .path = archive.metadata_path, .data = metadata_text });
    try file_entries.append(allocator, mfiles.entryFor(archive.metadata_path, metadata_text));
    try entries.append(allocator, .{ .path = archive.commands_path, .data = commands_text });
    try file_entries.append(allocator, mfiles.entryFor(archive.commands_path, commands_text));
    for (extras) |extra| {
        try entries.append(allocator, .{ .path = extra.path, .data = extra.data });
        if (extra.listed) try file_entries.append(allocator, mfiles.entryFor(extra.path, extra.data));
    }
    const files_bytes = try mfiles.emit(allocator, file_entries.items);
    defer allocator.free(files_bytes);
    try entries.append(allocator, .{ .path = archive.files_path, .data = files_bytes });
    return zip.build(allocator, entries.items, .{});
}

fn writeProjectFile(tmp: *std.testing.TmpDir, path: []const u8, data: []const u8) !void {
    const io = testing.io;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        try tmp.dir.createDirPath(io, path[0..slash]);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = data });
}

/// テスト用 symlink を作る。Windows 等で link 作成権限がない環境では、
/// 既存の ZIP テストと同じく検証自体を省略する。
fn createTestSymlink(
    directory: std.Io.Dir,
    io: std.Io,
    target: []const u8,
    link_path: []const u8,
    is_directory: bool,
) !void {
    directory.symLink(io, target, link_path, .{ .is_directory = is_directory }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };
}

const ProjectFile = struct {
    path: []const u8,
    data: []const u8,
};

const Project = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    document: toml.Document,

    fn init(allocator: Allocator, manifest: []const u8, files: []const ProjectFile) !Project {
        var project = Project{
            .tmp = testing.tmpDir(.{}),
            .root = undefined,
            .document = undefined,
        };
        errdefer project.tmp.cleanup();
        try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "nako.toml", .data = manifest });
        for (files) |file| try writeProjectFile(&project.tmp, file.path, file.data);
        project.root = try project.tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
        project.document = try parseDocument(allocator, manifest);
        return project;
    }

    fn deinit(self: *Project, allocator: Allocator) void {
        self.document.deinit();
        allocator.free(self.root);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

const file_main =
    \\●(Aを)取得とは
    \\  Aで戻る
    \\ここまで
    \\定数 公開タイムアウト{公開}=5
    \\
;
const file_dsl =
    \\●(Aを)公開取得とは
    \\  Aで戻る
    \\ここまで
    \\
;

test "Z-01 正規形ZIPと三つの制御ファイルを受理し検証済みデータを公開する" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, z0_metadata, z0_commands, z0_payload, &.{});
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();

    try testing.expectEqualStrings("@example/demo", verified.packageId());
    try testing.expectEqualStrings("1.0.0", verified.packageVersion());
    try testing.expectEqual(types.Kind.universal, verified.artifactKind());
    try testing.expectEqual(@as(usize, 3), verified.runtimes().len);
    try testing.expectEqualStrings(z0_payload, try verified.selectedEntry("."));
    try testing.expectEqual(@as(usize, 3), verified.fileEntries().len);

    // P04 が参照する所有型。
    const package_table = verified.metadata.root.get("package").?.kind.table;
    try testing.expectEqualStrings("@example/demo", package_table.get("id").?.kind.string);
    const exports_object = verified.commands.value.object.get("exports").?.object;
    try testing.expect(exports_object.get(".") != null);
    const global_names = try verified.globalCommandNames(allocator);
    defer allocator.free(global_names);
    try testing.expectEqual(@as(usize, 0), global_names.len);
    try testing.expectEqualStrings("MIT", verified.packageLicense());
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn findCentral(bytes: []const u8, name: []const u8) ?usize {
    const eocd = bytes.len - 22;
    const count = readU16(bytes, eocd + 10);
    var offset: usize = readU32(bytes, eocd + 16);
    for (0..count) |_| {
        if (readU32(bytes, offset) != 0x02014b50) return null;
        const name_len = readU16(bytes, offset + 28);
        const extra_len = readU16(bytes, offset + 30);
        const comment_len = readU16(bytes, offset + 32);
        if (std.mem.eql(u8, bytes[offset + 46 .. offset + 46 + name_len], name)) return offset;
        offset += 46 + name_len + extra_len + comment_len;
    }
    return null;
}

test "Z-05 実バイト列のSHA-256が索引と不一致なら拒否する" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, z0_metadata, z0_commands, z0_payload, &.{});
    defer allocator.free(bytes);
    const payload_offset = std.mem.indexOf(u8, bytes, z0_payload) orelse return error.TestUnexpectedResult;
    @memcpy(bytes[payload_offset .. payload_offset + z0_payload.len], "# fixturf\n");
    // ZIP 自体は壊さず、索引だけが元の内容を指す状態にする。
    const crc = std.hash.Crc32.hash("# fixturf\n");
    const central = findCentral(bytes, "src/main.nako3") orelse return error.TestUnexpectedResult;
    const local: usize = readU32(bytes, central + 42);
    writeU32(bytes, central + 16, crc);
    writeU32(bytes, local + 14, crc);
    try testing.expectError(error.HashMismatch, archive.verify(allocator, bytes));
}

test "Z-06 索引にない通常ファイルを拒否する" {
    const allocator = testing.allocator;
    const extras = [_]Extra{.{ .path = "extra.txt", .data = "x", .listed = false }};
    const bytes = try buildFixture(allocator, z0_metadata, z0_commands, z0_payload, &extras);
    defer allocator.free(bytes);
    try testing.expectError(error.FileIndexMismatch, archive.verify(allocator, bytes));
}

test "Z-09 METADATA と COMMANDS のキー集合不一致を拒否する" {
    const allocator = testing.allocator;
    const commands =
        \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[],"constants":[]},"./client":{"binding":"scoped","commands":[],"constants":[]}}}
    ;
    const bytes = try buildFixture(allocator, z0_metadata, commands, z0_payload, &.{});
    defer allocator.free(bytes);
    try testing.expectError(error.ExportMismatch, archive.verify(allocator, bytes));
}

test "Z-10 global binding がないのに exports_global_commands が真なら拒否する" {
    const allocator = testing.allocator;
    const commands =
        \\{"schema_version":1,"exports_global_commands":true,"exports":{".":{"binding":"scoped","commands":[],"constants":[]}}}
    ;
    const bytes = try buildFixture(allocator, z0_metadata, commands, z0_payload, &.{});
    defer allocator.free(bytes);
    try testing.expectError(error.GlobalCommandsMismatch, archive.verify(allocator, bytes));
}

test "Z-13 LicenseRef の本文が欠落または空なら拒否する" {
    const allocator = testing.allocator;
    const metadata =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "LicenseRef-Demo"
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "scoped" }
        \\
    ;
    const missing = try buildFixture(allocator, metadata, z0_commands, z0_payload, &.{});
    defer allocator.free(missing);
    try testing.expectError(error.MissingLicenseText, archive.verify(allocator, missing));

    const empty_extras = [_]Extra{.{
        .path = "LICENSES/LicenseRef-Demo.txt",
        .data = " \n",
    }};
    const empty = try buildFixture(allocator, metadata, z0_commands, z0_payload, &empty_extras);
    defer allocator.free(empty);
    try testing.expectError(error.MissingLicenseText, archive.verify(allocator, empty));

    const text_extras = [_]Extra{.{
        .path = "LICENSES/LicenseRef-Demo.txt",
        .data = "Demo license text\n",
    }};
    const present = try buildFixture(allocator, metadata, z0_commands, z0_payload, &text_extras);
    defer allocator.free(present);
    var verified = try archive.verify(allocator, present);
    defer verified.deinit();
    try testing.expectEqualStrings("LicenseRef-Demo", verified.packageLicense());
}

test "Z-14 native-source は artifact.native.abi_version を必須とする" {
    const allocator = testing.allocator;
    const missing_native =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[artifact]
        \\kind = "native-source"
        \\runtimes = ["lnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "scoped" }
        \\
    ;
    const rejected = try buildFixture(allocator, missing_native, z0_commands, z0_payload, &.{});
    defer allocator.free(rejected);
    try testing.expectError(error.MissingField, archive.verify(allocator, rejected));

    const with_native =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[artifact]
        \\kind = "native-source"
        \\runtimes = ["lnako"]
        \\[artifact.native]
        \\abi_version = 1
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "scoped" }
        \\
    ;
    const accepted = try buildFixture(allocator, with_native, z0_commands, z0_payload, &.{});
    defer allocator.free(accepted);
    var verified = try archive.verify(allocator, accepted);
    defer verified.deinit();
    try testing.expectEqual(types.Kind.@"native-source", verified.artifactKind());
    try testing.expectEqual(@as(?u32, 1), verified.native().?.abi_version);
}

test "Z-15 共通 exports にない artifact.entries を拒否する" {
    const allocator = testing.allocator;
    const metadata =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[artifact]
        \\kind = "esm"
        \\runtimes = ["cnako"]
        \\[artifact.entries]
        \\"./undeclared" = "src/main.nako3"
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "scoped" }
        \\
    ;
    const bytes = try buildFixture(allocator, metadata, z0_commands, z0_payload, &.{});
    defer allocator.free(bytes);
    try testing.expectError(error.UndefinedExportEntry, archive.verify(allocator, bytes));
}

test "Z-16 旧制御ファイル名を error.LegacyArchive として拒否する" {
    const allocator = testing.allocator;
    const entries = [_]zip.SourceEntry{
        .{ .path = "src/main.nako3", .data = z0_payload },
        .{ .path = archive.metadata_path, .data = z0_metadata },
        .{ .path = "NAKO-PKG/FILES.toml", .data = "schemaVersion = 1\n" },
        .{ .path = "NAKO-PKG/commands.json", .data = z0_commands },
    };
    const bytes = try zip.build(allocator, &entries, .{});
    defer allocator.free(bytes);
    try testing.expectError(error.LegacyArchive, archive.verify(allocator, bytes));

    const old_metadata =
        \\schemaVersion = 1
        \\[package]
        \\name = "demo"
        \\
    ;
    const old_entries = [_]zip.SourceEntry{
        .{ .path = "src/main.nako3", .data = z0_payload },
        .{ .path = archive.metadata_path, .data = old_metadata },
        .{ .path = archive.files_path, .data = "{\"schema_version\":1,\"files\":[]}" },
        .{ .path = archive.commands_path, .data = z0_commands },
    };
    const old_bytes = try zip.build(allocator, &old_entries, .{});
    defer allocator.free(old_bytes);
    try testing.expectError(error.LegacyArchive, archive.verify(allocator, old_bytes));
}

test "Z-16 説明文・コメント中のschemaVersionは正当なv1を拒否しない" {
    const allocator = testing.allocator;
    const metadata =
        \\# schemaVersion / schema-version は旧形式の語だがコメントでありキーではない
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\description = "schemaVersion と schema-version を説明文に含む正当な v1"
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "scoped" }
        \\
    ;
    const bytes = try buildFixture(allocator, metadata, z0_commands, z0_payload, &.{});
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqualStrings("@example/demo", verified.packageId());
}

test "verify はZIP実バイト長にも圧縮後上限を適用する" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, z0_metadata, z0_commands, z0_payload, &.{});
    defer allocator.free(bytes);
    try testing.expectError(error.CompressedSizeExceeded, archive.verifyWithLimits(
        allocator,
        bytes,
        .{ .max_compressed_bytes = bytes.len - 1 },
    ));
}

test "Verified は入力ZIPバイト列の寿命に依存しない" {
    const allocator = testing.allocator;
    var bytes = try buildFixture(allocator, z0_metadata, z0_commands, z0_payload, &.{});
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    allocator.free(bytes);
    bytes = &.{};
    try testing.expectEqualStrings("@example/demo", verified.packageId());
    try testing.expectEqualStrings(z0_payload, try verified.selectedEntry("."));
    try testing.expectEqualStrings(z0_payload, verified.entryBytes("src/main.nako3").?);
    try testing.expect(std.mem.startsWith(u8, verified.entryPath(0), "NAKO-PKG/"));
    const listed = verified.fileEntries();
    try testing.expectEqualStrings("src/main.nako3", listed[listed.len - 1].path);
    const names = try verified.globalCommandNames(allocator);
    defer allocator.free(names);
    try testing.expectEqual(@as(usize, 0), names.len);
}

const universal_manifest =
    \\schema_version = 1
    \\
    \\[package]
    \\id = "@example/demo"
    \\version = "1.0.0"
    \\description = "サンプル"
    \\license = "MIT"
    \\capabilities = ["pure-nako"]
    \\
    \\[package.engines]
    \\lnako = ">=0.3.0 <1.0.0"
    \\cnako = ">=3.6.0"
    \\
    \\[exports]
    \\"." = { entry = "src/main.nako3" }
    \\"./dsl" = { entry = "src/dsl.nako3", binding = "global" }
    \\
    \\[features]
    \\default = ["tls"]
    \\tls = []
    \\
    \\[artifacts.universal]
    \\include = ["src/**/*.nako3"]
    \\
    \\[dependencies]
    \\"@std/json" = "^1.0.0"
    \\"@other/json" = { version = "^2.1.0", alias = "fast_json", features = ["simd"] }
    \\
    \\[runtime-dependencies.lnako]
    \\"@std/tls" = "^1.0.0"
    \\
    \\[dev-dependencies]
    \\"@std/test" = "^1.0.0"
    \\
;

test "全kind: universal を生成し commands・constants・依存・再現性を検証する" {
    const allocator = testing.allocator;
    var project = try Project.init(allocator, universal_manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "src/dsl.nako3", .data = file_dsl },
    });
    defer project.deinit(allocator);

    const first = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .universal,
    });
    defer allocator.free(first);
    const Holder = struct { doc: toml.Document };
    var holder = Holder{ .doc = project.document };
    const second = try archive.packManifest(allocator, testing.io, project.root, &holder, .{
        .kind = .universal,
    });
    defer allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);

    var verified = try archive.verify(allocator, first);
    defer verified.deinit();
    try testing.expectEqual(types.Kind.universal, verified.artifactKind());
    try testing.expectEqual(@as(usize, 2), verified.exports().len);
    try testing.expectEqualStrings(file_main, try verified.selectedEntry("."));
    try testing.expectEqualStrings(file_dsl, try verified.selectedEntry("./dsl"));

    const global_names = try verified.globalCommandNames(allocator);
    defer allocator.free(global_names);
    try testing.expectEqual(@as(usize, 1), global_names.len);
    try testing.expectEqualStrings("公開取得", global_names[0]);

    const exports_value = verified.commands.value.object.get("exports").?.object;
    const main_export = exports_value.get(".").?.object;
    try testing.expectEqual(@as(usize, 1), main_export.get("commands").?.array.items.len);
    try testing.expectEqualStrings("取得", main_export.get("commands").?.array.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("公開タイムアウト", main_export.get("constants").?.array.items[0].string);
    try testing.expect(verified.commands.value.object.get("exports_global_commands").?.bool);

    const dependencies = verified.dependencies();
    try testing.expectEqual(@as(usize, 3), dependencies.len);
    var saw_alias = false;
    var saw_runtime = false;
    for (dependencies) |dependency| {
        if (std.mem.eql(u8, dependency.id, "@other/json")) {
            try testing.expectEqualStrings("fast_json", dependency.alias.?);
            saw_alias = true;
        }
        if (std.mem.eql(u8, dependency.id, "@std/tls")) {
            try testing.expectEqual(@as(usize, 1), dependency.runtimes.len);
            try testing.expectEqual(types.Runtime.lnako, dependency.runtimes[0]);
            saw_runtime = true;
        }
        try testing.expect(!std.mem.eql(u8, dependency.id, "@std/test"));
    }
    try testing.expect(saw_alias and saw_runtime);
    try testing.expectEqual(@as(usize, 2), verified.metadata_model.features.len);
    try testing.expectEqual(@as(usize, 2), verified.metadata_model.engines.len);
}

test "全kind: esm は artifact.entries で共通入口を差し替える" {
    const allocator = testing.allocator;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.esm]
        \\runtimes = ["cnako", "wnako"]
        \\entry = "dist/esm/index.js"
        \\include = ["dist/esm/**"]
        \\
    ;
    var project = try Project.init(allocator, manifest, &.{
        .{ .path = "dist/esm/index.js", .data = "export const demo = 1;\n" },
    });
    defer project.deinit(allocator);
    const bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .esm,
    });
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqual(types.Kind.esm, verified.artifactKind());
    try testing.expectEqual(@as(usize, 2), verified.runtimes().len);
    try testing.expectEqualStrings("export const demo = 1;\n", try verified.selectedEntry("."));
    try testing.expectEqualStrings("dist/esm/index.js", verified.metadata_model.artifactEntry(".").?);
    const main_export = verified.commands.value.object.get("exports").?.object.get(".").?.object;
    try testing.expectEqual(@as(usize, 0), main_export.get("commands").?.array.items.len);
}

test "全kind: esm の命令一覧はアーティファクト固有の実体から生成する" {
    const allocator = testing.allocator;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/common.nako3" }
        \\[artifacts.esm]
        \\runtimes = ["cnako"]
        \\entry = "src/artifact.nako3"
        \\include = ["src/common.nako3", "src/artifact.nako3"]
        \\
    ;
    const common_source =
        \\●(Aを)共通取得とは
        \\  Aで戻る
        \\ここまで
        \\
    ;
    const artifact_source =
        \\●(Aを)実体取得とは
        \\  Aで戻る
        \\ここまで
        \\
    ;
    var project = try Project.init(allocator, manifest, &.{
        .{ .path = "src/common.nako3", .data = common_source },
        .{ .path = "src/artifact.nako3", .data = artifact_source },
    });
    defer project.deinit(allocator);
    const bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .esm,
    });
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    const main_export = verified.commands.value.object.get("exports").?.object.get(".").?.object;
    const commands = main_export.get("commands").?.array.items;
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqualStrings("実体取得", commands[0].object.get("name").?.string);
    try testing.expectEqualStrings("A", commands[0].object.get("args").?.array.items[0].object.get("name").?.string);
}

test "全kind: native-source は abi_version とビルド入力を収録する" {
    const allocator = testing.allocator;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\[artifacts.native]
        \\abi_version = 1
        \\source_include = ["native/**"]
        \\
    ;
    var project = try Project.init(allocator, manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "native/build.zig", .data = "// build\n" },
    });
    defer project.deinit(allocator);
    const bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .@"native-source",
    });
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqual(types.Kind.@"native-source", verified.artifactKind());
    try testing.expectEqual(@as(?u32, 1), verified.native().?.abi_version);
    try testing.expect(verified.entryBytes("native/build.zig") != null);
    // 共通 exports は変えず、種別固有入口だけを build.zig へ結ぶ。
    try testing.expectEqualStrings("src/main.nako3", verified.exports()[0].entry);
    try testing.expectEqualStrings("native/build.zig", verified.metadata_model.selectedEntry(".").?);
    try testing.expectEqualStrings("// build\n", try verified.selectedEntry("."));
}

test "native-source は source_include 内の複数 build.zig を推測せず拒否する" {
    const allocator = testing.allocator;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\[artifacts.native]
        \\abi_version = 1
        \\source_include = ["native/**"]
        \\
    ;
    var project = try Project.init(allocator, manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "native/build.zig", .data = "// build\n" },
        .{ .path = "native/other/build.zig", .data = "// another build\n" },
    });
    defer project.deinit(allocator);
    try testing.expectError(error.AmbiguousBuildInput, archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        .{ .kind = .@"native-source" },
    ));
}

test "native-source の明示 build.zig と C 入力をそのまま収録する" {
    const allocator = testing.allocator;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "native/build.zig" }
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\[artifacts.native]
        \\abi_version = 1
        \\source_include = ["native/**"]
        \\
    ;
    var project = try Project.init(allocator, manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "native/build.zig", .data = "// build\n" },
        .{ .path = "native/helper.c", .data = "int helper(void) { return 0; }\n" },
    });
    defer project.deinit(allocator);
    const bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .@"native-source",
    });
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqualStrings("native/build.zig", verified.metadata_model.selectedEntry(".").?);
    try testing.expectEqualStrings("native/build.zig", verified.exports()[0].entry);
    try testing.expect(verified.entryBytes("native/helper.c") != null);
}

test "全kind: native-prebuilt はライブラリと glibc を検証する" {
    const allocator = testing.allocator;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\[artifacts.native]
        \\abi_version = 1
        \\
    ;
    var project = try Project.init(allocator, manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "native/libdemo.so", .data = "DUMMY-ELF" },
    });
    defer project.deinit(allocator);
    const bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .@"native-prebuilt",
        .native = .{
            .target_triple = "x86_64-linux-gnu",
            .abi_version = 1,
            .glibc_min = "2.31",
            .library_path = "native/libdemo.so",
        },
    });
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqual(types.Kind.@"native-prebuilt", verified.artifactKind());
    const native = verified.native().?;
    try testing.expectEqualStrings("x86_64-linux-gnu", native.target_triple.?);
    try testing.expectEqualStrings("2.31", native.glibc_min.?);
    try testing.expectEqualStrings("DUMMY-ELF", verified.entryBytes("native/libdemo.so").?);
    try testing.expectEqualStrings("DUMMY-ELF", try verified.selectedEntry("."));
    try testing.expectEqual(@as(usize, 1), verified.metadata_model.artifact.entries.len);
    try testing.expectEqualStrings(".", verified.metadata_model.artifact.entries[0].subpath);
    try testing.expectEqualStrings("native/libdemo.so", verified.metadata_model.artifact.entries[0].path);

    const no_glibc = archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .@"native-prebuilt",
        .native = .{
            .target_triple = "x86_64-linux-gnu",
            .abi_version = 1,
            .library_path = "native/libdemo.so",
        },
    });
    try testing.expectError(error.MissingField, no_glibc);

    const musl_with_glibc = archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .@"native-prebuilt",
        .native = .{
            .target_triple = "x86_64-linux-musl",
            .abi_version = 1,
            .glibc_min = "2.31",
            .library_path = "native/libdemo.so",
        },
    });
    try testing.expectError(error.InvalidGlibcVersion, musl_with_glibc);
}

test "全kind: native-prebuilt は prebuilt_lib_name から収録パスを導出する" {
    const allocator = testing.allocator;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/prebuilt"
        \\version = "3.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "scoped" }
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\[artifacts.native]
        \\abi_version = 1
        \\prebuilt_lib_name = "demo"
        \\
    ;
    var project = try Project.init(allocator, manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "native/libdemo.so", .data = "LINUX-ELF" },
        .{ .path = "native/libdemo.dylib", .data = "MAC-DYLIB" },
        .{ .path = "native/demo.dll", .data = "WINDOWS-DLL" },
    });
    defer project.deinit(allocator);

    const linux_bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .@"native-prebuilt",
        .native = .{
            .target_triple = "x86_64-linux-gnu",
            .abi_version = 1,
            .glibc_min = "2.31",
        },
    });
    defer allocator.free(linux_bytes);
    var linux = try archive.verify(allocator, linux_bytes);
    defer linux.deinit();
    try testing.expectEqualStrings("native/libdemo.so", linux.native().?.library_path.?);
    try testing.expectEqualStrings("LINUX-ELF", try linux.selectedEntry("."));
    try testing.expectEqualStrings("src/main.nako3", linux.metadata_model.exports[0].entry);
    try testing.expectEqual(@as(usize, 1), linux.metadata_model.artifact.entries.len);
    try testing.expectEqualStrings(".", linux.metadata_model.artifact.entries[0].subpath);
    try testing.expectEqualStrings("native/libdemo.so", linux.metadata_model.artifact.entries[0].path);

    const mac_bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .@"native-prebuilt",
        .native = .{
            .target_triple = "aarch64-macos-macho",
            .abi_version = 1,
        },
    });
    defer allocator.free(mac_bytes);
    var mac = try archive.verify(allocator, mac_bytes);
    defer mac.deinit();
    try testing.expectEqualStrings("native/libdemo.dylib", mac.native().?.library_path.?);
    try testing.expectEqualStrings("MAC-DYLIB", try mac.selectedEntry("."));

    const windows_bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .@"native-prebuilt",
        .native = .{
            .target_triple = "x86_64-windows-msvc",
            .abi_version = 1,
        },
    });
    defer allocator.free(windows_bytes);
    var windows = try archive.verify(allocator, windows_bytes);
    defer windows.deinit();
    try testing.expectEqualStrings("native/demo.dll", windows.native().?.library_path.?);
    try testing.expectEqualStrings("WINDOWS-DLL", try windows.selectedEntry("."));
}

test "全kind: native-prebuilt は共通 .nako3 から命令を抽出し入口はライブラリへ向ける" {
    const allocator = testing.allocator;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/prebuilt-global"
        \\version = "3.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "global" }
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\[artifacts.native]
        \\abi_version = 1
        \\prebuilt_lib_name = "demo"
        \\
    ;
    var project = try Project.init(allocator, manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "native/libdemo.so", .data = "DUMMY-ELF" },
    });
    defer project.deinit(allocator);
    const bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .@"native-prebuilt",
        .native = .{
            .target_triple = "x86_64-linux-gnu",
            .abi_version = 1,
            .glibc_min = "2.31",
        },
    });
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqualStrings("DUMMY-ELF", try verified.selectedEntry("."));
    try testing.expect(verified.commands_model.exports_global_commands);
    const export_entry = verified.commands_model.findExport(".").?;
    try testing.expectEqual(@as(usize, 1), export_entry.commands.len);
    try testing.expectEqualStrings("取得", export_entry.commands[0].name);
}

test "全kind: native-prebuilt は曖昧な prebuilt_lib_name に明示パスを要求する" {
    const allocator = testing.allocator;
    const ambiguous_manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/prebuilt"
        \\version = "3.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\[artifacts.native]
        \\abi_version = 1
        \\prebuilt_lib_name = "native/demo"
        \\
    ;
    var project = try Project.init(allocator, ambiguous_manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "native/custom.so", .data = "CUSTOM-ELF" },
    });
    defer project.deinit(allocator);

    try testing.expectError(error.AmbiguousLibrary, archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        .{
            .kind = .@"native-prebuilt",
            .native = .{
                .target_triple = "x86_64-linux-gnu",
                .abi_version = 1,
                .glibc_min = "2.31",
            },
        },
    ));

    // 明示パスは prebuilt_lib_name の曖昧さより優先する。
    const bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .@"native-prebuilt",
        .native = .{
            .target_triple = "x86_64-linux-gnu",
            .abi_version = 1,
            .glibc_min = "2.31",
            .library_path = "native/custom.so",
        },
    });
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqualStrings("native/custom.so", verified.native().?.library_path.?);
    try testing.expectEqualStrings("CUSTOM-ELF", try verified.selectedEntry("."));
    try testing.expectEqualStrings("native/custom.so", verified.metadata_model.artifact.entries[0].path);

    const extension_manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/prebuilt"
        \\version = "3.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.native]
        \\abi_version = 1
        \\prebuilt_lib_name = "demo.dll"
        \\
    ;
    var extension_project = try Project.init(allocator, extension_manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
    });
    defer extension_project.deinit(allocator);
    try testing.expectError(error.AmbiguousLibrary, archive.pack(
        allocator,
        testing.io,
        extension_project.root,
        &extension_project.document,
        .{
            .kind = .@"native-prebuilt",
            .native = .{
                .target_triple = "x86_64-linux-gnu",
                .abi_version = 1,
                .glibc_min = "2.31",
            },
        },
    ));

    try testing.expectError(error.InvalidTargetTriple, archive.pack(
        allocator,
        testing.io,
        extension_project.root,
        &extension_project.document,
        .{
            .kind = .@"native-prebuilt",
            .native = .{
                .target_triple = "x86_64-unknown-foo",
                .abi_version = 1,
            },
        },
    ));

    const unnamed_manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/prebuilt"
        \\version = "3.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.native]
        \\abi_version = 1
        \\
    ;
    var unnamed_project = try Project.init(allocator, unnamed_manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
    });
    defer unnamed_project.deinit(allocator);
    try testing.expectError(error.MissingLibraryName, archive.pack(
        allocator,
        testing.io,
        unnamed_project.root,
        &unnamed_project.document,
        .{
            .kind = .@"native-prebuilt",
            .native = .{
                .target_triple = "x86_64-linux-gnu",
                .abi_version = 1,
                .glibc_min = "2.31",
            },
        },
    ));
}

test "Z-13 LicenseRef の本文を pack が全 kind で同梱する" {
    const allocator = testing.allocator;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "LicenseRef-Demo"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\
    ;
    var project = try Project.init(allocator, manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
    });
    defer project.deinit(allocator);
    try testing.expectError(error.MissingLicenseText, archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        .{ .kind = .universal },
    ));

    try writeProjectFile(&project.tmp, "LICENSES/LicenseRef-Demo.txt", "Demo license body\n");
    const bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .universal,
    });
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqualStrings("Demo license body\n", verified.entryBytes("LICENSES/LicenseRef-Demo.txt").?);
    try testing.expect(verified.fileEntries().len >= 4);
}

test "Z-14 pack は native-source の abi_version 欠落を拒否する" {
    const allocator = testing.allocator;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\[artifacts.native]
        \\source_include = ["native/**"]
        \\
    ;
    var project = try Project.init(allocator, manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "native/build.zig", .data = "// build\n" },
    });
    defer project.deinit(allocator);
    try testing.expectError(error.MissingField, archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        .{ .kind = .@"native-source" },
    ));
}

test "DEFLATE で pack したアーカイブを検証できる" {
    const allocator = testing.allocator;
    var project = try Project.init(allocator, universal_manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "src/dsl.nako3", .data = file_dsl },
    });
    defer project.deinit(allocator);
    const bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .universal,
        .compression = .deflate,
    });
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqualStrings(file_main, try verified.selectedEntry("."));
}

test "pack は収録対象外の symlink と予約領域を拒否する" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.universal]
        \\include = ["src/**"]
        \\
    ;
    var project = try Project.init(allocator, manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
    });
    defer project.deinit(allocator);
    try project.tmp.dir.symLink(testing.io, "main.nako3", "src/link.nako3", .{});
    try testing.expectError(error.SymlinkNotAllowed, archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        .{ .kind = .universal },
    ));
}

test "pack は walk 外の ESM 入口の symlink を親成分含め拒否する" {
    const allocator = testing.allocator;
    const io = testing.io;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "scoped" }
        \\[artifacts.esm]
        \\runtimes = ["cnako"]
        \\entry = "dist/esm/index.js"
        \\include = ["dist/payload/**"]
        \\
    ;
    {
        var project = try Project.init(allocator, manifest, &.{
            .{ .path = "dist/esm/real.js", .data = "export const demo = 1;\n" },
        });
        defer project.deinit(allocator);
        try createTestSymlink(project.tmp.dir, io, "real.js", "dist/esm/index.js", false);
        try testing.expectError(error.SymlinkNotAllowed, archive.pack(
            allocator,
            io,
            project.root,
            &project.document,
            .{ .kind = .esm },
        ));
    }
    {
        var project = try Project.init(allocator, manifest, &.{
            .{ .path = "real/index.js", .data = "export const demo = 1;\n" },
        });
        defer project.deinit(allocator);
        try project.tmp.dir.createDirPath(io, "dist");
        try createTestSymlink(project.tmp.dir, io, "../real", "dist/esm", true);
        try testing.expectError(error.SymlinkNotAllowed, archive.pack(
            allocator,
            io,
            project.root,
            &project.document,
            .{ .kind = .esm },
        ));
    }
}

test "pack は walk 外の native-prebuilt ライブラリの symlink を親成分含め拒否する" {
    const allocator = testing.allocator;
    const io = testing.io;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.universal]
        \\include = ["src/**"]
        \\[artifacts.native]
        \\abi_version = 1
        \\
    ;
    const options = archive.PackOptions{
        .kind = .@"native-prebuilt",
        .native = .{
            .target_triple = "x86_64-linux-gnu",
            .abi_version = 1,
            .glibc_min = "2.31",
            .library_path = "native/libdemo.so",
        },
    };
    {
        var project = try Project.init(allocator, manifest, &.{
            .{ .path = "src/main.nako3", .data = file_main },
            .{ .path = "real/libdemo.so", .data = "DUMMY-ELF" },
        });
        defer project.deinit(allocator);
        try project.tmp.dir.createDirPath(io, "native");
        try createTestSymlink(project.tmp.dir, io, "../real/libdemo.so", "native/libdemo.so", false);
        try testing.expectError(error.SymlinkNotAllowed, archive.pack(
            allocator,
            io,
            project.root,
            &project.document,
            options,
        ));
    }
    {
        var project = try Project.init(allocator, manifest, &.{
            .{ .path = "src/main.nako3", .data = file_main },
            .{ .path = "real/libdemo.so", .data = "DUMMY-ELF" },
        });
        defer project.deinit(allocator);
        try createTestSymlink(project.tmp.dir, io, "real", "native", true);
        try testing.expectError(error.SymlinkNotAllowed, archive.pack(
            allocator,
            io,
            project.root,
            &project.document,
            options,
        ));
    }
}

test "pack は walk 外の LicenseRef 本文の symlink を親成分含め拒否する" {
    const allocator = testing.allocator;
    const io = testing.io;
    const manifest =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "LicenseRef-Demo"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[artifacts.universal]
        \\include = ["src/**"]
        \\
    ;
    {
        var project = try Project.init(allocator, manifest, &.{
            .{ .path = "src/main.nako3", .data = file_main },
            .{ .path = "real/LicenseRef-Demo.txt", .data = "Demo license body\n" },
        });
        defer project.deinit(allocator);
        try project.tmp.dir.createDirPath(io, "LICENSES");
        try createTestSymlink(
            project.tmp.dir,
            io,
            "../real/LicenseRef-Demo.txt",
            "LICENSES/LicenseRef-Demo.txt",
            false,
        );
        try testing.expectError(error.SymlinkNotAllowed, archive.pack(
            allocator,
            io,
            project.root,
            &project.document,
            .{ .kind = .universal },
        ));
    }
    {
        var project = try Project.init(allocator, manifest, &.{
            .{ .path = "src/main.nako3", .data = file_main },
            .{ .path = "real/LicenseRef-Demo.txt", .data = "Demo license body\n" },
        });
        defer project.deinit(allocator);
        try createTestSymlink(project.tmp.dir, io, "real", "LICENSES", true);
        try testing.expectError(error.SymlinkNotAllowed, archive.pack(
            allocator,
            io,
            project.root,
            &project.document,
            .{ .kind = .universal },
        ));
    }
}

const js_esm_manifest =
    \\schema_version = 1
    \\[package]
    \\id = "@example/js"
    \\version = "1.0.0"
    \\license = "MIT"
    \\[exports]
    \\"." = { entry = "src/main.nako3", binding = "scoped" }
    \\[artifacts.esm]
    \\runtimes = ["cnako", "wnako"]
    \\entry = "dist/esm/index.js"
    \\include = ["dist/esm/**"]
    \\
;

const js_esm_entry = "export function greet(name) { return `hello ${name}`; }\n";

const js_commands_empty =
    \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[],"constants":[]}}}
;

const js_commands =
    \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[{"name":"JS挨拶","kind":"function","args":[{"name":"A","josi":["を"]}],"return_type":"string"}],"constants":["JS版"]}}}
;

test "全kind: ESM の実JS入口に明示 COMMANDS.json を入力できる" {
    const allocator = testing.allocator;
    var project = try Project.init(allocator, js_esm_manifest, &.{
        .{ .path = "dist/esm/index.js", .data = js_esm_entry },
    });
    defer project.deinit(allocator);

    // 命令が無い入口も合法。明示入力でも空の commands/constants を保持する。
    const empty = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .esm,
        .commands_json = js_commands_empty,
    });
    defer allocator.free(empty);
    var empty_verified = try archive.verify(allocator, empty);
    defer empty_verified.deinit();
    const empty_export = empty_verified.commands.value.object.get("exports").?.object.get(".").?.object;
    try testing.expectEqual(@as(usize, 0), empty_export.get("commands").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), empty_export.get("constants").?.array.items.len);

    const bytes = try archive.pack(allocator, testing.io, project.root, &project.document, .{
        .kind = .esm,
        .commands_json = js_commands,
    });
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqualStrings(js_esm_entry, try verified.selectedEntry("."));
    const export_object = verified.commands.value.object.get("exports").?.object.get(".").?.object;
    const commands = export_object.get("commands").?.array.items;
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqualStrings("JS挨拶", commands[0].object.get("name").?.string);
    try testing.expectEqualStrings("string", commands[0].object.get("return_type").?.string);
    try testing.expectEqualStrings("JS版", export_object.get("constants").?.array.items[0].string);
}

test "Z-09 ESM の明示 COMMANDS.json が METADATA と食い違えば拒否する" {
    const allocator = testing.allocator;
    var project = try Project.init(allocator, js_esm_manifest, &.{
        .{ .path = "dist/esm/index.js", .data = js_esm_entry },
    });
    defer project.deinit(allocator);

    const extra_export =
        \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[],"constants":[]},"./client":{"binding":"scoped","commands":[],"constants":[]}}}
    ;
    try testing.expectError(error.ExportMismatch, archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        .{ .kind = .esm, .commands_json = extra_export },
    ));

    const missing_export =
        \\{"schema_version":1,"exports_global_commands":false,"exports":{}}
    ;
    try testing.expectError(error.ExportMismatch, archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        .{ .kind = .esm, .commands_json = missing_export },
    ));

    const global_binding =
        \\{"schema_version":1,"exports_global_commands":true,"exports":{".":{"binding":"global","commands":[],"constants":[]}}}
    ;
    try testing.expectError(error.BindingMismatch, archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        .{ .kind = .esm, .commands_json = global_binding },
    ));

    try testing.expectError(error.InvalidCommands, archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        .{ .kind = .esm, .commands_json = "{\"schema_version\":1" },
    ));
}

const native_manifest =
    \\schema_version = 1
    \\[package]
    \\id = "@example/native"
    \\version = "2.0.0"
    \\license = "MIT"
    \\[exports]
    \\"." = { entry = "src/main.nako3", binding = "scoped" }
    \\[artifacts.universal]
    \\include = ["src/**/*.nako3"]
    \\[artifacts.native]
    \\abi_version = 1
    \\
;

const native_commands =
    \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[{"name":"ネイティブ取得","kind":"function","args":[{"name":"A","josi":["を"]}]}],"constants":[]}}}
;

const native_pack_options = archive.PackOptions{
    .kind = .@"native-prebuilt",
    .native = .{
        .target_triple = "x86_64-linux-gnu",
        .abi_version = 1,
        .glibc_min = "2.31",
        .library_path = "native/libdemo.so",
    },
};

test "全kind: native-prebuilt のライブラリに明示 COMMANDS.json を入力できる" {
    const allocator = testing.allocator;
    var project = try Project.init(allocator, native_manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "native/libdemo.so", .data = "DUMMY-ELF" },
    });
    defer project.deinit(allocator);

    var options = native_pack_options;
    options.commands_json = native_commands;
    const bytes = try archive.pack(allocator, testing.io, project.root, &project.document, options);
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqualStrings("DUMMY-ELF", verified.entryBytes("native/libdemo.so").?);
    const export_object = verified.commands.value.object.get("exports").?.object.get(".").?.object;
    const commands = export_object.get("commands").?.array.items;
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqualStrings("ネイティブ取得", commands[0].object.get("name").?.string);
    try testing.expectEqual(@as(usize, 0), export_object.get("constants").?.array.items.len);
}

test "Z-09 native-prebuilt の明示 COMMANDS.json が METADATA と食い違えば拒否する" {
    const allocator = testing.allocator;
    var project = try Project.init(allocator, native_manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "native/libdemo.so", .data = "DUMMY-ELF" },
    });
    defer project.deinit(allocator);

    var extra_key_options = native_pack_options;
    extra_key_options.commands_json =
        \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[],"constants":[]},"./extra":{"binding":"scoped","commands":[],"constants":[]}}}
    ;
    try testing.expectError(error.ExportMismatch, archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        extra_key_options,
    ));

    var global_options = native_pack_options;
    global_options.commands_json =
        \\{"schema_version":1,"exports_global_commands":true,"exports":{".":{"binding":"global","commands":[],"constants":[]}}}
    ;
    try testing.expectError(error.BindingMismatch, archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        global_options,
    ));
}

test "COMMANDS.json は 16MiB 超でも ZIP の既定上限内なら verify が受理する" {
    const allocator = testing.allocator;
    const commands_text = try paddedCommands(allocator, z0_commands);
    defer allocator.free(commands_text);
    const bytes = try buildFixture(allocator, z0_metadata, commands_text, z0_payload, &.{});
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    const stored = verified.entryBytes(archive.commands_path) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(commands_probe_bytes, stored.len);
}

test "COMMANDS.json は 16MiB 超でも ZIP の既定上限内なら pack が明示入力を受理する" {
    const allocator = testing.allocator;
    var project = try Project.init(allocator, universal_manifest, &.{
        .{ .path = "src/main.nako3", .data = file_main },
        .{ .path = "src/dsl.nako3", .data = file_dsl },
    });
    defer project.deinit(allocator);
    // universal_manifest の export 集合（"." scoped・"./dsl" global）に合わせる。
    const pack_commands =
        \\{"schema_version":1,"exports_global_commands":true,"exports":{".":{"binding":"scoped","commands":[],"constants":[]},"./dsl":{"binding":"global","commands":[],"constants":[]}}}
    ;
    const commands_text = try paddedCommands(allocator, pack_commands);
    defer allocator.free(commands_text);
    const bytes = try archive.pack(
        allocator,
        testing.io,
        project.root,
        &project.document,
        .{ .kind = .universal, .commands_json = commands_text },
    );
    defer allocator.free(bytes);
    var verified = try archive.verify(allocator, bytes);
    defer verified.deinit();
    try testing.expectEqual(@as(usize, 2), verified.commands_model.exports.len);
}
