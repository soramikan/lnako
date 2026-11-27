//! `v1_client_materialize` の交叉検査テスト（§3.3・§3.5・§4.3・§6.3）。
//!
//! 取得時の SHA-256 照合後に呼ばれる `defaultMaterialize` が、選択に使った
//! index の `Artifact` とアーカイブ正本の runtimes/native 情報を展開前に
//! 照合すること、失敗時に `dest` を変更しないこと、`Verified` の arena を
//! 借用した文字列を戻り値へ漏らさないことを確認する。

const std = @import("std");
const testing = std.testing;

const types = @import("v1_types.zig");
const zip = @import("v1_zip.zig");
const mfiles = @import("v1_metadata_files.zig");
const archive = @import("v1_archive.zig");
const materialize = @import("v1_client_materialize.zig");

const Allocator = std.mem.Allocator;
const payload = "# fixture\n";

const universal_metadata =
    \\schema_version = 1
    \\
    \\[package]
    \\id = "@example/demo"
    \\version = "1.0.0"
    \\license = "MIT"
    \\
    \\[artifact]
    \\kind = "universal"
    \\runtimes = ["lnako", "cnako", "wnako"]
    \\
    \\[exports]
    \\"." = { entry = "src/main.nako3", binding = "scoped" }
    \\
;

const native_prebuilt_metadata =
    \\schema_version = 1
    \\
    \\[package]
    \\id = "@example/demo"
    \\version = "1.0.0"
    \\license = "MIT"
    \\
    \\[artifact]
    \\kind = "native-prebuilt"
    \\runtimes = ["lnako"]
    \\
    \\[artifact.native]
    \\target_triple = "x86_64-linux-gnu"
    \\abi_version = 1
    \\glibc_min = "2.31"
    \\library_path = "native/libdemo.so"
    \\
    \\[exports]
    \\"." = { entry = "src/main.nako3", binding = "scoped" }
    \\
;

const native_source_metadata =
    \\schema_version = 1
    \\
    \\[package]
    \\id = "@example/demo"
    \\version = "1.0.0"
    \\license = "MIT"
    \\
    \\[artifact]
    \\kind = "native-source"
    \\runtimes = ["lnako"]
    \\
    \\[artifact.native]
    \\abi_version = 1
    \\
    \\[exports]
    \\"." = { entry = "src/main.nako3", binding = "scoped" }
    \\
;

const scoped_commands =
    \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[],"constants":[]}}}
;

const global_metadata =
    \\schema_version = 1
    \\
    \\[package]
    \\id = "@example/demo"
    \\version = "1.0.0"
    \\license = "MIT"
    \\
    \\[artifact]
    \\kind = "universal"
    \\runtimes = ["lnako", "cnako", "wnako"]
    \\
    \\[exports]
    \\"." = { entry = "src/main.nako3", binding = "global" }
    \\
;

const global_commands =
    \\{"schema_version":1,"exports_global_commands":true,"exports":{".":{"binding":"global","commands":[{"name":"取得","kind":"command","args":[]}],"constants":[]}}}
;

const Extra = struct {
    path: []const u8,
    data: []const u8,
};

fn buildFixture(
    allocator: Allocator,
    metadata_text: []const u8,
    commands_text: []const u8,
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
        try file_entries.append(allocator, mfiles.entryFor(extra.path, extra.data));
    }

    const files_bytes = try mfiles.emit(allocator, file_entries.items);
    defer allocator.free(files_bytes);
    try entries.append(allocator, .{ .path = archive.files_path, .data = files_bytes });
    return zip.build(allocator, entries.items, .{});
}

fn artifactHash(buffer: *[71]u8, bytes: []const u8) []const u8 {
    const digest = mfiles.hash(bytes);
    return std.fmt.bufPrint(buffer, "sha256:{s}", .{
        std.fmt.bytesToHex(digest, .lower),
    }) catch unreachable;
}

/// `dest` に entry が一つも作られていないことを確認する。
fn expectEmptyDest(dir: std.Io.Dir) !void {
    var iterable = try dir.openDir(testing.io, ".", .{ .iterate = true });
    defer iterable.close(testing.io);
    var iterator = iterable.iterate();
    var count: usize = 0;
    while (try iterator.next(testing.io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 0), count);
}

fn expectMaterializeError(
    expected_error: anyerror,
    bytes: []const u8,
    artifact: *const types.Artifact,
    expected: materialize.Expected,
    dest: std.Io.Dir,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(expected_error, materialize.defaultMaterialize(
        null,
        testing.io,
        testing.allocator,
        artifact,
        expected,
        bytes,
        dest,
        arena_state.allocator(),
    ));
    try expectEmptyDest(dest);
}

