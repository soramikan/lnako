//! `native-source` のローカルビルド（§3.3・§6.3・O07）。
//!
//! 仕様は「ルートが Package ID とアーティファクト SHA-256 に対して明示許可
//! した場合だけビルドする」とだけ定め、ビルド入力の呼び出しは実装へ委任
//! している。ここではその規約を次のように固定する。
//!
//! 1. 選択器と同じ `v1_selection.isSourcePermitted` で、対象ノードの
//!    Package ID と SHA-256 を再検査する。許可がなければ `zig` を起動しない。
//! 2. ビルド入力は、そのアーティファクトの `exports` が選んだ実パス
//!    （`artifact.entries` があればその値、なければ共通 `entry`）である。
//!    `v1_client_materialize` が `selectedEntry` で解決済みの値をそのまま
//!    使う。入力はアーカイブ内の通常ファイル `build.zig` でなければならない。
//! 3. 同じビルド入力を選ぶ複数のサブパスは 1 回だけビルドし、同じ成果物を
//!    共有する。異なる入力は入力パスの SHA-256 から決めた別々の
//!    `native-build/<key>/` でビルドし、`--prefix`・ローカルキャッシュ・
//!    グローバルキャッシュをすべてその下へ分離する。
//! 4. `zig build` は `--build-file` で宣言された入力だけを起動する。
//!    `--prefix` は `<key>/out`、ローカルキャッシュは `--cache-dir`、
//!    グローバルキャッシュは子プロセスの `ZIG_GLOBAL_CACHE_DIR` で
//!    `<key>/global-cache` に向ける（Zig 0.17.0 の `zig build` に
//!    `--global-cache` オプションはない）。
//! 5. `<key>/out/{lib,bin}` にホスト用の共有ライブラリがちょうど 1 個だけ
//!    通常ファイルとして install された場合に限り成功とする。各入力の
//!    成果物を、その入力を選んだ全サブパスの `entry` へ差し替える。
//!
//! ビルドは許可されたソースのコードを実行する。プロセスの権限で動くため
//! サンドボックスではない。許可（ID + SHA-256）が唯一の境界である。
//!
//! `artifact.native.library_path` は native-source では参照しない。これは
//! 後段入力（アーカイブ内の既成ライブラリ）を流用しないためである。

const std = @import("std");
const builtin = @import("builtin");

const env = @import("v1_client_env.zig");
const fetch = @import("fetch.zig");
const selection = @import("v1_selection.zig");
const types = @import("v1_types.zig");

const Allocator = std.mem.Allocator;

pub const build_file = "build.zig";
pub const build_dir = "native-build";
pub const default_timeout_seconds: u32 = 600;
pub const default_max_output_bytes: usize = 64 * 1024;

pub const Options = struct {
    /// 使用する Zig 実行ファイル。テストでは固定の代替を注入できる。
    zig_executable: []const u8 = "zig",
    /// 1 回の `zig build` の timeout。入力が複数なら入力ごとに適用する。
    timeout_seconds: u32 = default_timeout_seconds,
    /// 1 回の `zig build` の stdout/stderr を保持する上限。超えたら失敗する。
    max_output_bytes: usize = default_max_output_bytes,
    /// CLI から渡された環境を保ち、ビルド用キャッシュの設定だけを変える。
    environ_map: ?*const std.process.Environ.Map = null,
};

pub const Error = error{
    /// ID + SHA-256 の明示許可がない。ビルドも展開も開始しない。
    SourceNotPermitted,
    /// 宣言された入力がアーカイブ内にない。
    MissingBuildFile,
    /// 入力が通常ファイルでない、空、または `build.zig` ではない。
    InvalidBuildFile,
    /// 既に `native-build/` が存在する（アーカイブ由来の出力を拒否する）。
    BuildDirectoryConflict,
    /// `zig` を起動できない。
    BuildUnavailable,
    /// `zig build` が非 0 で終了した、または起動後に異常終了した。
    BuildFailed,
    /// `zig build` が時間内に終了しなかった。
    BuildTimedOut,
    /// ビルド出力が取得上限を超えた。
    BuildOutputTooLarge,
    /// install された共有ライブラリがない。
    BuildOutputMissing,
    /// 1 回のビルドでホスト用の共有ライブラリが複数 install された。
    BuildOutputAmbiguous,
    /// 出力が通常ファイルでない、またはパッケージ外を指す。
    UnsafeBuildOutput,
    /// native-source の export が空。
    UnsupportedNativeSourceExports,
    /// 共有ライブラリの拡張子を決められないホスト。
    UnsupportedHost,
};

const BuildJob = struct {
    /// アーカイブ内の `build.zig` 相対パス。`exports` から借用する。
    input: []const u8,
    /// 入力パスの SHA-256 先頭 16 バイトを小文字 hex にしたもの。
    key: []u8,
    /// `findInstalledLibrary` が返す、パッケージルート相対の成果物。
    library: []const u8 = &.{},
};

