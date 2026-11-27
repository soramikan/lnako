//! `lnako package build|pack|verify|cache|publish` — `.npkg` の生成・
//! 展開前検証と、v1 で対象外になった旧公開経路の案内。
//!
//! build（pack は別名）は `nako.toml` を持つ v1 プロジェクトから、`--kind`
//! で選んだ単一アーティファクトの Canonical ZIP を決定的に生成する。
//! verify は `.npkg` を §3.2〜§3.5 に従って検証し、複数指定時は §3.3・
//! §3.5・§5.3 のクロスアーティファクト検査（P04）をローカルで行う。
//! publish は v1 では旧 static PUT を使わないため、対象外と代替手順を示す。
//! いずれもパッケージの初期化コードは実行しない。

const std = @import("std");
const lnako = @import("lnako");

const cache = lnako.package.cache;
const v1_archive = lnako.package.v1_archive;
const v1_zip = lnako.package.v1_zip;
const v1_manifest = lnako.package.v1_manifest;
const v1_types = lnako.package.v1_types;
const v1_cross = lnako.package.v1_cross;
const package_v1_cli = @import("package_v1_cli.zig");

/// `nako.toml` の読み取り上限。`v1_manifest` の検証上限と揃える。
const max_manifest_bytes: usize = 16 * 1024 * 1024;
/// 明示入力する COMMANDS.json の読み取り上限。COMMANDS 固有の上限は
/// 設けず、pack が最終的に適用する ZIP の既定展開合計上限で有界にする。
const max_commands_bytes: usize = @intCast(v1_zip.default_max_uncompressed_bytes);
/// `.npkg` の読み取り上限。v1 の圧縮後上限 25 MiB を超えた入力を
/// 展開前に確実に拒否できるよう、少し余裕を持たせる。
const max_npkg_bytes: usize = 32 * 1024 * 1024;

fn toKind(kind: package_v1_cli.ArtifactKind) v1_types.Kind {
    return switch (kind) {
        .universal => .universal,
        .esm => .esm,
        .native_source => .@"native-source",
        .native_prebuilt => .@"native-prebuilt",
    };
}

fn kindLabel(kind: v1_types.Kind) []const u8 {
    return v1_types.kindName(kind);
}

/// `--kind` と manifest から、出力ファイル名に使う runtimes を決める。
/// `--runtime` の明示が無い ESM は `[artifacts.esm].runtimes` を使う。
fn effectiveRuntimeNames(
    allocator: std.mem.Allocator,
    parsed: *const package_v1_cli.BuildArgs,
    manifest: *const v1_manifest.Manifest,
) ![]const []const u8 {
    switch (parsed.kind) {
        .universal => return &.{ "lnako", "cnako", "wnako" },
        .native_source, .native_prebuilt => return &.{"lnako"},
        .esm => {
            if (parsed.runtimes.len != 0) return parsed.runtimes;
            const esm = manifest.artifacts.esm orelse return &.{};
            const names = try allocator.alloc([]const u8, esm.runtimes.len);
            for (esm.runtimes, 0..) |runtime, index| names[index] = v1_types.runtimeName(runtime);
            return names;
        },
    }
}

fn parseEsmsRuntimes(
    allocator: std.mem.Allocator,
    parsed: *const package_v1_cli.BuildArgs,
) !?[]const v1_types.Runtime {
    if (parsed.kind != .esm or parsed.runtimes.len == 0) return null;
    const runtimes = try allocator.alloc(v1_types.Runtime, parsed.runtimes.len);
    for (parsed.runtimes, 0..) |name, index| {
        runtimes[index] = v1_types.parseRuntime(name) orelse return error.InvalidRuntime;
    }
    return runtimes;
}

/// native 系の ABI は v1 では `[artifacts.native].abi_version` が正本。
/// CLI から上書きせず、manifest の値だけを出力名に使う（Z-14）。
fn manifestNativeAbi(manifest: *const v1_manifest.Manifest) ?u32 {
    const native = manifest.artifacts.native orelse return null;
    return native.abi_version;
}

fn printBuildUsage(stdout: *std.Io.Writer) !void {
    try stdout.writeAll(
        \\使い方: lnako package build [ROOT] [オプション]
        \\  -o, --output PATH        出力先（既定は §3.1 の推奨名）
        \\      --kind KIND          universal|esm|native-source|native-prebuilt（既定 universal）
        \\      --runtime NAME      cnako,wnako など。ESM の対象を固定する（複数回可）
        \\      --target-triple T   native-prebuilt の {arch}-{os}-{abi}
        \\      --glibc-min V       GNU Linux の native-prebuilt で必須（MAJOR.MINOR）
        \\      --library-path P    native-prebuilt のライブラリ相対パス（省略時は prebuilt_lib_name から導出）
        \\      --commands PATH     明示入力する v1 COMMANDS.json（JS/native 等）
        \\
    );
}

