const std = @import("std");
const builtin = @import("builtin");

const native_source = @import("v1_native_source.zig");
const env = @import("v1_client_env.zig");
const types = @import("v1_types.zig");
const selection = @import("v1_selection.zig");

const testing = std.testing;
const io = testing.io;

const id = "@acme/native";
const sha = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const build_input = "native/build.zig";

fn write(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

fn executableScript(dir: std.Io.Dir, allocator: std.mem.Allocator, body: []const u8) ![:0]u8 {
    try write(dir, "fake-zig", body);
    var file = try dir.openFile(io, "fake-zig", .{ .mode = .read_write });
    defer file.close(io);
    try file.setPermissions(io, .executable_file);
    return dir.realPathFileAlloc(io, "fake-zig", allocator);
}

fn permission() selection.SourcePermission {
    return .{ .id = id, .sha256 = sha };
}

fn requirePosixShell() !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
}

fn readAll(dir: std.Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(io, path, testing.allocator, .limited(1024 * 1024));
}

/// 実際に `zig build` が受け取った引数とキャッシュ環境を記録し、
/// build.zig の親ディレクトリ名から一意な共有ライブラリを install する。
fn recordingScript(allocator: std.mem.Allocator, extension: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\set -eu
        \\printf 'run\n' >> "run.log"
        \\printf '%s\n' "$@" >> "args.log"
        \\printf '%s\n' "${{ZIG_GLOBAL_CACHE_DIR:-}}" >> "global.log"
        \\printf '%s\n' "${{ZIG_LOCAL_CACHE_DIR:-}}" >> "local.log"
        \\prefix=
        \\build_file=
        \\while [ "$#" -gt 0 ]; do
        \\  case "$1" in
        \\    --prefix) shift; prefix="$1" ;;
        \\    --build-file) shift; build_file="$1" ;;
        \\  esac
        \\  shift
        \\done
        \\name=$(basename "$(dirname "$build_file")")
        \\mkdir -p "$prefix/lib"
        \\printf built > "$prefix/lib/lib$name{s}"
        \\
    , .{extension});
}

fn expectNoBuildDirectory(dir: std.Io.Dir) !void {
    try testing.expectError(error.FileNotFound, dir.statFile(io, native_source.build_dir, .{}));
}

test "未許可では build.zig を読まずビルドも開始しない" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    try write(temporary.dir, build_input, "// fixture\n");
    const extension = try native_source.libraryExtension(builtin.os.tag);
    const script = try recordingScript(a, extension);
    defer a.free(script);
    const zig = try executableScript(temporary.dir, a, script);
    defer a.free(zig);

    const exports = [_]env.Export{.{ .subpath = ".", .entry = build_input, .binding = .scoped }};
    try testing.expectError(error.SourceNotPermitted, native_source.build(
        a,
        io,
        .{ .zig_executable = zig },
        temporary.dir,
        id,
        sha,
        &.{},
        &exports,
    ));
    try testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "run.log", .{}));
    try expectNoBuildDirectory(temporary.dir);
}

test "宣言された build.zig がなければビルドを開始しない" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    const script = "#!/bin/sh\nexit 0\n";
    const zig = try executableScript(temporary.dir, a, script);
    defer a.free(zig);

    const exports = [_]env.Export{.{ .subpath = ".", .entry = build_input, .binding = .scoped }};
    try testing.expectError(error.MissingBuildFile, native_source.build(
        a,
        io,
        .{ .zig_executable = zig },
        temporary.dir,
        id,
        sha,
        &.{permission()},
        &exports,
    ));
    try expectNoBuildDirectory(temporary.dir);
}

test "build.zig 以外の宣言ではビルドを開始しない" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    try write(temporary.dir, "src/index.nako3", "# not a build input\n");
    const script = "#!/bin/sh\nexit 0\n";
    const zig = try executableScript(temporary.dir, a, script);
    defer a.free(zig);

    const exports = [_]env.Export{.{ .subpath = ".", .entry = "src/index.nako3", .binding = .scoped }};
    try testing.expectError(error.InvalidBuildFile, native_source.build(
        a,
        io,
        .{ .zig_executable = zig },
        temporary.dir,
        id,
        sha,
        &.{permission()},
        &exports,
    ));
    try expectNoBuildDirectory(temporary.dir);
}

test "パッケージ外や空の入力パスを拒否する" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    const script = "#!/bin/sh\nexit 0\n";
    const zig = try executableScript(temporary.dir, a, script);
    defer a.free(zig);

    for ([_][]const u8{ "/build.zig", "../build.zig", "native//build.zig" }) |bad| {
        const exports = [_]env.Export{.{ .subpath = ".", .entry = bad, .binding = .scoped }};
        try testing.expectError(error.InvalidBuildFile, native_source.build(
            a,
            io,
            .{ .zig_executable = zig },
            temporary.dir,
            id,
            sha,
            &.{permission()},
            &exports,
        ));
    }
    try expectNoBuildDirectory(temporary.dir);
}