/// ビルドを実行し、各 export の `entry` を対応する成果物へ差し替えて返す。
///
/// 返す文字列は `allocator` が所有する。`package_dir` は展開済みパッケージの
/// ルートで、`sha256` は取得・lock 照合を終えた実バイト列の SHA-256 と
/// 同じでなければならない（呼び出し側が保証する）。
pub fn build(
    allocator: Allocator,
    io: std.Io,
    options: Options,
    package_dir: std.Io.Dir,
    id: []const u8,
    sha256: []const u8,
    permissions: []const selection.SourcePermission,
    exports: []const env.Export,
) ![]const env.Export {
    // 1. 選択器と同じ規則で再検査する。未許可なら何も触らない。
    if (!selection.isSourcePermitted(id, sha256, permissions)) return error.SourceNotPermitted;
    if (exports.len == 0) return error.UnsupportedNativeSourceExports;

    // 2. 宣言された入力だけを検証し、重複を 1 回のビルドへまとめる。
    var jobs: std.ArrayList(BuildJob) = .empty;
    defer {
        for (jobs.items) |job| allocator.free(job.key);
        jobs.deinit(allocator);
    }
    for (exports) |export_entry| {
        try validateBuildInput(io, package_dir, export_entry.entry);
        if (findJob(jobs.items, export_entry.entry) != null) continue;
        const key = try buildKey(allocator, export_entry.entry);
        errdefer allocator.free(key);
        try jobs.append(allocator, .{ .input = export_entry.entry, .key = key });
    }
    if (jobs.items.len == 0) return error.UnsupportedNativeSourceExports;

    // 入力順に固定する。出力の割り当ては exports の順序を保つ。
    std.mem.sort(BuildJob, jobs.items, {}, struct {
        fn lessThan(_: void, left: BuildJob, right: BuildJob) bool {
            return std.mem.order(u8, left.input, right.input) == .lt;
        }
    }.lessThan);

    // 3. アーカイブに `native-build/` が含まれていたら拒否する。空の
    //    ディレクトリを新規作成できることが、出力がビルド由来である条件。
    const existing = package_dir.statFile(io, build_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing != null) return error.BuildDirectoryConflict;
    package_dir.createDir(io, build_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.BuildDirectoryConflict,
        else => return err,
    };

    const package_abs = try package_dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(package_abs);

    // 親の環境を引き継ぎ、各ビルドのキャッシュだけを staging 内へ差し替える。
    var child_env = if (options.environ_map) |parent_env|
        try parent_env.clone(allocator)
    else if (comptime builtin.link_libc or builtin.os.tag == .windows)
        (try fetch.readEnvMap(allocator)) orelse std.process.Environ.Map.init(allocator)
    else
        std.process.Environ.Map.init(allocator);
    defer child_env.deinit();

    for (jobs.items) |*job| {
        job.library = try runBuild(allocator, io, options, package_dir, package_abs, job, &child_env);
    }

    // 4. 各サブパスを、そのサブパスが選んだ入力の成果物へ差し替える。
    return rewriteExports(allocator, exports, jobs.items);
}

fn validateBuildInput(io: std.Io, package_dir: std.Io.Dir, path: []const u8) !void {
    if (!types.validPath(path)) return error.InvalidBuildFile;
    if (!std.mem.eql(u8, std.fs.path.basename(path), build_file)) return error.InvalidBuildFile;
    const stat = package_dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.MissingBuildFile,
        error.SymLinkLoop => return error.InvalidBuildFile,
        else => return err,
    };
    if (stat.kind != .file or stat.size == 0) return error.InvalidBuildFile;
}

fn buildKey(allocator: Allocator, input: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, hex[0..32]);
}

fn findJob(jobs: []const BuildJob, input: []const u8) ?*const BuildJob {
    for (jobs) |*job| {
        if (std.mem.eql(u8, job.input, input)) return job;
    }
    return null;
}