fn runBuild(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var parsed = package_v1_cli.parseBuildArgs(allocator, args, stderr) catch |err| switch (err) {
        error.Usage => {
            try stderr.flush();
            std.process.exit(2);
        },
        else => return err,
    };
    if (parsed.help) {
        try printBuildUsage(stdout);
        return;
    }

    const manifest_path = try std.fs.path.join(allocator, &.{ parsed.root, "nako.toml" });
    const source = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(max_manifest_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print("package build: {s}/nako.toml が見つかりません\n", .{parsed.root});
            try stderr.flush();
            std.process.exit(1);
        },
        else => return err,
    };

    var manifest = v1_manifest.parse(allocator, source, .pack) catch |err| {
        if (err == error.LegacyManifest) {
            try stderr.writeAll(package_v1_cli.legacy_manifest_message);
        } else {
            const detail = v1_manifest.diagnostic(err) orelse @errorName(err);
            try stderr.print("package build: nako.toml が v1 形式として不正です: {s}\n", .{detail});
            try stderr.print("  v1 の必須欄は先頭の schema_version = 1 と [package] の id/version/license です\n", .{});
        }
        try stderr.flush();
        std.process.exit(1);
    };
    defer manifest.deinit();

    var commands_source: ?[]const u8 = null;
    if (parsed.commands_path) |commands_path| {
        commands_source = std.Io.Dir.cwd().readFileAlloc(io, commands_path, allocator, .limited(max_commands_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr.print("package build: COMMANDS.json が見つかりません: {s}\n", .{commands_path});
                try stderr.flush();
                std.process.exit(1);
            },
            error.StreamTooLong => {
                try stderr.print("package build: {s} は上限 {d} バイトを超えています\n", .{ commands_path, max_commands_bytes });
                try stderr.flush();
                std.process.exit(1);
            },
            else => return err,
        };
    }

    const esm_runtimes = try parseEsmsRuntimes(allocator, &parsed);
    const bytes = v1_archive.packManifest(allocator, io, parsed.root, &manifest, .{
        .kind = toKind(parsed.kind),
        .native = .{
            .target_triple = parsed.target_triple,
            .glibc_min = parsed.glibc_min,
            .library_path = parsed.library_path,
        },
        .esm_runtimes = esm_runtimes,
        .commands_json = commands_source,
    }) catch |err| {
        const name = @errorName(err);
        var hint: []const u8 = "nako.toml の [artifacts.*]/[exports] と --kind の指定を確認してください";
        if (std.mem.eql(u8, name, "InvalidInclude")) {
            hint = "この kind の [artifacts.*].include が空、または対象ファイルがありません";
        } else if (std.mem.eql(u8, name, "MissingExportEntry")) {
            hint = "exports の entry が収録対象（include）に含まれていません";
        } else if (std.mem.eql(u8, name, "MissingLibraryName")) {
            hint = "native-prebuilt には nako.toml の [artifacts.native].prebuilt_lib_name か --library-path が必要です";
        } else if (std.mem.eql(u8, name, "MissingLibrary")) {
            hint = "prebuilt_lib_name から導出したライブラリ（native/<name>）が見つかりません。--library-path で指定してください";
        } else if (std.mem.eql(u8, name, "AmbiguousLibrary")) {
            hint = "prebuilt_lib_name から収録パスを決められません。--library-path で package root 相対のライブラリを指定してください";
        } else if (std.mem.eql(u8, name, "AmbiguousBuildInput")) {
            hint = "native-source の build.zig が [artifacts.native].source_include 内に複数あります。build.zig が一意になるよう収録対象を絞ってください";
        } else if (std.mem.eql(u8, name, "InvalidTargetTriple")) {
            hint = "--target-triple は {arch}-{os}-{abi} の既知の組合せで指定してください";
        } else if (std.mem.eql(u8, name, "MissingEntry")) {
            hint = "収録対象のファイルが package root にありません";
        } else if (std.mem.eql(u8, name, "InvalidLibraryPath")) {
            hint = "--library-path は package root 相対の正規パスで指定してください";
        } else if (std.mem.eql(u8, name, "InvalidCommands")) {
            hint = "--commands の COMMANDS.json が v1 の構造として不正です";
        } else if (std.mem.eql(u8, name, "ExportMismatch")) {
            hint = "--commands の exports キー集合が METADATA.toml の [exports] と一致しません";
        } else if (std.mem.eql(u8, name, "BindingMismatch") or
            std.mem.eql(u8, name, "GlobalCommandsMismatch"))
        {
            hint = "--commands の binding と exports_global_commands を METADATA.toml の [exports] に合わせてください";
        } else if (std.mem.eql(u8, name, "MissingField")) {
            hint = "nako.toml の [artifacts.*] に必要な欄（include/entry/abi_version）がありません";
        }
        try stderr.print("package build: .npkg を生成できません（{s}）: {s}\n", .{ name, hint });
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(bytes);

    const id = manifest.package.id orelse {
        try stderr.writeAll("package build: nako.toml の [package].id がありません\n");
        try stderr.flush();
        std.process.exit(1);
    };
    const version = manifest.package.version orelse {
        try stderr.writeAll("package build: nako.toml の [package].version がありません\n");
        try stderr.flush();
        std.process.exit(1);
    };
    const output_path = parsed.output orelse try package_v1_cli.defaultOutputName(
        allocator,
        id,
        version,
        parsed.kind,
        try effectiveRuntimeNames(allocator, &parsed, &manifest),
        parsed.target_triple,
        manifestNativeAbi(&manifest),
    );

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = bytes }) catch |err| {
        try stderr.print("package build: {s} へ書き込めません: {s}\n", .{ output_path, @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try stdout.print("{s}: {s} {s} の {s} アーティファクトを生成しました（{d} バイト、sha256:{s}）\n", .{
        output_path,
        id,
        version,
        kindLabel(toKind(parsed.kind)),
        bytes.len,
        std.fmt.bytesToHex(digest, .lower),
    });
}

/// 旧 `.npkg` は Canonical ZIP 以前の検査で落ちることがある（旧生成器は
/// DOS 日時を 0 にしていた）。制御ファイル名が実バイト列に現れる場合だけ、
/// 構造エラーより先に「v1 で再作成が必要」という移行診断を出す。
pub fn containsLegacyControlHint(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes, "NAKO-PKG/FILES.toml") != null or
        std.mem.indexOf(u8, bytes, "NAKO-PKG/commands.json") != null;
}

fn printVerifyUsage(stdout: *std.Io.Writer) !void {
    try stdout.writeAll(
        \\使い方: lnako package verify <FILE.npkg>...
        \\  v1 の verify は §3.2〜§3.5 の構造検証だけを行う。
        \\  二つ以上指定すると §3.3・§3.5・§5.3 のクロス検証も行う。
        \\
    );
}

fn crossCodeLabel(code: v1_cross.Code) []const u8 {
    return switch (code) {
        .empty_artifact_set => "アーティファクトがありません",
        .invalid_metadata => "METADATA.toml の構造が不正です",
        .invalid_commands => "COMMANDS.json の構造が不正です",
        .common_field_mismatch => "リリース共通項目が一致しません",
        .global_commands_mismatch => "global 命令の集合が一致しません",
        .duplicate_artifact => "同じ kind/runtimes/triple/ABI のアーティファクトが重複しています",
    };
}

fn runVerify(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = package_v1_cli.parseVerifyArgs(allocator, args, stderr) catch |err| switch (err) {
        error.Usage => {
            try stderr.flush();
            std.process.exit(2);
        },
        else => return err,
    };
    if (parsed.help) {
        try printVerifyUsage(stdout);
        return;
    }

    var verified: std.ArrayList(v1_archive.Verified) = .empty;
    defer {
        for (verified.items) |*item| item.deinit();
        verified.deinit(allocator);
    }

    for (parsed.files) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_npkg_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr.print("package verify: {s} が見つかりません\n", .{path});
                try stderr.flush();
                std.process.exit(1);
            },
            error.StreamTooLong => {
                try stderr.print("package verify: {s} は上限 {d} バイトを超えています\n", .{ path, max_npkg_bytes });
                try stderr.flush();
                std.process.exit(1);
            },
            else => return err,
        };
        var item = v1_archive.verify(allocator, bytes) catch |err| {
            if (err == error.LegacyArchive or containsLegacyControlHint(bytes)) {
                try stderr.writeAll(package_v1_cli.legacy_archive_message);
            } else {
                try stderr.print("package verify: {s}: 不正な .npkg です（{s}）\n", .{ path, @errorName(err) });
                try stderr.writeAll("  §3.2 の Canonical ZIP と §3.3〜§3.5 の制御ファイルを確認してください\n");
            }
            try stderr.flush();
            std.process.exit(1);
        };
        try verified.append(allocator, item);
        try stdout.print("{s}: {s} {s}（{s}、{d} ファイル）— 検証 OK\n", .{
            path,
            item.packageId(),
            item.packageVersion(),
            kindLabel(item.artifactKind()),
            item.entryCount(),
        });
    }

    if (verified.items.len >= 2) {
        var report = v1_cross.check(allocator, verified.items) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try stderr.print("package verify: クロス検証を実行できません（{s}）\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            },
        };
        defer report.deinit();
        if (!report.ok()) {
            try stderr.print("package verify: クロス検証に失敗しました（{d} 件）\n", .{report.diagnostics.len});
            for (report.diagnostics) |diagnostic| {
                if (diagnostic.artifact) |artifact| {
                    try stderr.print("  [{s}] artifacts[{d}] {s}\n", .{
                        crossCodeLabel(diagnostic.code),
                        artifact,
                        diagnostic.field,
                    });
                } else {
                    try stderr.print("  [{s}] {s}\n", .{ crossCodeLabel(diagnostic.code), diagnostic.field });
                }
            }
            try stderr.flush();
            std.process.exit(1);
        }
        try stdout.print("クロス検証 OK（{d} アーティファクト、global 命令 {d} 件）\n", .{
            verified.items.len,
            report.global_commands.len,
        });
    }
}