test "許可済みの宣言パスを --build-file で起動し 1 個のライブラリを返す" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    try write(temporary.dir, build_input, "// fixture\n");
    const extension = try native_source.libraryExtension(builtin.os.tag);
    const script = try recordingScript(a, extension);
    defer a.free(script);
    const zig = try executableScript(temporary.dir, a, script);
    defer a.free(zig);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const exports = [_]env.Export{.{ .subpath = ".", .entry = build_input, .binding = .scoped }};
    const rewritten = try native_source.build(
        allocator,
        io,
        .{ .zig_executable = zig },
        temporary.dir,
        id,
        sha,
        &.{permission()},
        &exports,
    );

    try testing.expectEqual(@as(usize, 1), rewritten.len);
    try testing.expectEqualStrings(".", rewritten[0].subpath);
    try testing.expect(std.mem.startsWith(u8, rewritten[0].entry, "native-build/"));
    const expected_library = try std.fmt.allocPrint(allocator, "/out/lib/libnative{s}", .{extension});
    defer allocator.free(expected_library);
    try testing.expect(std.mem.endsWith(u8, rewritten[0].entry, expected_library));
    try testing.expectEqual(types.Binding.scoped, rewritten[0].binding);

    const package_abs = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(package_abs);
    const expected_build_file = try std.fs.path.join(allocator, &.{ package_abs, build_input });
    defer allocator.free(expected_build_file);

    const args = try readAll(temporary.dir, "args.log");
    defer a.free(args);
    try testing.expect(std.mem.indexOf(u8, args, "--build-file") != null);
    try testing.expect(std.mem.indexOf(u8, args, expected_build_file) != null);
    try testing.expect(std.mem.indexOf(u8, args, "--prefix") != null);
    try testing.expect(std.mem.indexOf(u8, args, "--cache-dir") != null);
    try testing.expect(std.mem.indexOf(u8, args, "--global-cache") == null);

    const global = try readAll(temporary.dir, "global.log");
    defer a.free(global);
    try testing.expect(std.mem.indexOf(u8, global, "native-build/") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, global, "\n"), "/global-cache"));
    const local = try readAll(temporary.dir, "local.log");
    defer a.free(local);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, local, "\n"), "/cache"));

    const bytes = try temporary.dir.readFileAlloc(io, rewritten[0].entry, a, .limited(64));
    defer a.free(bytes);
    try testing.expectEqualStrings("built", bytes);
}

test "同じ入力を選ぶ複数サブパスは 1 回だけビルドして同じ成果物を共有する" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    try write(temporary.dir, build_input, "// fixture\n");
    const extension = try native_source.libraryExtension(builtin.os.tag);
    const script = try recordingScript(a, extension);
    defer a.free(script);
    const zig = try executableScript(temporary.dir, a, script);
    defer a.free(zig);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const exports = [_]env.Export{
        .{ .subpath = ".", .entry = build_input, .binding = .scoped },
        .{ .subpath = "./client", .entry = build_input, .binding = .global },
    };
    const rewritten = try native_source.build(
        arena.allocator(),
        io,
        .{ .zig_executable = zig },
        temporary.dir,
        id,
        sha,
        &.{permission()},
        &exports,
    );

    try testing.expectEqual(@as(usize, 2), rewritten.len);
    try testing.expectEqualStrings(".", rewritten[0].subpath);
    try testing.expectEqualStrings("./client", rewritten[1].subpath);
    try testing.expectEqualStrings(rewritten[0].entry, rewritten[1].entry);
    try testing.expectEqual(types.Binding.global, rewritten[1].binding);

    const runs = try readAll(temporary.dir, "run.log");
    defer a.free(runs);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, runs, "run\n"));
}

test "異なる入力は別の出力とキャッシュでビルドし、サブパスごとに割り当てる" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    try write(temporary.dir, "a/build.zig", "// a\n");
    try write(temporary.dir, "b/build.zig", "// b\n");
    const extension = try native_source.libraryExtension(builtin.os.tag);
    const script = try recordingScript(a, extension);
    defer a.free(script);
    const zig = try executableScript(temporary.dir, a, script);
    defer a.free(zig);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const exports = [_]env.Export{
        .{ .subpath = ".", .entry = "a/build.zig", .binding = .scoped },
        .{ .subpath = "./b", .entry = "b/build.zig", .binding = .scoped },
    };
    const rewritten = try native_source.build(
        arena.allocator(),
        io,
        .{ .zig_executable = zig },
        temporary.dir,
        id,
        sha,
        &.{permission()},
        &exports,
    );

    try testing.expectEqual(@as(usize, 2), rewritten.len);
    const expected_a = try std.fmt.allocPrint(arena.allocator(), "/out/lib/liba{s}", .{extension});
    defer arena.allocator().free(expected_a);
    const expected_b = try std.fmt.allocPrint(arena.allocator(), "/out/lib/libb{s}", .{extension});
    defer arena.allocator().free(expected_b);
    try testing.expect(std.mem.endsWith(u8, rewritten[0].entry, expected_a));
    try testing.expect(std.mem.endsWith(u8, rewritten[1].entry, expected_b));
    try testing.expect(!std.mem.eql(u8, rewritten[0].entry, rewritten[1].entry));

    const runs = try readAll(temporary.dir, "run.log");
    defer a.free(runs);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, runs, "run\n"));

    const global = try readAll(temporary.dir, "global.log");
    defer a.free(global);
    var lines = std.mem.tokenizeScalar(u8, global, '\n');
    const first = lines.next() orelse return error.TestUnexpectedResult;
    const second = lines.next() orelse return error.TestUnexpectedResult;
    try testing.expect(!std.mem.eql(u8, first, second));
    try testing.expect(std.mem.indexOf(u8, first, "native-build/") != null);
    try testing.expect(std.mem.indexOf(u8, second, "native-build/") != null);
}

