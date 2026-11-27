//! v1 制御ファイルのモデル・検証・シリアライズの単体テスト。Canonical ZIP の
//! フィクスチャを補い、TOML/JSON の型境界、feature 循環、LicenseRef、GLIBC、
//! 命令・定数の導出を確認する。

const std = @import("std");
const testing = std.testing;
const meta = @import("v1_metadata.zig");
const mfiles = @import("v1_metadata_files.zig");
const mcommands = @import("v1_metadata_commands.zig");
const types = @import("v1_types.zig");

const Allocator = std.mem.Allocator;

fn parseMetadata(allocator: Allocator, source: []const u8, arena: Allocator) !meta.Parsed {
    return meta.parse(allocator, source, arena);
}

test "METADATA の schema_version は TOML 整数 1 を要求する" {
    const allocator = testing.allocator;
    const float_version =
        \\schema_version = 1.0
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\
    ;
    var arena_a = std.heap.ArenaAllocator.init(allocator);
    defer arena_a.deinit();
    try testing.expectError(error.InvalidFieldType, parseMetadata(allocator, float_version, arena_a.allocator()));

    const wrong_version =
        \\schema_version = 2
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\
    ;
    var arena_b = std.heap.ArenaAllocator.init(allocator);
    defer arena_b.deinit();
    try testing.expectError(error.InvalidSchemaVersion, parseMetadata(allocator, wrong_version, arena_b.allocator()));
}

test "公開バージョンは数値幅非依存でMETADATAに受理される" {
    const allocator = testing.allocator;
    const source =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "9007199254740992.0.0-rc.1"
        \\license = "MIT"
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parsed = try parseMetadata(allocator, source, arena.allocator());
    defer parsed.document.deinit();
    try testing.expectEqualStrings("9007199254740992.0.0-rc.1", parsed.model.package.version);
}

test "features の循環参照を拒否する" {
    const allocator = testing.allocator;
    const source =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[features]
        \\default = ["tls"]
        \\tls = ["http3"]
        \\http3 = ["tls"]
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expectError(error.FeatureCycle, parseMetadata(allocator, source, arena.allocator()));
}

test "native-prebuilt の GNU glibc 必須と非 GNU の省略を検査する" {
    const allocator = testing.allocator;
    const gnu_without_glibc =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[artifact]
        \\kind = "native-prebuilt"
        \\runtimes = ["lnako"]
        \\[artifact.native]
        \\target_triple = "x86_64-linux-gnu"
        \\abi_version = 1
        \\library_path = "native/libdemo.so"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\
    ;
    var arena_a = std.heap.ArenaAllocator.init(allocator);
    defer arena_a.deinit();
    try testing.expectError(error.MissingField, parseMetadata(allocator, gnu_without_glibc, arena_a.allocator()));

    const musl_with_glibc =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[artifact]
        \\kind = "native-prebuilt"
        \\runtimes = ["lnako"]
        \\[artifact.native]
        \\target_triple = "x86_64-linux-musl"
        \\abi_version = 1
        \\glibc_min = "2.31"
        \\library_path = "native/libdemo.so"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\
    ;
    var arena_b = std.heap.ArenaAllocator.init(allocator);
    defer arena_b.deinit();
    try testing.expectError(error.InvalidGlibcVersion, parseMetadata(allocator, musl_with_glibc, arena_b.allocator()));

    const gnu_with_glibc =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[artifact]
        \\kind = "native-prebuilt"
        \\runtimes = ["lnako"]
        \\[artifact.native]
        \\target_triple = "x86_64-linux-gnu"
        \\abi_version = 1
        \\glibc_min = "2.31"
        \\library_path = "native/libdemo.so"
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\
    ;
    var arena_c = std.heap.ArenaAllocator.init(allocator);
    defer arena_c.deinit();
    var parsed = try parseMetadata(allocator, gnu_with_glibc, arena_c.allocator());
    defer parsed.document.deinit();
    try testing.expectEqual(@as(?u32, 1), parsed.model.artifact.native.?.abi_version);
}

