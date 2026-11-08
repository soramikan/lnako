//! `lnako package build|verify|cache|publish` — `.npkg` の生成・インストール
//! 前検証と、公開前検証（dry-run）・static registry への公開。
//!
//! build は `nako.toml` を持つ package directory から決定的な `.npkg` を
//! 出力し、verify は `.npkg` の構造・索引・対象環境適合を静的に検査する。
//! publish は manifest/lock/.npkg/registry 設定を検証したうえで、明示された
//! registry にだけ `.npkg` と version record を PUT する（既定は dry-run）。
//! いずれもパッケージの初期化コードは実行しない。

const std = @import("std");
const lnako = @import("lnako");

const diag = lnako.package.diagnostics;
const npkg_build = lnako.package.npkg_build;
const npkg_verify = lnako.package.npkg_verify;
const publish_mod = lnako.package.publish;
const semver = lnako.package.semver;
const cache = lnako.package.cache;

fn renderAndFail(list: *const diag.List, stderr: *std.Io.Writer, source_name: []const u8) !noreturn {
    try list.render(stderr, source_name);
    try stderr.flush();
    std.process.exit(1);
}

fn runBuild(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var root: []const u8 = ".";
    var root_set = false;
    var output: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "-o") or std.mem.eql(u8, argument, "--output")) {
            index += 1;
            if (index >= args.len) {
                try stderr.writeAll("package build: -o/--output には出力パスが必要です\n");
                std.process.exit(2);
            }
            output = args[index];
        } else if (std.mem.startsWith(u8, argument, "-")) {
            try stderr.print("package build: 不明なオプションです: {s}\n", .{argument});
            std.process.exit(2);
        } else if (!root_set) {
            root = argument;
            root_set = true;
        } else {
            try stderr.print("package build: 不明な引数です: {s}\n", .{argument});
            std.process.exit(2);
        }
    }

    var list = diag.List.init(allocator);
    defer list.deinit();
    var built = npkg_build.build(allocator, io, root, &list, .{ .output = output }) catch |err| switch (err) {
        error.InvalidPackage => try renderAndFail(&list, stderr, root),
        error.FileNotFound => {
            try stderr.print("package build: {s}/nako.toml が見つかりません\n", .{root});
            try stderr.flush();
            std.process.exit(1);
        },
        else => return err,
    };
    defer built.deinit();

    const output_path = output orelse try npkg_build.defaultOutputName(allocator, &built.manifest);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = built.archive });
    try stdout.print("{s}: {d} ファイルを収録しました\n", .{ output_path, built.files.len });
}

