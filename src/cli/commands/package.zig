//! `lnako package build|verify` — `.npkg` の生成とインストール前検証。
//!
//! build は `nako.toml` を持つ package directory から決定的な `.npkg` を
//! 出力し、verify は `.npkg` の構造・索引・対象環境適合を静的に検査する。
//! いずれもパッケージの初期化コードは実行しない。

const std = @import("std");
const lnako = @import("lnako");

const diag = lnako.package.diagnostics;
const npkg_build = lnako.package.npkg_build;
const npkg_verify = lnako.package.npkg_verify;
const semver = lnako.package.semver;

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

    const output_path = output orelse try std.fmt.allocPrint(allocator, "{s}-{}.{}.{}.npkg", .{
        built.manifest.package.name,
        built.manifest.package.version.major,
        built.manifest.package.version.minor,
        built.manifest.package.version.patch,
    });
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
        const value_options = [_][]const u8{ "--runtime", "--os", "--cpu", "--abi", "--os-version", "--libc", "--feature", "--nako-version", "--cnako-version", "--lnako-version" };
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

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len == 0) {
        try stderr.writeAll("package: 操作を指定してください（build|verify）\n");
        std.process.exit(2);
    }
    if (std.mem.eql(u8, args[0], "build")) {
        return runBuild(allocator, io, args[1..], stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "verify")) {
        return runVerify(allocator, io, args[1..], stdout, stderr);
    }
    try stderr.print("package: 不明な操作です: {s}（build|verify）\n", .{args[0]});
    std.process.exit(2);
}