test "LicenseRef を式から重複なく抽出し本文パスへ写す" {
    const allocator = testing.allocator;
    const references = try meta.licenseRefs(
        allocator,
        "MIT OR LicenseRef-Beta AND LicenseRef-Alpha OR LicenseRef-Beta",
    );
    defer allocator.free(references);
    try testing.expectEqual(@as(usize, 2), references.len);
    try testing.expectEqualStrings("LicenseRef-Alpha", references[0]);
    try testing.expectEqualStrings("LicenseRef-Beta", references[1]);
    const path = try meta.licenseRefPath(allocator, "LicenseRef-Alpha");
    defer allocator.free(path);
    try testing.expectEqualStrings("LICENSES/LicenseRef-Alpha.txt", path);
}

test "engines の範囲と runtimes・alias の字句を検証する" {
    const allocator = testing.allocator;
    const bad_range =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[engines]
        \\lnako = "1.2.3.4"
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\
    ;
    var arena_a = std.heap.ArenaAllocator.init(allocator);
    defer arena_a.deinit();
    try testing.expectError(error.InvalidRange, parseMetadata(allocator, bad_range, arena_a.allocator()));

    const bad_alias =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[[dependencies]]
        \\id = "@std/json"
        \\req = "^1.0.0"
        \\alias = "bad alias"
        \\
    ;
    var arena_b = std.heap.ArenaAllocator.init(allocator);
    defer arena_b.deinit();
    try testing.expectError(error.InvalidDependency, parseMetadata(allocator, bad_alias, arena_b.allocator()));
}

test "v1範囲はnode-semver 7.7.4のwildcardとqualifierを受理する" {
    const allocator = testing.allocator;
    const source =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[engines]
        \\lnako = "1.x.5"
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\[[dependencies]]
        \\id = "@std/json"
        \\req = "*.1"
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parsed = try parseMetadata(allocator, source, arena.allocator());
    defer parsed.document.deinit();
    try testing.expectEqualStrings("1.x.5", parsed.model.engines[0].range);
    try testing.expectEqualStrings("*.1", parsed.model.dependencies[0].req);

    const bad =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[engines]
        \\lnako = "1.x.5.6"
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\
    ;
    var arena_b = std.heap.ArenaAllocator.init(allocator);
    defer arena_b.deinit();
    try testing.expectError(error.InvalidRange, parseMetadata(allocator, bad, arena_b.allocator()));
}

test "METADATA を決定的に再シリアライズできる" {
    const allocator = testing.allocator;
    const source =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\description = "サンプル"
        \\license = "MIT"
        \\keywords = ["a", "b"]
        \\capabilities = ["pure-nako"]
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "scoped" }
        \\[features]
        \\default = ["tls"]
        \\tls = []
        \\[[dependencies]]
        \\id = "@std/json"
        \\req = "^1.0.0"
        \\features = []
        \\default_features = true
        \\optional = false
        \\
    ;
    var arena_a = std.heap.ArenaAllocator.init(allocator);
    defer arena_a.deinit();
    var parsed = try parseMetadata(allocator, source, arena_a.allocator());
    defer parsed.document.deinit();
    const first = try meta.emit(allocator, parsed.model);
    defer allocator.free(first);
    const second = try meta.emit(allocator, parsed.model);
    defer allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);

    var arena_b = std.heap.ArenaAllocator.init(allocator);
    defer arena_b.deinit();
    var reparsed = try parseMetadata(allocator, first, arena_b.allocator());
    defer reparsed.document.deinit();
    try testing.expectEqualStrings("@example/demo", reparsed.model.package.id);
    try testing.expectEqual(@as(usize, 1), reparsed.model.dependencies.len);
}