/// `lnako package cache dir|clean` — 共有 cache の場所表示と初期化。
/// clean は cache lock を取得してから objects・checkouts・staging を全て
/// 削除する。使用中の sync は lock で直列化されるため途中の entry を
/// 観測・削除しない。
fn runCache(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len == 0) {
        try stderr.writeAll("package cache: 操作を指定してください（dir|clean）\n");
        std.process.exit(2);
    }
    const action = args[0];
    var cache_dir: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            index += 1;
            if (index >= args.len) {
                try stderr.writeAll("package cache: --package-cache-dir にはパスが必要です\n");
                std.process.exit(2);
            }
            cache_dir = args[index];
        } else {
            try stderr.print("package cache: 不明な引数です: {s}\n", .{argument});
            std.process.exit(2);
        }
    }

    const root = cache_dir orelse (try cache.defaultRoot(allocator)) orelse {
        try stderr.writeAll("package cache: 環境変数から cache dir を決定できません。--package-cache-dir を指定してください\n");
        std.process.exit(1);
    };

    if (std.mem.eql(u8, action, "dir")) {
        try stdout.print("{s}\n", .{root});
        return;
    }
    if (!std.mem.eql(u8, action, "clean")) {
        try stderr.print("package cache: 不明な操作です: {s}（dir|clean）\n", .{action});
        std.process.exit(2);
    }

    var store = try cache.Store.open(allocator, io, root);
    defer store.deinit();
    var guard = store.lockWait() catch |err| switch (err) {
        error.Busy => {
            try stderr.writeAll("package cache clean: 別の処理が cache を使用中です\n");
            std.process.exit(1);
        },
        else => return err,
    };
    defer guard.unlock();
    const removed = try store.cleanAll();
    try stdout.print("package cache clean: {d} 個の項目を削除しました（{s}）\n", .{ removed, root });
}