test "runtimes 集合が一致すれば index の順序に依存せず展開する" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, universal_metadata, scoped_commands, &.{});
    defer allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var hash_buffer: [71]u8 = undefined;
    const artifact = types.Artifact{
        .kind = .universal,
        .runtimes = &.{ .wnako, .lnako, .cnako },
        .sha256 = artifactHash(&hash_buffer, bytes),
    };
    const result = try materialize.defaultMaterialize(
        null,
        testing.io,
        allocator,
        &artifact,
        .{ .id = "@example/demo", .version = "1.0.0", .kind = .universal, .runtime = .lnako },
        bytes,
        tmp.dir,
        arena_state.allocator(),
    );

    try testing.expectEqual(@as(usize, 1), result.exports.len);
    try testing.expectEqualStrings(".", result.exports[0].subpath);
    try testing.expectEqualStrings("src/main.nako3", result.exports[0].entry);
    try testing.expect(!result.exports_global_commands);
    try testing.expectEqual(@as(usize, 0), result.global_commands.len);

    const written = try tmp.dir.readFileAlloc(testing.io, "src/main.nako3", allocator, .limited(1024));
    defer allocator.free(written);
    try testing.expectEqualStrings(payload, written);
}

test "runtimes 集合が異なる場合は展開せず dest を変更しない" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, universal_metadata, scoped_commands, &.{});
    defer allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var hash_buffer: [71]u8 = undefined;
    const artifact = types.Artifact{
        .kind = .universal,
        // アーカイブ正本は wnako を含むが index は含まない。
        .runtimes = &.{ .lnako, .cnako },
        .sha256 = artifactHash(&hash_buffer, bytes),
    };
    try expectMaterializeError(
        error.ArtifactRuntimeMismatch,
        bytes,
        &artifact,
        .{ .id = "@example/demo", .version = "1.0.0", .kind = .universal, .runtime = .lnako },
        tmp.dir,
    );
}

test "native-prebuilt の triple が異なる場合は展開せず dest を変更しない" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, native_prebuilt_metadata, scoped_commands, &.{
        .{ .path = "native/libdemo.so", .data = "DUMMY-ELF" },
    });
    defer allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var hash_buffer: [71]u8 = undefined;
    const artifact = types.Artifact{
        .kind = .@"native-prebuilt",
        .runtimes = &.{.lnako},
        .target_triple = "aarch64-macos-none",
        .abi_version = 1,
        .sha256 = artifactHash(&hash_buffer, bytes),
    };
    try expectMaterializeError(
        error.ArtifactTargetMismatch,
        bytes,
        &artifact,
        .{ .id = "@example/demo", .version = "1.0.0", .kind = .@"native-prebuilt", .runtime = .lnako },
        tmp.dir,
    );
}

test "native-prebuilt の ABI が異なる場合は展開せず dest を変更しない" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, native_prebuilt_metadata, scoped_commands, &.{
        .{ .path = "native/libdemo.so", .data = "DUMMY-ELF" },
    });
    defer allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var hash_buffer: [71]u8 = undefined;
    const artifact = types.Artifact{
        .kind = .@"native-prebuilt",
        .runtimes = &.{.lnako},
        .target_triple = "x86_64-linux-gnu",
        .abi_version = 2,
        .glibc_min = "2.31",
        .sha256 = artifactHash(&hash_buffer, bytes),
    };
    try expectMaterializeError(
        error.ArtifactTargetMismatch,
        bytes,
        &artifact,
        .{ .id = "@example/demo", .version = "1.0.0", .kind = .@"native-prebuilt", .runtime = .lnako },
        tmp.dir,
    );
}

test "native-prebuilt の glibc_min が異なる場合は展開せず dest を変更しない" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, native_prebuilt_metadata, scoped_commands, &.{
        .{ .path = "native/libdemo.so", .data = "DUMMY-ELF" },
    });
    defer allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var hash_buffer: [71]u8 = undefined;
    const artifact = types.Artifact{
        .kind = .@"native-prebuilt",
        .runtimes = &.{.lnako},
        .target_triple = "x86_64-linux-gnu",
        .abi_version = 1,
        .glibc_min = "2.28",
        .sha256 = artifactHash(&hash_buffer, bytes),
    };
    try expectMaterializeError(
        error.ArtifactTargetMismatch,
        bytes,
        &artifact,
        .{ .id = "@example/demo", .version = "1.0.0", .kind = .@"native-prebuilt", .runtime = .lnako },
        tmp.dir,
    );
}

