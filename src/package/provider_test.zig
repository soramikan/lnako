const std = @import("std");
const diag = @import("diagnostics.zig");
const fetch = @import("fetch.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const npkg_build = @import("npkg_build.zig");
const provider = @import("provider.zig");
const registry = @import("registry.zig");
const resolver = @import("resolver.zig");

const testing = std.testing;

// ---------------------------------------------------------------------------
// HTTP fixture server
// ---------------------------------------------------------------------------

const Route = struct {
    path: []const u8,
    status: u16 = 200,
    body: []const u8 = "",
    /// redirect 応答の Location。
    location: ?[]const u8 = null,
    /// 応答までの遅延（timeout 試験用）。
    delay_ms: u64 = 0,
};

/// 単一接続ずつ処理する最小 HTTP サーバ。`Connection: close` で応答するため
/// redirect・連続要求は別接続として順に処理される。
const FixtureServer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    listener: ?std.Io.net.Server = null,
    thread: ?std.Thread = null,
    base_url: ?[]u8 = null,
    routes: []const Route = &.{},
    requests: std.atomic.Value(usize) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),

    fn start(self: *FixtureServer, routes: []const Route) !void {
        const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.listener = try loopback.listen(self.io, .{ .reuse_address = true });
        self.routes = routes;
        self.base_url = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}", .{self.listener.?.socket.address.getPort()});
        // Server をコピーで渡し、stop の deinit→close で accept を解除する。
        // self.listener を直接参照すると deinit 中の null 化と競合する。
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{ self, self.listener.? });
    }

    fn stop(self: *FixtureServer) void {
        if (self.listener) |*listener| {
            self.stopping.store(true, .release);
            // listen socket への shutdown は accept の並行 cancel 機構として
            // Zig が規定する方法。deinit（close）だけでは accept が解除されず、
            // close 後の accept は BADF で panic するため join より先に行う。
            const wake: std.Io.net.Stream = .{ .socket = listener.socket };
            wake.shutdown(self.io, .both) catch {};
            // shutdown が accept を解除しない環境向けに自接続でも起こす。
            if (listener.socket.address.connect(self.io, .{ .mode = .stream })) |stream| {
                stream.close(self.io);
            } else |_| {}
            if (self.thread) |thread| thread.join();
            listener.deinit(self.io);
            self.listener = null;
        }
        if (self.base_url) |base| self.allocator.free(base);
    }

    fn url(self: *const FixtureServer, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url.?, path });
    }

    fn serveLoop(self: *FixtureServer, server: std.Io.net.Server) void {
        var listener = server;
        while (true) {
            var stream = listener.accept(self.io) catch return;
            if (self.stopping.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            self.serve(&stream);
        }
    }

    fn serve(self: *FixtureServer, stream: *std.Io.net.Stream) void {
        defer stream.close(self.io);
        _ = self.requests.fetchAdd(1, .release);
        var read_buffer: [512]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        // `readSliceShort` は buffer を満たすまでブロックするため、CRLFCRLF
        // 検出は 1 byte ずつ行う（`http_tls_test.zig` と同じ手法）。
        var request: [4096]u8 = undefined;
        var total: usize = 0;
        var window: u32 = 0;
        while (true) {
            var byte: [1]u8 = undefined;
            const n = reader.interface.readSliceShort(&byte) catch return;
            if (n == 0) return;
            if (total < request.len) {
                request[total] = byte[0];
                total += 1;
            }
            window = (window << 8) | byte[0];
            if (window == std.mem.readInt(u32, "\r\n\r\n", .big)) break;
        }
        const line_end = std.mem.indexOf(u8, request[0..total], "\r\n") orelse return;
        const line = request[0..line_end];
        const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return;
        const rest = line[first_space + 1 ..];
        const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
        const path = rest[0..second_space];

        for (self.routes) |route| {
            if (!std.mem.eql(u8, route.path, path)) continue;
            if (route.delay_ms > 0) {
                std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(@intCast(route.delay_ms)), .clock = .awake }, self.io) catch return;
            }
            var write_buffer: [1024]u8 = undefined;
            var writer = stream.writer(self.io, &write_buffer);
            if (route.location) |location| {
                writer.interface.print("HTTP/1.1 {d} Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ route.status, location }) catch return;
            } else {
                writer.interface.print("HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ route.status, statusText(route.status), route.body.len }) catch return;
                writer.interface.writeAll(route.body) catch return;
            }
            writer.interface.flush() catch return;
            return;
        }
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        writer.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch return;
        writer.interface.flush() catch return;
    }

    fn statusText(status: u16) []const u8 {
        return switch (status) {
            200 => "OK",
            301 => "Moved Permanently",
            302 => "Found",
            404 => "Not Found",
            else => "Status",
        };
    }
};