/// `lnako package publish` — v1 仕様では旧 static registry への PUT を
/// 公開経路に使わない（`docs/specification.md` §5、O02）。公開は P07 の
/// `POST /v1/packages/{scope}/{name}/releases`（OIDC 認証）で行うため、
/// この CLI は旧経路へ接続せず、対象外であることと代替手順だけを示す。
fn runPublish(
    _: std.mem.Allocator,
    _: std.Io,
    _: []const []const u8,
    _: ?*const std.process.Environ.Map,
    _: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    try stderr.writeAll(package_v1_cli.publish_out_of_scope_message);
    try stderr.flush();
    std.process.exit(2);
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    if (args.len == 0) {
        try stderr.writeAll("package: 操作を指定してください（build|pack|verify|cache|publish）\n");
        std.process.exit(2);
    }
    if (std.mem.eql(u8, args[0], "build") or std.mem.eql(u8, args[0], "pack")) {
        return runBuild(allocator, io, args[1..], stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "verify")) {
        return runVerify(allocator, io, args[1..], stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "cache")) {
        return runCache(allocator, io, args[1..], stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "publish")) {
        return runPublish(allocator, io, args[1..], environ_map, stdout, stderr);
    }
    try stderr.print("package: 不明な操作です: {s}（build|pack|verify|cache|publish）\n", .{args[0]});
    std.process.exit(2);
}

test {
    _ = @import("package_test.zig");
    _ = @import("package_v1_cli.zig");
}