test "native-source の ABI が異なる場合は展開せず dest を変更しない" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, native_source_metadata, scoped_commands, &.{});
    defer allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var hash_buffer: [71]u8 = undefined;
    const artifact = types.Artifact{
        .kind = .@"native-source",
        .runtimes = &.{.lnako},
        .abi_version = 2,
        .sha256 = artifactHash(&hash_buffer, bytes),
    };
    try expectMaterializeError(
        error.ArtifactTargetMismatch,
        bytes,
        &artifact,
        .{ .id = "@example/demo", .version = "1.0.0", .kind = .@"native-source", .runtime = .lnako },
        tmp.dir,
    );
}

test "index の digest 形式が不正なら展開せず dest を変更しない" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, universal_metadata, scoped_commands, &.{});
    defer allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const artifact = types.Artifact{
        .kind = .universal,
        .runtimes = &.{ .lnako, .cnako, .wnako },
        .sha256 = "sha256:not-a-digest",
    };
    try expectMaterializeError(
        error.ArtifactMetadataMismatch,
        bytes,
        &artifact,
        .{ .id = "@example/demo", .version = "1.0.0", .kind = .universal, .runtime = .lnako },
        tmp.dir,
    );
}

test "native-prebuilt の照合が一致すれば展開する" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, native_prebuilt_metadata, scoped_commands, &.{
        .{ .path = "native/libdemo.so", .data = "DUMMY-ELF" },
    });
    defer allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var hash_buffer: [71]u8 = undefined;
    const artifact = types.Artifact{
        .kind = .@"native-prebuilt",
        .runtimes = &.{.lnako},
        .target_triple = "x86_64-linux-gnu",
        .abi_version = 1,
        .glibc_min = "2.31",
        .sha256 = artifactHash(&hash_buffer, bytes),
    };
    const result = try materialize.defaultMaterialize(
        null,
        testing.io,
        allocator,
        &artifact,
        .{ .id = "@example/demo", .version = "1.0.0", .kind = .@"native-prebuilt", .runtime = .lnako },
        bytes,
        tmp.dir,
        arena_state.allocator(),
    );
    try testing.expectEqual(@as(usize, 1), result.exports.len);

    const library = try tmp.dir.readFileAlloc(testing.io, "native/libdemo.so", allocator, .limited(1024));
    defer allocator.free(library);
    try testing.expectEqualStrings("DUMMY-ELF", library);
}

test "global 命令名は verified arena の解放後も arena 所有の複製を返す" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, global_metadata, global_commands, &.{});
    defer allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var hash_buffer: [71]u8 = undefined;
    const artifact = types.Artifact{
        .kind = .universal,
        .runtimes = &.{ .lnako, .cnako, .wnako },
        .sha256 = artifactHash(&hash_buffer, bytes),
    };
    const result = try materialize.defaultMaterialize(
        null,
        testing.io,
        allocator,
        &artifact,
        .{ .id = "@example/demo", .version = "1.0.0", .kind = .universal, .runtime = .lnako },
        bytes,
        tmp.dir,
        arena_state.allocator(),
    );

    try testing.expect(result.exports_global_commands);
    try testing.expectEqual(@as(usize, 1), result.exports.len);
    try testing.expectEqual(types.Binding.global, result.exports[0].binding);
    try testing.expectEqual(@as(usize, 1), result.global_commands.len);
    try testing.expectEqualStrings("取得", result.global_commands[0]);
}

test "再利用検証は同じ ZIP でも index の target_triple 変更を拒否する" {
    const allocator = testing.allocator;
    const bytes = try buildFixture(allocator, native_prebuilt_metadata, scoped_commands, &.{
        .{ .path = "native/libdemo.so", .data = "DUMMY-ELF" },
    });
    defer allocator.free(bytes);

    var hash_buffer: [71]u8 = undefined;
    const artifact = types.Artifact{
        .kind = .@"native-prebuilt",
        .runtimes = &.{.lnako},
        // アーカイブ正本は x86_64-linux-gnu。index だけ triple が変わる。
        .target_triple = "aarch64-macos-none",
        .abi_version = 1,
        .sha256 = artifactHash(&hash_buffer, bytes),
    };
    try testing.expectError(error.ArtifactTargetMismatch, materialize.verifyArtifact(
        allocator,
        &artifact,
        .{ .id = "@example/demo", .version = "1.0.0", .kind = .@"native-prebuilt", .runtime = .lnako },
        bytes,
    ));
}