fn newSession(policy: fetch.Policy) fetch.Session {
    return fetch.Session.init(testing.allocator, testing.io, policy);
}

// ---------------------------------------------------------------------------
// path provider
// ---------------------------------------------------------------------------

fn writePackage(dir: std.Io.Dir, io: std.Io, root: []const u8) !void {
    const manifest_path = try std.fs.path.join(testing.allocator, &.{ root, "nako.toml" });
    defer testing.allocator.free(manifest_path);
    try dir.writeFile(io, .{
        .sub_path = manifest_path,
        .data =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "demo"
        \\path = "src/index.nako3"
        \\
        ,
    });
}

test "path provider はローカル manifest を取得して source identity を返す" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try writePackage(temporary.dir, io, "pkg");
    const root = try temporary.dir.realPathFileAlloc(io, "pkg", testing.allocator);
    defer testing.allocator.free(root);
    const base = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);

    var session = newSession(.{});
    defer session.deinit();
    const acquired = try provider.acquirePath(&session, .{ .name = "demo", .path = "pkg", .mutable = true }, base);
    try testing.expectEqual(lock_model.SourceKind.path, acquired.source.kind);
    try testing.expectEqualStrings("pkg", acquired.source.path.?);
    try testing.expectEqual(true, acquired.source.mutable.?);
    const parsed = acquired.manifest.?;
    try testing.expectEqualStrings("demo", parsed.package.name);
}

test "path provider は Unicode path を扱える" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "テストパッケージ/src");
    try writePackage(temporary.dir, io, "テストパッケージ");
    const base = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);

    var session = newSession(.{});
    defer session.deinit();
    const acquired = try provider.acquirePath(&session, .{ .name = "demo", .path = "テストパッケージ" }, base);
    try testing.expectEqualStrings("テストパッケージ", acquired.source.path.?);
    try testing.expectEqualStrings("demo", acquired.manifest.?.package.name);
}

test "path provider は manifest 不在を not_found と分類する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "empty");
    const base = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);

    var session = newSession(.{});
    defer session.deinit();
    try testing.expectError(error.NotFound, provider.acquirePath(&session, .{ .name = "demo", .path = "empty" }, base));
    const failure = session.lastFailure().?;
    try testing.expectEqual(fetch.FailureKind.not_found, failure.kind);
    try testing.expectEqual(fetch.ResourceKind.manifest, failure.resource);
}

test "path provider は offline でもローカル manifest を取得できる" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try writePackage(temporary.dir, io, "pkg");
    const base = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);

    var session = newSession(.{ .offline = true });
    defer session.deinit();
    const acquired = try provider.acquirePath(&session, .{ .name = "demo", .path = "pkg" }, base);
    try testing.expect(acquired.manifest != null);
}

// ---------------------------------------------------------------------------
// HTTP fetch
// ---------------------------------------------------------------------------

test "HTTP取得は成功応答の bytes を返す" {
    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{.{ .path = "/artifact.npkg", .body = "payload-bytes" }});
    defer server.stop();

    var session = newSession(.{});
    defer session.deinit();
    const url = try server.url("/artifact.npkg");
    defer testing.allocator.free(url);
    const bytes = try fetch.fetchBytes(&session, url, .artifact);
    try testing.expectEqualStrings("payload-bytes", bytes);
    try testing.expectEqual(@as(usize, 1), server.requests.load(.acquire));
}

test "HTTP取得は 404 を not_found として分類する" {
    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{});
    defer server.stop();

    var session = newSession(.{});
    defer session.deinit();
    const url = try server.url("/missing");
    defer testing.allocator.free(url);
    try testing.expectError(error.NotFound, fetch.fetchBytes(&session, url, .artifact));
    const failure = session.lastFailure().?;
    try testing.expectEqual(fetch.FailureKind.not_found, failure.kind);
}

test "HTTP取得は応答遅延で timeout を分類する" {
    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{.{ .path = "/slow", .body = "late", .delay_ms = 500 }});
    defer server.stop();

    var session = newSession(.{ .timeout_ns = 30 * std.time.ns_per_ms });
    defer session.deinit();
    const url = try server.url("/slow");
    defer testing.allocator.free(url);
    try testing.expectError(error.Timeout, fetch.fetchBytes(&session, url, .artifact));
    const failure = session.lastFailure().?;
    try testing.expectEqual(fetch.FailureKind.timeout, failure.kind);
}