test "COMMANDS の global 命令だけを定数と分けて導出する" {
    const allocator = testing.allocator;
    const source =
        \\{"schema_version":1,"exports_global_commands":true,"exports":{
        \\".":{"binding":"scoped","commands":[{"name":"取得","kind":"function","args":[]}],"constants":["設定値"]},
        \\"./dsl":{"binding":"global","commands":[{"name":"公開取得","kind":"function","args":[{"name":"A","josi":["を"]}]}],"constants":["公開定数"]}
        \\}}
    ;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parsed = try mcommands.parse(allocator, source, arena.allocator());
    defer parsed.document.deinit();
    try testing.expect(parsed.model.exports_global_commands);
    const names = try mcommands.globalCommandNames(arena.allocator(), parsed.model);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("公開取得", names[0]);
    const root_export = parsed.model.findExport(".").?;
    try testing.expectEqualStrings("設定値", root_export.constants[0]);
}

test "COMMANDS の handmade な再シリアライズと再解析" {
    const allocator = testing.allocator;
    const exports = [_]mcommands.Export{
        .{
            .subpath = "./dsl",
            .binding = .global,
            .commands = &.{.{
                .name = "公開取得",
                .kind = "function",
                .args = &.{.{ .name = "A", .josi = &.{"を"} }},
            }},
            .constants = &.{"公開定数"},
        },
        .{
            .subpath = ".",
            .binding = .scoped,
            .commands = &.{},
            .constants = &.{"設定値"},
        },
    };
    const bytes = try mcommands.emit(allocator, &exports);
    defer allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parsed = try mcommands.parse(allocator, bytes, arena.allocator());
    defer parsed.document.deinit();
    try testing.expect(parsed.model.exports_global_commands);
    try testing.expectEqualStrings(".", parsed.model.exports[0].subpath);
    try testing.expectEqualStrings("./dsl", parsed.model.exports[1].subpath);
    try testing.expectEqualStrings("公開取得", parsed.model.exports[1].commands[0].name);
}

test "COMMANDS の重複命令名と型違いを拒否する" {
    const allocator = testing.allocator;
    const duplicate =
        \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[{"name":"取得","kind":"function","args":[]},{"name":"取得","kind":"function","args":[]}],"constants":[]}}}
    ;
    var arena_a = std.heap.ArenaAllocator.init(allocator);
    defer arena_a.deinit();
    try testing.expectError(error.DuplicateCommand, mcommands.parse(allocator, duplicate, arena_a.allocator()));

    const float_version =
        \\{"schema_version":1.5,"exports_global_commands":false,"exports":{}}
    ;
    var arena_b = std.heap.ArenaAllocator.init(allocator);
    defer arena_b.deinit();
    try testing.expectError(error.InvalidCommands, mcommands.parse(allocator, float_version, arena_b.allocator()));
}

test "FILES の索引を検証し決定的に書き出す" {
    const allocator = testing.allocator;
    const entries = [_]mfiles.Entry{
        .{ .path = "a.txt", .size = 1, .sha256 = mfiles.hash("a") },
        .{ .path = "B.txt", .size = 1, .sha256 = mfiles.hash("b") },
    };
    const bytes = try mfiles.emit(allocator, &entries);
    defer allocator.free(bytes);
    var model = try mfiles.parse(allocator, bytes);
    defer model.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), model.files.len);
    try testing.expectEqualStrings("B.txt", model.files[0].path);
    try testing.expectEqualStrings("a.txt", model.files[1].path);

    const unsorted =
        \\{"schema_version":1,"files":[{"path":"b.txt","size":1,"sha256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"path":"a.txt","size":1,"sha256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    try testing.expectError(error.NotSorted, mfiles.parse(allocator, unsorted));

    const uppercase_hash =
        \\{"schema_version":1,"files":[{"path":"a.txt","size":1,"sha256":"sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}]}
    ;
    try testing.expectError(error.InvalidHash, mfiles.parse(allocator, uppercase_hash));

    const traversal =
        \\{"schema_version":1,"files":[{"path":"../evil","size":1,"sha256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    try testing.expectError(error.InvalidPath, mfiles.parse(allocator, traversal));
}