test "出力が 0 個なら失敗する（既存ライブラリへフォールバックしない）" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    try write(temporary.dir, build_input, "// fixture\n");
    const extension = try native_source.libraryExtension(builtin.os.tag);
    const prebuilt = try std.fmt.allocPrint(a, "prebuilt{s}", .{extension});
    defer a.free(prebuilt);
    try write(temporary.dir, prebuilt, "not-a-build-output");

    const script =
        \\#!/bin/sh
        \\set -eu
        \\exit 0
        \\
    ;
    const zig = try executableScript(temporary.dir, a, script);
    defer a.free(zig);

    const exports = [_]env.Export{.{ .subpath = ".", .entry = build_input, .binding = .scoped }};
    try testing.expectError(error.BuildOutputMissing, native_source.build(
        a,
        io,
        .{ .zig_executable = zig },
        temporary.dir,
        id,
        sha,
        &.{permission()},
        &exports,
    ));
}

test "ホスト用ライブラリが複数なら曖昧として失敗する" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    try write(temporary.dir, build_input, "// fixture\n");
    const extension = try native_source.libraryExtension(builtin.os.tag);
    const script = try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\set -eu
        \\prefix=
        \\while [ "$#" -gt 0 ]; do
        \\  case "$1" in
        \\    --prefix) shift; prefix="$1" ;;
        \\  esac
        \\  shift
        \\done
        \\mkdir -p "$prefix/lib"
        \\printf one > "$prefix/lib/libone{s}"
        \\printf two > "$prefix/lib/libtwo{s}"
        \\
    , .{ extension, extension });
    defer a.free(script);
    const zig = try executableScript(temporary.dir, a, script);
    defer a.free(zig);

    const exports = [_]env.Export{.{ .subpath = ".", .entry = build_input, .binding = .scoped }};
    try testing.expectError(error.BuildOutputAmbiguous, native_source.build(
        a,
        io,
        .{ .zig_executable = zig },
        temporary.dir,
        id,
        sha,
        &.{permission()},
        &exports,
    ));
}

test "zig build の非 0 終了は失敗として扱う" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    try write(temporary.dir, build_input, "// fixture\n");
    const script =
        \\#!/bin/sh
        \\exit 7
        \\
    ;
    const zig = try executableScript(temporary.dir, a, script);
    defer a.free(zig);

    const exports = [_]env.Export{.{ .subpath = ".", .entry = build_input, .binding = .scoped }};
    try testing.expectError(error.BuildFailed, native_source.build(
        a,
        io,
        .{ .zig_executable = zig },
        temporary.dir,
        id,
        sha,
        &.{permission()},
        &exports,
    ));
}

test "アーカイブ由来の native-build をビルド出力として再利用しない" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    try write(temporary.dir, build_input, "// fixture\n");
    const extension = try native_source.libraryExtension(builtin.os.tag);
    const stale = try std.fmt.allocPrint(a, "{s}/out/lib/libstale{s}", .{ native_source.build_dir, extension });
    defer a.free(stale);
    try write(temporary.dir, stale, "stale");

    const exports = [_]env.Export{.{ .subpath = ".", .entry = build_input, .binding = .scoped }};
    try testing.expectError(error.BuildDirectoryConflict, native_source.build(
        a,
        io,
        .{ .zig_executable = "definitely-not-zig" },
        temporary.dir,
        id,
        sha,
        &.{permission()},
        &exports,
    ));
}

test "export が空ならビルドしない" {
    try requirePosixShell();
    const a = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    try write(temporary.dir, build_input, "// fixture\n");
    const script = "#!/bin/sh\nexit 0\n";
    const zig = try executableScript(temporary.dir, a, script);
    defer a.free(zig);

    try testing.expectError(error.UnsupportedNativeSourceExports, native_source.build(
        a,
        io,
        .{ .zig_executable = zig },
        temporary.dir,
        id,
        sha,
        &.{permission()},
        &.{},
    ));
    try expectNoBuildDirectory(temporary.dir);
}

test "ホスト別の共有ライブラリ拡張子" {
    try testing.expectEqualStrings(".dylib", try native_source.libraryExtension(.macos));
    try testing.expectEqualStrings(".so", try native_source.libraryExtension(.linux));
    try testing.expectEqualStrings(".dll", try native_source.libraryExtension(.windows));
    try testing.expectError(error.UnsupportedHost, native_source.libraryExtension(.freebsd));
}

test {
    _ = @import("v1_native_source_e2e_test.zig");
}
