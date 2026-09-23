//! `lnako sync` — プロジェクトを検出して `nako.lock` を最新化した上で、
//! package を取得・検証して `.nako/` 環境を構築する。`--json` は
//! `environment.json` と同じバイト列を標準出力へ書く（cnako の委譲呼出し
//! がそのまま検証に使える）。`--locked` は lock の変更を禁止する。

const std = @import("std");
const lnako = @import("lnako");

const diag = lnako.package.diagnostics;
const cache = lnako.package.cache;
const project = lnako.package.project;
const sync = lnako.package.sync;

const CliError = error{ Failed, Usage };

fn fail(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) CliError {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    if (@import("builtin").is_test) return error.Failed;
    std.process.exit(1);
}

fn failUsage(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) CliError {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    if (@import("builtin").is_test) return error.Usage;
    std.process.exit(2);
}

/// 値を取るフラグの次の引数を値として取り出す。末尾に値が無い場合や、
/// 次の引数が別のオプション（`-` 始まり）なら用法エラーとする。
fn flagValue(args: []const []const u8, index: *usize, flag: []const u8, stderr: *std.Io.Writer) CliError![]const u8 {
    if (index.* + 1 >= args.len or std.mem.startsWith(u8, args[index.* + 1], "-")) {
        return failUsage(stderr, "sync: {s} には値が必要です\n", .{flag});
    }
    index.* += 1;
    return args[index.*];
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var options = sync.Options{};
    var json = false;
    var clean = false;
    var locked = false;
    var features: std.ArrayList([]const u8) = .empty;
    defer features.deinit(allocator);
    var no_default_features = false;
    var registry_url: ?[]const u8 = null;
    var root_set = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--profile")) {
            options.profile = try flagValue(args, &index, "--profile", stderr);
        } else if (std.mem.eql(u8, argument, "--runtime")) {
            const runtime = try flagValue(args, &index, "--runtime", stderr);
            if (std.mem.eql(u8, runtime, "lnako")) {
                options.runtime = .lnako;
            } else if (std.mem.eql(u8, runtime, "cnako")) {
                options.runtime = .cnako;
            } else {
                return failUsage(stderr, "sync: 不明な runtime です: {s}（lnako|cnako）\n", .{runtime});
            }
        } else if (std.mem.eql(u8, argument, "--offline")) {
            options.policy.offline = true;
        } else if (std.mem.eql(u8, argument, "--locked")) {
            locked = true;
        } else if (std.mem.eql(u8, argument, "--features")) {
            const spec = try flagValue(args, &index, "--features", stderr);
            var it = std.mem.splitScalar(u8, spec, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " ");
                if (trimmed.len > 0) try features.append(allocator, trimmed);
            }
        } else if (std.mem.eql(u8, argument, "--no-default-features")) {
            no_default_features = true;
        } else if (std.mem.eql(u8, argument, "--registry")) {
            registry_url = try flagValue(args, &index, "--registry", stderr);
        } else if (std.mem.eql(u8, argument, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            options.cache_root = try flagValue(args, &index, "--package-cache-dir", stderr);
        } else if (std.mem.eql(u8, argument, "--package-cache-clean")) {
            clean = true;
        } else if (std.mem.eql(u8, argument, "--allow-plaintext-http")) {
            options.policy.allow_plaintext_http = true;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return failUsage(stderr, "sync: 不明なオプションです: {s}\n", .{argument});
        } else if (!root_set) {
            options.project_root = argument;
            root_set = true;
        } else {
            return failUsage(stderr, "sync: 不明な引数です: {s}\n", .{argument});
        }
    }

    var list = diag.List.init(allocator);
    defer list.deinit();

    // プロジェクトが見つかれば lock を最新化してから sync する（依存解決
    // から環境構築まで一貫させる）。--locked はここで検証する。
    // manifest 読込〜lock 公開まで編集 lock を保持し、並行する
    // add/remove/lock/update/自動準備と直列化する。
    var edit_guard: ?project.EditLock = null;
    defer if (edit_guard) |*g| g.unlock();
    if (project.findRoot(allocator, io, options.project_root) catch null) |root| {
        defer allocator.free(root);
        edit_guard = project.acquireEditLock(allocator, io, root) catch |err| {
            return fail(stderr, "sync: 編集ロックを取得できません: {s}\n", .{@errorName(err)});
        };
    }
    const discovered = project.discoverAndLoad(allocator, io, options.project_root, &list) catch |err| {
        if (list.errorCount() > 0) try list.render(stderr, options.project_root);
        return fail(stderr, "sync: プロジェクトを読み込めません: {s}\n", .{@errorName(err)});
    };
    if (discovered) |loaded| {
        var found = loaded;
        defer found.deinit();
        options.project_root = found.root;
        var prepare = project.PrepareOptions{
            .profile = options.profile,
            .features = features.items,
            .no_default_features = no_default_features,
            // project コマンドの PrepareOptions と同じ優先順位:
            // --registry が無ければ LNAKO_REGISTRY を参照する。
            .registry_url = registry_url orelse if (environ_map) |map| map.get("LNAKO_REGISTRY") else null,
            .cache_root = options.cache_root,
            .policy = options.policy,
        };
        if (locked) {
            project.verifyLocked(allocator, io, &found, &prepare, &list) catch |err| {
                if (list.errorCount() > 0) try list.render(stderr, found.manifest_path);
                return fail(stderr, "sync: nako.lock が不足・陳腐のため --locked を満たせません: {s}\n", .{@errorName(err)});
            };
        }
        var lock_outcome = project.ensureLock(allocator, io, &found, &prepare, &list) catch |err| {
            if (list.errorCount() > 0) try list.render(stderr, found.manifest_path);
            return fail(stderr, "sync: 依存解決に失敗しました: {s}\n", .{@errorName(err)});
        };
        lock_outcome.deinit();
    }

    var report = sync.run(allocator, io, options, &list) catch |err| {
        if (list.errorCount() > 0) {
            try list.render(stderr, options.project_root);
            try stderr.flush();
            if (@import("builtin").is_test) return error.Failed;
            std.process.exit(1);
        }
        switch (err) {
            error.LockNotFound => return fail(stderr, "sync: {s}/nako.lock が見つかりません\n", .{options.project_root}),
            error.UnknownProfile, error.InvalidProfile => return fail(stderr, "sync: profile を解決できません\n", .{}),
            error.Busy => return fail(stderr, "sync: 別の処理が cache を使用中です\n", .{}),
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

test "値を取るフラグは次のオプションを値として消費せず用法エラーにする" {
    const testing = std.testing;
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);

    // `sync --features --json` が "--json" を feature 名として受理しない
    // ことを含め、全値フラグで次オプションの誤消費と末尾欠落を検査する。
    const flags = [_][]const u8{ "--profile", "--runtime", "--features", "--registry", "--package-cache-dir" };
    for (flags) |flag| {
        err.clearRetainingCapacity();
        try testing.expectError(error.Usage, run(a, testing.io, &.{flag}, null, &out.writer, &err.writer));
        try testing.expect(std.mem.indexOf(u8, err.written(), "には値が必要です") != null);

        err.clearRetainingCapacity();
        try testing.expectError(error.Usage, run(a, testing.io, &.{ flag, "--json" }, null, &out.writer, &err.writer));
        try testing.expect(std.mem.indexOf(u8, err.written(), "には値が必要です") != null);
    }
}