test "HTTP取得は redirect を既定では追跡し 0 回指定では拒否する" {
    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{
        .{ .path = "/old", .status = 302, .location = "/real" },
        .{ .path = "/real", .body = "redirected" },
    });
    defer server.stop();

    var session = newSession(.{});
    defer session.deinit();
    const url = try server.url("/old");
    defer testing.allocator.free(url);
    const bytes = try fetch.fetchBytes(&session, url, .artifact);
    try testing.expectEqualStrings("redirected", bytes);

    var denied = newSession(.{ .max_redirects = 0 });
    defer denied.deinit();
    const url2 = try server.url("/old");
    defer testing.allocator.free(url2);
    try testing.expectError(error.RedirectDenied, fetch.fetchBytes(&denied, url2, .artifact));
    try testing.expectEqual(fetch.FailureKind.redirect_denied, denied.lastFailure().?.kind);
}

test "HTTP取得は取得上限超過を too_large として分類する" {
    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{.{ .path = "/big", .body = "0123456789abcdef" }});
    defer server.stop();

    var session = newSession(.{ .max_bytes = 8 });
    defer session.deinit();
    const url = try server.url("/big");
    defer testing.allocator.free(url);
    try testing.expectError(error.TooLarge, fetch.fetchBytes(&session, url, .artifact));
    try testing.expectEqual(fetch.FailureKind.too_large, session.lastFailure().?.kind);
}

test "offline policy は通信せず不足を分類する" {
    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{.{ .path = "/artifact", .body = "x" }});
    defer server.stop();

    var session = newSession(.{ .offline = true });
    defer session.deinit();
    const url = try server.url("/artifact");
    defer testing.allocator.free(url);
    try testing.expectError(error.Offline, fetch.fetchBytes(&session, url, .artifact));
    // 通信を一切行わない。
    try testing.expectEqual(@as(usize, 0), server.requests.load(.acquire));
    const failure = session.lastFailure().?;
    try testing.expectEqual(fetch.FailureKind.offline, failure.kind);
    try testing.expectEqual(fetch.ResourceKind.artifact, failure.resource);
}

// ---------------------------------------------------------------------------
// HTTP provider
// ---------------------------------------------------------------------------

test "http provider は hash 照合済みの artifact を返す" {
    const body = "raw nako3 source bytes";
    const hash = try fetch.sha256Hex(testing.allocator, body);
    defer testing.allocator.free(hash);
    const declared = try std.fmt.allocPrint(testing.allocator, "sha256:{s}", .{hash});
    defer testing.allocator.free(declared);

    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{.{ .path = "/dep.nako3", .body = body }});
    defer server.stop();

    var session = newSession(.{});
    defer session.deinit();
    const url = try server.url("/dep.nako3");
    defer testing.allocator.free(url);
    const acquired = try provider.acquireHttp(&session, .{ .name = "dep", .url = url, .hash = declared });
    try testing.expectEqualStrings(body, acquired.artifact_bytes.?);
    try testing.expectEqualStrings(hash, acquired.artifact_sha256.?);
    try testing.expectEqual(lock_model.SourceKind.http, acquired.source.kind);
}

test "http provider は .npkg を検証して manifest を取り出す" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try writePackage(temporary.dir, io, "pkg");
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/src/index.nako3", .data = "●表示とは\nここまで\n" });
    const root = try temporary.dir.realPathFileAlloc(io, "pkg", testing.allocator);
    defer testing.allocator.free(root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var built = try npkg_build.build(testing.allocator, io, root, &list, .{});
    defer built.deinit();
    const hash = try fetch.sha256Hex(testing.allocator, built.archive);
    defer testing.allocator.free(hash);
    const declared = try std.fmt.allocPrint(testing.allocator, "sha256:{s}", .{hash});
    defer testing.allocator.free(declared);

    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{.{ .path = "/demo.npkg", .body = built.archive }});
    defer server.stop();

    var session = newSession(.{});
    defer session.deinit();
    const url = try server.url("/demo.npkg");
    defer testing.allocator.free(url);
    const acquired = try provider.acquireHttp(&session, .{ .name = "demo", .url = url, .hash = declared });
    try testing.expectEqualStrings(".npkg", acquired.artifact_type.?);
    try testing.expectEqualStrings("demo", acquired.manifest.?.package.name);
}