fn runVerify(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var archive_path: ?[]const u8 = null;
    var target = npkg_verify.Target{};
    var features: std.ArrayList([]const u8) = .empty;
    var nako_version_text: ?[]const u8 = null;
    var cnako_version_text: ?[]const u8 = null;
    var lnako_version_text: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        const value_options = [_][]const u8{ "--runtime", "--os", "--cpu", "--abi", "--os-version", "--libc", "--optimize", "--feature", "--nako-version", "--cnako-version", "--lnako-version" };
        var matched = false;
        inline for (value_options) |option| {
            if (std.mem.eql(u8, argument, option)) {
                index += 1;
                if (index >= args.len) {
                    try stderr.print("package verify: {s} には値が必要です\n", .{option});
                    std.process.exit(2);
                }
                const value = args[index];
                if (comptime std.mem.eql(u8, option, "--runtime")) {
                    target.runtime = value;
                } else if (comptime std.mem.eql(u8, option, "--os")) {
                    target.os = value;
                } else if (comptime std.mem.eql(u8, option, "--cpu")) {
                    target.cpu = value;
                } else if (comptime std.mem.eql(u8, option, "--abi")) {
                    target.abi = value;
                } else if (comptime std.mem.eql(u8, option, "--os-version")) {
                    target.os_version = value;
                } else if (comptime std.mem.eql(u8, option, "--libc")) {
                    target.libc = value;
                } else if (comptime std.mem.eql(u8, option, "--optimize")) {
                    target.optimize = value;
                } else if (comptime std.mem.eql(u8, option, "--feature")) {
                    try features.append(allocator, value);
                } else if (comptime std.mem.eql(u8, option, "--nako-version")) {
                    nako_version_text = value;
                } else if (comptime std.mem.eql(u8, option, "--cnako-version")) {
                    cnako_version_text = value;
                } else if (comptime std.mem.eql(u8, option, "--lnako-version")) {
                    lnako_version_text = value;
                }
                matched = true;
            }
        }
        if (matched) continue;
        if (std.mem.eql(u8, argument, "--compat-js")) {
            target.compat_js = true;
        } else if (std.mem.eql(u8, argument, "--no-default-features")) {
            target.default_features = false;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            try stderr.print("package verify: 不明なオプションです: {s}\n", .{argument});
            std.process.exit(2);
        } else if (archive_path == null) {
            archive_path = argument;
        } else {
            try stderr.print("package verify: 不明な引数です: {s}\n", .{argument});
            std.process.exit(2);
        }
    }
    const path = archive_path orelse {
        try stderr.writeAll("package verify: .npkg ファイルを指定してください\n");
        std.process.exit(2);
    };
    // 言語版（--nako-version）と処理系版（--cnako-version/--lnako-version）は
    // 独立に指定する。同じ値を両制約へ流用すると、lnako のリリース番号と
    // 対応する言語版が異なるパッケージを誤って拒否する。
    if (nako_version_text) |text| {
        target.nako_version = semver.Version.parse(text) catch {
            try stderr.print("package verify: --nako-version が不正です: {s}\n", .{text});
            std.process.exit(2);
        };
    }
    if (cnako_version_text) |text| {
        target.cnako_version = semver.Version.parse(text) catch {
            try stderr.print("package verify: --cnako-version が不正です: {s}\n", .{text});
            std.process.exit(2);
        };
    }
    if (lnako_version_text) |text| {
        target.lnako_version = semver.Version.parse(text) catch {
            try stderr.print("package verify: --lnako-version が不正です: {s}\n", .{text});
            std.process.exit(2);
        };
    }
    target.features = features.items;

    var list = diag.List.init(allocator);
    defer list.deinit();
    var verified = npkg_verify.verifyFile(allocator, io, path, target, &list) catch |err| switch (err) {
        error.InvalidPackage => try renderAndFail(&list, stderr, path),
        error.FileNotFound => {
            try stderr.print("package verify: {s} が見つかりません\n", .{path});
            try stderr.flush();
            std.process.exit(1);
        },
        else => return err,
    };
    defer verified.deinit();

    const package = verified.manifest.package;
    try stdout.print("{s}: {s} ", .{ path, package.name });
    try package.version.format(stdout);
    try stdout.print("（{d} ファイル、{d} 命令）— 検証 OK\n", .{ verified.files.len, verified.commands.len });
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