fn runBuild(
    allocator: Allocator,
    io: std.Io,
    options: Options,
    package_dir: std.Io.Dir,
    package_abs: []const u8,
    job: *const BuildJob,
    child_env: *std.process.Environ.Map,
) ![]const u8 {
    const root_rel = try std.fs.path.join(allocator, &.{ build_dir, job.key });
    defer allocator.free(root_rel);
    const out_rel = try std.fs.path.join(allocator, &.{ root_rel, "out" });
    defer allocator.free(out_rel);
    const cache_rel = try std.fs.path.join(allocator, &.{ root_rel, "cache" });
    defer allocator.free(cache_rel);
    const global_cache_rel = try std.fs.path.join(allocator, &.{ root_rel, "global-cache" });
    defer allocator.free(global_cache_rel);

    package_dir.createDir(io, root_rel, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.BuildDirectoryConflict,
        else => return err,
    };
    try package_dir.createDir(io, out_rel, .default_dir);
    try package_dir.createDir(io, cache_rel, .default_dir);
    try package_dir.createDir(io, global_cache_rel, .default_dir);

    const out_abs = try std.fs.path.join(allocator, &.{ package_abs, out_rel });
    defer allocator.free(out_abs);
    const cache_abs = try std.fs.path.join(allocator, &.{ package_abs, cache_rel });
    defer allocator.free(cache_abs);
    const global_cache_abs = try std.fs.path.join(allocator, &.{ package_abs, global_cache_rel });
    defer allocator.free(global_cache_abs);
    const build_file_abs = try std.fs.path.resolve(allocator, &.{ package_abs, job.input });
    defer allocator.free(build_file_abs);
    if (!isWithin(package_abs, build_file_abs)) return error.UnsafeBuildOutput;

    // Zig 0.17.0 の `zig build` はグローバルキャッシュの CLI オプションを
    // 持たない。子プロセスの環境変数で staging 内へ向ける。
    try child_env.put("ZIG_GLOBAL_CACHE_DIR", global_cache_abs);
    try child_env.put("ZIG_LOCAL_CACHE_DIR", cache_abs);

    const argv = [_][]const u8{
        options.zig_executable,
        "build",
        "--build-file",
        build_file_abs,
        "--prefix",
        out_abs,
        "--cache-dir",
        cache_abs,
        "--summary",
        "none",
    };

    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = package_abs },
        .environ_map = child_env,
        .stdout_limit = .limited(options.max_output_bytes),
        .stderr_limit = .limited(options.max_output_bytes),
        .timeout = .{ .duration = .{
            .raw = .fromSeconds(options.timeout_seconds),
            .clock = .awake,
        } },
    }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.BuildUnavailable,
        error.StreamTooLong => return error.BuildOutputTooLarge,
        error.Timeout => return error.BuildTimedOut,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.BuildFailed,
        else => return error.BuildFailed,
    }

    return findInstalledLibrary(allocator, io, package_dir, package_abs, out_rel);
}

/// ホスト用の共有ライブラリ拡張子。`native-source` のビルドはホスト向け。
pub fn libraryExtension(os: std.Target.Os.Tag) ![]const u8 {
    return switch (os) {
        .macos => ".dylib",
        .linux => ".so",
        .windows => ".dll",
        else => error.UnsupportedHost,
    };
}

fn findInstalledLibrary(
    allocator: Allocator,
    io: std.Io,
    package_dir: std.Io.Dir,
    package_abs: []const u8,
    output_rel: []const u8,
) ![]const u8 {
    const extension = try libraryExtension(builtin.os.tag);
    var found: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (found.items) |path| allocator.free(path);
        found.deinit(allocator);
    }

    for ([_][]const u8{ "lib", "bin" }) |subdir| {
        const rel_dir = try std.fs.path.join(allocator, &.{ output_rel, subdir });
        defer allocator.free(rel_dir);
        var dir = package_dir.openDir(io, rel_dir, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.NotDir, error.SymLinkLoop => return error.UnsafeBuildOutput,
            else => return err,
        };
        defer dir.close(io);

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), extension)) continue;
            if (entry.kind != .file) return error.UnsafeBuildOutput;
            const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
            if (stat.kind != .file or stat.size == 0) return error.UnsafeBuildOutput;
            const path = try std.fs.path.join(allocator, &.{ output_rel, subdir, entry.name });
            found.append(allocator, path) catch |err| {
                allocator.free(path);
                return err;
            };
        }
    }

    if (found.items.len == 0) return error.BuildOutputMissing;
    if (found.items.len != 1) return error.BuildOutputAmbiguous;

    const library = found.items[0];
    found.deinit(allocator);
    const absolute = try std.fs.path.resolve(allocator, &.{ package_abs, library });
    defer allocator.free(absolute);
    if (!isWithin(package_abs, absolute)) return error.UnsafeBuildOutput;
    return library;
}

fn rewriteExports(
    allocator: Allocator,
    exports: []const env.Export,
    jobs: []const BuildJob,
) ![]const env.Export {
    const rewritten = try allocator.alloc(env.Export, exports.len);
    for (exports, 0..) |export_entry, index| {
        const job = findJob(jobs, export_entry.entry) orelse return error.MissingBuildFile;
        rewritten[index] = .{
            .subpath = export_entry.subpath,
            .entry = job.library,
            .binding = export_entry.binding,
        };
    }
    return rewritten;
}

fn isWithin(root: []const u8, path: []const u8) bool {
    if (path.len <= root.len) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    return std.fs.path.isSep(path[root.len]);
}

test {
    _ = @import("v1_native_source_test.zig");
}
