//! `lnako sync` — `nako.lock` を読み、package を取得・検証して `.nako/`
//! 環境を構築する。`--json` は `environment.json` と同じバイト列を標準出力
//! へ書く（cnako の委譲呼出しがそのまま検証に使える）。

const std = @import("std");
const lnako = @import("lnako");

const diag = lnako.package.diagnostics;
const cache = lnako.package.cache;
const sync = lnako.package.sync;

fn fail(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var options = sync.Options{};
    var json = false;
    var clean = false;
    var root_set = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--profile")) {
            index += 1;
            if (index >= args.len) fail(stderr, "sync: --profile には profile 名が必要です\n", .{});
            options.profile = args[index];
        } else if (std.mem.eql(u8, argument, "--runtime")) {
            index += 1;
            if (index >= args.len) fail(stderr, "sync: --runtime には lnako|cnako が必要です\n", .{});
            if (std.mem.eql(u8, args[index], "lnako")) {
                options.runtime = .lnako;
            } else if (std.mem.eql(u8, args[index], "cnako")) {
                options.runtime = .cnako;
            } else {
                fail(stderr, "sync: 不明な runtime です: {s}（lnako|cnako）\n", .{args[index]});
            }
        } else if (std.mem.eql(u8, argument, "--offline")) {
            options.policy.offline = true;
        } else if (std.mem.eql(u8, argument, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            index += 1;
            if (index >= args.len) fail(stderr, "sync: --package-cache-dir にはパスが必要です\n", .{});
            options.cache_root = args[index];
        } else if (std.mem.eql(u8, argument, "--package-cache-clean")) {
            clean = true;
        } else if (std.mem.eql(u8, argument, "--allow-plaintext-http")) {
            options.policy.allow_plaintext_http = true;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            fail(stderr, "sync: 不明なオプションです: {s}\n", .{argument});
        } else if (!root_set) {
            options.project_root = argument;
            root_set = true;
        } else {
            fail(stderr, "sync: 不明な引数です: {s}\n", .{argument});
        }
    }

    var list = diag.List.init(allocator);
    defer list.deinit();
    var report = sync.run(allocator, io, options, &list) catch |err| {
        if (list.errorCount() > 0) {
            try list.render(stderr, options.project_root);
            try stderr.flush();
            std.process.exit(1);
        }
        switch (err) {
            error.LockNotFound => fail(stderr, "sync: {s}/nako.lock が見つかりません\n", .{options.project_root}),
            error.UnknownProfile, error.InvalidProfile => fail(stderr, "sync: profile を解決できません\n", .{}),
            error.Busy => fail(stderr, "sync: 別の処理が cache を使用中です\n", .{}),
            else => return err,
        }
    };
    defer report.deinit();

    if (clean) {
        // 今回の sync が参照した entry 以外を整理する。別プロジェクト専用の
        // entry も消える点に注意（内容アドレスなので再取得は可能）。
        const root = options.cache_root orelse (try cache.defaultRoot(allocator)) orelse
            try std.fs.path.join(allocator, &.{ report.environment_root, "cache" });
        var store = try cache.Store.open(allocator, io, root);
        defer store.deinit();
        var guard = try store.lockWait();
        defer guard.unlock();
        const removed = try store.cleanKeep(report.used_keys);
        if (removed > 0) {
            try stderr.print("sync: cache から {d} 個の未使用 entry を削除しました\n", .{removed});
        }
    }

    if (json) {
        try stdout.writeAll(report.environment_json);
        try stdout.flush();
    } else {
        try stderr.print("sync: {d} 個の package を世代 {s} として構築しました（{s}）\n", .{ report.package_count, report.generation, report.environment_root });
        try stderr.flush();
    }
}