test "http provider は破損内容を hash_mismatch で拒否する" {
    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{.{ .path = "/corrupt", .body = "tampered" }});
    defer server.stop();

    var session = newSession(.{});
    defer session.deinit();
    const url = try server.url("/corrupt");
    defer testing.allocator.free(url);
    const wrong = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    try testing.expectError(error.HashMismatch, provider.acquireHttp(&session, .{ .name = "dep", .url = url, .hash = wrong }));
    try testing.expectEqual(fetch.FailureKind.hash_mismatch, session.lastFailure().?.kind);
}

// ---------------------------------------------------------------------------
// Git provider
// ---------------------------------------------------------------------------

/// git hook（pre-push 等）配下で実行されると GIT_DIR 等の `GIT_*` 環境変数が
/// 子プロセスへ漏れて一時 repo ではなく呼出し側の repo を操作するため、
/// 除去した環境を git へ渡す。
fn gitRunInner(io: std.Io, argv: []const []const u8) !std.process.RunResult {
    var env_map = try fetch.sanitizedGitEnvMap(testing.allocator);
    defer if (env_map) |*m| m.deinit();
    return std.process.run(testing.allocator, io, .{
        .argv = argv,
        .environ_map = if (env_map) |*m| m else null,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
}

fn gitAvailable(io: std.Io) bool {
    const result = gitRunInner(io, &.{ "git", "--version" }) catch return false;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn gitRun(io: std.Io, argv: []const []const u8) !void {
    const result = gitRunInner(io, argv) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.GitFailed;
}

fn gitStdout(io: std.Io, argv: []const []const u8) ![]u8 {
    const result = gitRunInner(io, argv) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer testing.allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.GitFailed;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    const owned = try testing.allocator.dupe(u8, trimmed);
    testing.allocator.free(result.stdout);
    return owned;
}

/// ローカル git repo を作り、HEAD の完全 SHA を返す。
/// `path` は `realPathFileAlloc` 由来の sentinel 付き領域を保持する。
/// commit は `commit.gpgsign=false` で実行し、呼出し側の git 設定
/// （グローバルな署名強制等）に結果を依存させない。
fn createGitRepo(temporary: *std.testing.TmpDir, io: std.Io) !struct { path: [:0]u8, url: []u8, commit: []u8 } {
    try temporary.dir.createDirPath(io, "repo/src");
    try writePackage(temporary.dir, io, "repo");
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/src/index.nako3", .data = "●表示とは\nここまで\n" });
    const repo = try temporary.dir.realPathFileAlloc(io, "repo", testing.allocator);
    errdefer testing.allocator.free(repo);

    try gitRun(io, &.{ "git", "init", "--quiet", repo });
    try gitRun(io, &.{ "git", "-C", repo, "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "-A" });
    try gitRun(io, &.{ "git", "-C", repo, "-c", "user.email=test@example.com", "-c", "user.name=test", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "init" });
    const commit = try gitStdout(io, &.{ "git", "-C", repo, "rev-parse", "HEAD" });
    errdefer testing.allocator.free(commit);
    const url = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{repo});
    return .{ .path = repo, .url = url, .commit = commit };
}

test "git provider はローカル repo を clone して commit に固定する" {
    const io = testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const repo = try createGitRepo(&temporary, io);
    defer testing.allocator.free(repo.path);
    defer testing.allocator.free(repo.url);
    defer testing.allocator.free(repo.commit);

    const tmp_root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_root);
    const checkout = try std.fs.path.join(testing.allocator, &.{ tmp_root, "checkout" });
    defer testing.allocator.free(checkout);

    var session = newSession(.{});
    defer session.deinit();
    const short = repo.commit[0..7];
    const acquired = try provider.acquireGit(&session, .{ .name = "demo", .url = repo.url, .commit = short }, checkout, null);
    try testing.expectEqual(lock_model.SourceKind.git, acquired.source.kind);
    try testing.expectEqualStrings(repo.commit, acquired.source.commit.?);
    try testing.expectEqualStrings("demo", acquired.manifest.?.package.name);
}

test "git provider は commit-ish と同名の移動した tag に誤解されない" {
    const io = testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const repo = try createGitRepo(&temporary, io);
    defer testing.allocator.free(repo.path);
    defer testing.allocator.free(repo.url);
    defer testing.allocator.free(repo.commit);

    // 2 つ目の commit を作り、commit 接頭辞と同名の tag をそちらへ向ける。
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/second.txt", .data = "second" });
    try gitRun(io, &.{ "git", "-C", repo.path, "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "-A" });
    try gitRun(io, &.{ "git", "-C", repo.path, "-c", "user.email=test@example.com", "-c", "user.name=test", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "second" });
    const second = try gitStdout(io, &.{ "git", "-C", repo.path, "rev-parse", "HEAD" });
    defer testing.allocator.free(second);
    const short = repo.commit[0..7];
    // `rev-parse <short>` は同名 tag を先に解決するが、取得 provider は
    // --disambiguate で commit object を選ぶため tag 移動の影響を受けない。
    try gitRun(io, &.{ "git", "-C", repo.path, "tag", "-f", short, second });

    const tmp_root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_root);
    const checkout = try std.fs.path.join(testing.allocator, &.{ tmp_root, "checkout" });
    defer testing.allocator.free(checkout);

    var session = newSession(.{});
    defer session.deinit();
    const acquired = try provider.acquireGit(&session, .{ .name = "demo", .url = repo.url, .commit = short }, checkout, null);
    try testing.expectEqualStrings(repo.commit, acquired.source.commit.?);
}

test "git provider は既存 lock の commit を tag 移動後も使う" {
    const io = testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const repo = try createGitRepo(&temporary, io);
    defer testing.allocator.free(repo.path);
    defer testing.allocator.free(repo.url);
    defer testing.allocator.free(repo.commit);

    // tag を別 commit へ動かしても lock の commit を使う。
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/second.txt", .data = "second" });
    try gitRun(io, &.{ "git", "-C", repo.path, "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "-A" });
    try gitRun(io, &.{ "git", "-C", repo.path, "-c", "user.email=test@example.com", "-c", "user.name=test", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "second" });
    const second = try gitStdout(io, &.{ "git", "-C", repo.path, "rev-parse", "HEAD" });
    defer testing.allocator.free(second);
    const short = repo.commit[0..7];
    try gitRun(io, &.{ "git", "-C", repo.path, "tag", "-f", short, second });

    const locked = lock_model.Source{ .kind = .git, .url = repo.url, .commit = repo.commit };
    const tmp_root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_root);
    const checkout = try std.fs.path.join(testing.allocator, &.{ tmp_root, "checkout" });
    defer testing.allocator.free(checkout);

    var session = newSession(.{});
    defer session.deinit();
    const acquired = try provider.acquireGit(&session, .{ .name = "demo", .url = repo.url, .commit = short }, checkout, locked);
    try testing.expectEqualStrings(repo.commit, acquired.source.commit.?);
}

test "git provider は lock と矛盾する source 変更を拒否する" {
    const io = testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const repo = try createGitRepo(&temporary, io);
    defer testing.allocator.free(repo.path);
    defer testing.allocator.free(repo.url);
    defer testing.allocator.free(repo.commit);

    const locked = lock_model.Source{ .kind = .http, .url = "https://example.com/x", .hash = "sha256:00" };
    const tmp_root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_root);
    const checkout = try std.fs.path.join(testing.allocator, &.{ tmp_root, "checkout" });
    defer testing.allocator.free(checkout);

    var session = newSession(.{});
    defer session.deinit();
    try testing.expectError(error.SourceCollision, provider.acquireGit(&session, .{ .name = "demo", .url = repo.url, .commit = repo.commit[0..7] }, checkout, locked));
    try testing.expectEqual(fetch.FailureKind.source_collision, session.lastFailure().?.kind);
}

// ---------------------------------------------------------------------------
// source identity
// ---------------------------------------------------------------------------

test "checkLockedSource は暗黙の source 切替を拒否し static→registry を許す" {
    var session = newSession(.{});
    defer session.deinit();

    const git_declared = lock_model.Source{ .kind = .git, .url = "https://example.com/r", .commit = "abc1234" };
    const http_locked = lock_model.Source{ .kind = .http, .url = "https://example.com/x", .hash = "sha256:00" };
    try testing.expectError(error.SourceCollision, provider.checkLockedSource(&session, git_declared, http_locked, "demo"));

    const static_declared = lock_model.Source{ .kind = .static, .url = "https://static.example.com/pkg/demo" };
    const registry_locked = lock_model.Source{ .kind = .registry, .url = "https://static.example.com/pkg/demo" };
    try provider.checkLockedSource(&session, static_declared, registry_locked, "demo");

    const git_other = lock_model.Source{ .kind = .git, .url = "https://example.com/r", .commit = "ffffffffffffffffffffffffffffffffffffffff" };
    try testing.expectError(error.SourceCollision, provider.checkLockedSource(&session, git_declared, git_other, "demo"));
}

test "SourceIndex は同一 name の identity 衝突を検出する" {
    var session = newSession(.{});
    defer session.deinit();
    var index = provider.SourceIndex{};
    defer index.deinit(testing.allocator);

    const path_a = lock_model.Source{ .kind = .path, .path = "a" };
    const path_b = lock_model.Source{ .kind = .path, .path = "b" };
    try index.add(&session, "demo", path_a);
    // 同一 name に別 identity は衝突。
    try testing.expectError(error.SourceCollision, index.add(&session, "demo", path_b));
    // 同一 identity の再登録・別 name からの同一参照は許容。
    try index.add(&session, "demo", path_a);
    try index.add(&session, "alias", path_a);
}

// ---------------------------------------------------------------------------
// static registry provider
// ---------------------------------------------------------------------------

const registry_index =
    \\{"schemaVersion":1,"packages":[
    \\  {"schemaVersion":1,"id":"pkg:11111111111111111111111111111111","name":"libalpha","owner":"soramikan","humanId":"@soramikan/libalpha","versions":[]},
    \\  {"schemaVersion":1,"id":"pkg:22222222222222222222222222222222","name":"libbeta","owner":"soramikan","versions":[
    \\    {"schemaVersion":1,"version":"1.2.3","manifestHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","dependencies":[],"features":["default"],"artifacts":{"source":{"kind":"source","type":".npkg","sha256":"%SHA%","url":"%BASE%/artifacts/libbeta-1.2.3.npkg"}}},
    \\    {"schemaVersion":1,"version":"1.0.0","manifestHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","dependencies":[],"features":["default"],"artifacts":{"source":{"kind":"source","type":".npkg","sha256":"%SHA%","url":"%BASE%/artifacts/libbeta-1.0.0.npkg"}}}
    \\  ]}
    \\]}
;

const libalpha_package_doc =
    \\{"schemaVersion":1,"id":"pkg:11111111111111111111111111111111","name":"libalpha","owner":"soramikan","humanId":"@soramikan/libalpha","versions":[
    \\  {"schemaVersion":1,"version":"2.0.0","manifestHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","dependencies":["pkg:22222222222222222222222222222222"],"features":["default"],"artifacts":{"source":{"kind":"source","type":".npkg","sha256":"%SHA%","url":"%BASE%/artifacts/libalpha-2.0.0.npkg"}}}
    \\]}
;

fn buildNpkg(io: std.Io) !struct { dir: std.testing.TmpDir, archive: []u8, sha: []u8 } {
    var temporary = std.testing.tmpDir(.{});
    errdefer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try writePackage(temporary.dir, io, "pkg");
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/src/index.nako3", .data = "●表示とは\nここまで\n" });
    const root = try temporary.dir.realPathFileAlloc(io, "pkg", testing.allocator);
    defer testing.allocator.free(root);
    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var built = try npkg_build.build(testing.allocator, io, root, &list, .{});
    const archive = try testing.allocator.dupe(u8, built.archive);
    built.deinit();
    const sha = try fetch.sha256Hex(testing.allocator, archive);
    return .{ .dir = temporary, .archive = archive, .sha = sha };
}

fn renderDoc(allocator: std.mem.Allocator, template: []const u8, base: []const u8, sha: []const u8) ![]u8 {
    const with_base = try std.mem.replaceOwned(u8, allocator, template, "%BASE%", base);
    defer allocator.free(with_base);
    const sha_text = try std.fmt.allocPrint(allocator, "sha256:{s}", .{sha});
    defer allocator.free(sha_text);
    return std.mem.replaceOwned(u8, allocator, with_base, "%SHA%", sha_text);
}

test "静的registry provider は解決・metadata・artifact を提供する" {
    const io = testing.io;
    var npkg = try buildNpkg(io);
    defer npkg.dir.cleanup();
    defer testing.allocator.free(npkg.archive);
    defer testing.allocator.free(npkg.sha);

    var server = FixtureServer{ .io = io, .allocator = testing.allocator };
    try server.start(&.{});
    defer server.stop();

    const index_doc = try renderDoc(testing.allocator, registry_index, server.base_url.?, npkg.sha);
    defer testing.allocator.free(index_doc);
    const alpha_doc = try renderDoc(testing.allocator, libalpha_package_doc, server.base_url.?, npkg.sha);
    defer testing.allocator.free(alpha_doc);

    server.routes = &.{
        .{ .path = "/index.json", .body = index_doc },
        .{ .path = "/soramikan/libalpha.json", .body = alpha_doc },
        .{ .path = "/artifacts/libbeta-1.2.3.npkg", .body = npkg.archive },
    };

    var session = newSession(.{});
    defer session.deinit();
    var reg = try registry.StaticRegistry.init(&session, server.base_url.?, .{ .runtime = "lnako" });
    defer reg.deinit();

    // resolver.Provider として解決する。libalpha → pkg:2222...(libbeta) の
    // 依存 edge 経由で libbeta が解決される。
    const dep = resolver.Dependency{
        .id = .{ .pkg = "libalpha" },
        .constraint = .any,
    };
    var result = try resolver.resolve(testing.allocator, reg.provider(), &.{dep}, .{});
    defer result.deinit();
    const nodes = switch (result.result) {
        .resolved => |resolved| resolved,
        else => return error.TestUnexpectedResult,
    };
    var found_alpha = false;
    var found_beta = false;
    for (nodes) |node| {
        if (node.id != .pkg) continue;
        var text: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&text);
        try node.version.format(&w);
        if (std.mem.eql(u8, node.id.pkg, "libalpha")) {
            found_alpha = true;
            try testing.expectEqualStrings("2.0.0", w.buffered());
        }
        // libbeta は public id 宣言の依存 edge 経由なので node.id は
        // パッケージ名ではなく `pkg:<hex>` が保持される。
        if (std.mem.eql(u8, node.id.pkg, "pkg:22222222222222222222222222222222")) {
            found_beta = true;
            try testing.expectEqualStrings("1.2.3", w.buffered());
        }
    }
    try testing.expect(found_alpha and found_beta);

    // DetailsSource として lock 用 metadata を返す。
    const details = (try reg.detailsSource().get(testing.allocator, "libbeta", "1.2.3")).?;
    try testing.expectEqualStrings("pkg:22222222222222222222222222222222", details.public_id.?);
    try testing.expectEqual(lock_model.SourceKind.static, details.source.?.kind);
    try testing.expectEqual(@as(usize, 1), details.artifacts.len);

    // artifact bytes は宣言 hash と照合される。
    const artifact = try reg.acquireArtifact("libbeta", "1.2.3", "source");
    try testing.expectEqualStrings(npkg.sha, artifact.sha256);
    try testing.expectEqualStrings(npkg.archive, artifact.bytes);

    // index 内包 versions を持つ package は package doc を取得しない。
    // libalpha は index 未収録 versions のため package doc を 1 件取得する。
    try testing.expect(reg.package_docs.count() == 1);
}

test "静的registry provider は index 未収録の package を not_found と分類する" {
    const io = testing.io;
    var server = FixtureServer{ .io = io, .allocator = testing.allocator };
    const index_doc = "{\"schemaVersion\":1,\"packages\":[]}";
    try server.start(&.{.{ .path = "/index.json", .body = index_doc }});
    defer server.stop();

    var session = newSession(.{});
    defer session.deinit();
    var reg = try registry.StaticRegistry.init(&session, server.base_url.?, .{});
    defer reg.deinit();
    try testing.expectError(error.PackageNotFound, reg.provider().listVersions(testing.allocator, .{ .pkg = "missing" }));
}

test "静的registry provider の artifact は破損を hash_mismatch で拒否する" {
    const io = testing.io;
    var server = FixtureServer{ .io = io, .allocator = testing.allocator };
    try server.start(&.{});
    defer server.stop();

    const index_doc = try std.fmt.allocPrint(testing.allocator,
        \\{{"schemaVersion":1,"packages":[
        \\  {{"schemaVersion":1,"id":"pkg:33333333333333333333333333333333","name":"libcorrupt","owner":"o","versions":[
        \\    {{"schemaVersion":1,"version":"1.0.0","manifestHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","artifacts":{{"source":{{"kind":"source","type":"raw","sha256":"sha256:0000000000000000000000000000000000000000000000000000000000000000","url":"{s}/a"}}}}}}
        \\  ]}}
        \\]}}
    , .{server.base_url.?});
    defer testing.allocator.free(index_doc);
    server.routes = &.{
        .{ .path = "/index.json", .body = index_doc },
        .{ .path = "/a", .body = "tampered-bytes" },
    };

    var session = newSession(.{});
    defer session.deinit();
    var reg = try registry.StaticRegistry.init(&session, server.base_url.?, .{});
    defer reg.deinit();
    try testing.expectError(error.HashMismatch, reg.acquireArtifact("libcorrupt", "1.0.0", "source"));
    try testing.expectEqual(fetch.FailureKind.hash_mismatch, session.lastFailure().?.kind);
}

test "静的registry は offline で不足 metadata を特定し通信しない" {
    const io = testing.io;
    var server = FixtureServer{ .io = io, .allocator = testing.allocator };
    try server.start(&.{});
    defer server.stop();

    var session = newSession(.{ .offline = true });
    defer session.deinit();
    var reg = try registry.StaticRegistry.init(&session, server.base_url.?, .{});
    defer reg.deinit();
    try testing.expectError(error.Offline, reg.provider().listVersions(testing.allocator, .{ .pkg = "libbeta" }));
    try testing.expectEqual(@as(usize, 0), server.requests.load(.acquire));
    const failure = session.lastFailure().?;
    try testing.expectEqual(fetch.FailureKind.offline, failure.kind);
    try testing.expectEqual(fetch.ResourceKind.index, failure.resource);
}

test "registry index の重複 Public ID を拒否する" {
    var session = newSession(.{});
    defer session.deinit();
    const dup =
        \\{"schemaVersion":1,"packages":[
        \\  {"schemaVersion":1,"id":"pkg:00000000000000000000000000000000","name":"a","owner":"x","versions":[]},
        \\  {"schemaVersion":1,"id":"pkg:00000000000000000000000000000000","name":"b","owner":"y","versions":[]}
        \\]}
    ;
    try testing.expectError(error.InvalidMetadata, registry.parseIndex(&session, dup, "test://index"));
    const failure = session.lastFailure().?;
    try testing.expectEqual(fetch.FailureKind.invalid_metadata, failure.kind);
    try testing.expectEqualStrings(diag.E012_ALIAS_COLLISION, failure.diagnosticCode());
}

/// cwd から上方向に conformance fixture を持つリポジトリルートを探す。
/// （`lock_test.zig` の `openRepoRoot` と同じ手法）
fn openRepoRoot(io: std.Io) !std.Io.Dir {
    const probe = "tools/package-system/conformance/valid/registry/index/index.json";
    var buffer: [256]u8 = undefined;
    var prefix: []const u8 = ".";
    for (0..8) |_| {
        var candidate = try std.Io.Dir.cwd().openDir(io, prefix, .{});
        if (candidate.openFile(io, probe, .{})) |file| {
            file.close(io);
            return candidate;
        } else |_| {
            candidate.close(io);
        }
        prefix = std.fmt.bufPrint(&buffer, "{s}/..", .{prefix}) catch return error.FileNotFound;
    }
    return error.FileNotFound;
}

test "registry適合fixtureをZig側でも検証する" {
    const io = testing.io;
    var repo = try openRepoRoot(io);
    defer repo.close(io);
    const cases = [_]struct { path: []const u8, expected: ?[]const u8, contains: []const u8 }{
        .{ .path = "tools/package-system/conformance/valid/registry/index/index.json", .expected = null, .contains = "" },
        .{ .path = "tools/package-system/conformance/invalid/registry/duplicate-id/index.json", .expected = diag.E012_ALIAS_COLLISION, .contains = "pkg:00000000000000000000000000000000" },
    };
    for (cases) |case| {
        const bytes = try repo.readFileAlloc(io, case.path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);
        var session = newSession(.{});
        defer session.deinit();
        if (registry.parseIndex(&session, bytes, case.path)) |_| {
            if (case.expected != null) {
                std.debug.print("{s}: expected {s} but parsed successfully\n", .{ case.path, case.expected.? });
                return error.TestUnexpectedResult;
            }
        } else |_| {
            const code = case.expected orelse {
                std.debug.print("{s}: unexpected parse error\n", .{case.path});
                return error.TestUnexpectedResult;
            };
            var found = false;
            for (session.failures.items) |failure| {
                if (std.mem.eql(u8, failure.diagnosticCode(), code) and
                    std.mem.indexOf(u8, failure.message, case.contains) != null) found = true;
            }
            if (!found) {
                std.debug.print("{s}: expected {s} with \"{s}\", diagnostics:", .{ case.path, code, case.contains });
                for (session.failures.items) |failure| std.debug.print(" {s}", .{failure.diagnosticCode()});
                std.debug.print("\n", .{});
                return error.TestUnexpectedResult;
            }
        }
    }
}