/// `lnako package publish` — 既定は dry-run。`--no-dry-run` のときだけ
/// registry へ PUT する。registry/owner/token はフラグを優先し、無ければ
/// `LNAKO_REGISTRY` / `LNAKO_REGISTRY_OWNER` / `LNAKO_REGISTRY_TOKEN` を読む。
fn runPublish(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var root: []const u8 = ".";
    var root_set = false;
    var dry_run = true;
    var registry: ?[]const u8 = null;
    var owner: ?[]const u8 = null;
    var allow_plaintext_http = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, argument, "--no-dry-run")) {
            dry_run = false;
        } else if (std.mem.eql(u8, argument, "--allow-plaintext-http")) {
            allow_plaintext_http = true;
        } else if (std.mem.eql(u8, argument, "--registry")) {
            index += 1;
            if (index >= args.len or std.mem.startsWith(u8, args[index], "-")) {
                try stderr.writeAll("package publish: --registry には URL が必要です\n");
                std.process.exit(2);
            }
            registry = args[index];
        } else if (std.mem.eql(u8, argument, "--owner")) {
            index += 1;
            if (index >= args.len or std.mem.startsWith(u8, args[index], "-")) {
                try stderr.writeAll("package publish: --owner には値が必要です\n");
                std.process.exit(2);
            }
            owner = args[index];
        } else if (std.mem.startsWith(u8, argument, "-")) {
            try stderr.print("package publish: 不明なオプションです: {s}\n", .{argument});
            std.process.exit(2);
        } else if (!root_set) {
            root = argument;
            root_set = true;
        } else {
            try stderr.print("package publish: 不明な引数です: {s}\n", .{argument});
            std.process.exit(2);
        }
    }

    const registry_url = registry orelse envValue(environ_map, "LNAKO_REGISTRY");
    const owner_value = owner orelse envValue(environ_map, "LNAKO_REGISTRY_OWNER");
    const token = envValue(environ_map, "LNAKO_REGISTRY_TOKEN");

    var list = diag.List.init(allocator);
    defer list.deinit();
    var report = publish_mod.run(allocator, io, .{
        .root = root,
        .dry_run = dry_run,
        .registry_url = registry_url,
        .owner = owner_value,
        .token = token,
        .allow_plaintext_http = allow_plaintext_http,
    }, &list) catch |err| {
        switch (err) {
            error.RegistryRequired => try stderr.writeAll("package publish: 公開先 registry が未設定です（--registry または LNAKO_REGISTRY）\n"),
            error.AuthRequired => try stderr.writeAll("package publish: 認証情報がありません（環境変数 LNAKO_REGISTRY_TOKEN）\n"),
            error.InvalidAuth => try stderr.writeAll("package publish: 認証情報に空白・制御文字・非 ASCII が含まれています（LNAKO_REGISTRY_TOKEN）\n"),
            error.OwnerRequired => try stderr.writeAll("package publish: 公開先 owner を特定できません（--owner または LNAKO_REGISTRY_OWNER。index 未収録の初回公開では必須）\n"),
            error.InvalidRegistry => try stderr.writeAll("package publish: registry URL または owner の形式が不正です\n"),
            error.ProjectNotFound => try stderr.print("package publish: {s}/nako.toml が見つかりません\n", .{root}),
            error.LockMissing => try stderr.writeAll("package publish: nako.lock がありません。lnako lock を実行してください\n"),
            error.LockMismatch => try stderr.writeAll("package publish: nako.lock が現在の nako.toml と一致しません。lnako lock で更新してください\n"),
            error.InvalidManifest, error.InvalidLock, error.InvalidPackage, error.RegistryUnavailable, error.FileSystem => {
                if (list.errorCount() > 0) {
                    try list.render(stderr, root);
                } else {
                    try stderr.print("package publish: {s}\n", .{@errorName(err)});
                }
            },
            error.VersionConflict => try stderr.writeAll("package publish: 同一版が異なる内容（artifact hash）で公開済みです。上書きは拒否しました\n"),
            error.VersionYanked => try stderr.writeAll("package publish: 同一版は yanked 済みです。再公開には registry 側の手続きが必要です\n"),
            error.OutOfMemory, error.Canceled => return err,
        }
        try stderr.flush();
        std.process.exit(1);
    };
    defer report.deinit();
    try publish_mod.renderSummary(&report, stdout);
    try stdout.flush();
    if (report.status == .failed) {
        try stderr.flush();
        std.process.exit(1);
    }
}

fn envValue(environ_map: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const map = environ_map orelse return null;
    return map.get(name);
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
        try stderr.writeAll("package: 操作を指定してください（build|verify|cache|publish）\n");
        std.process.exit(2);
    }
    if (std.mem.eql(u8, args[0], "build")) {
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
    try stderr.print("package: 不明な操作です: {s}（build|verify|cache|publish）\n", .{args[0]});
    std.process.exit(2);
}

test {
    _ = @import("package_test.zig");
}
