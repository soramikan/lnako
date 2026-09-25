const std = @import("std");
const builtin = @import("builtin");
const diag = @import("diagnostics.zig");
const fetch = @import("fetch.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const npkg_build = @import("npkg_build.zig");
const provider = @import("provider.zig");
const registry = @import("registry.zig");
const resolver = @import("resolver.zig");
const sync_mod = @import("sync.zig");

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

test "path provider の絶対判定はhost pathと完全なUNCを区別する" {
    if (builtin.os.tag == .windows) {
        try testing.expect(provider.isAbsoluteDepPath("\\lib"));
        try testing.expect(!provider.isAbsoluteDepPath("\\\\lib"));
    } else {
        try testing.expect(!provider.isAbsoluteDepPath("\\lib"));
        try testing.expect(!provider.isAbsoluteDepPath("\\\\lib"));
    }
    try testing.expect(provider.isAbsoluteDepPath("C:\\"));
    try testing.expect(provider.isAbsoluteDepPath("\\\\server\\share\\lib"));
}

test "path provider はPOSIX上の先頭backslashを相対pathとして取得する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "base/\\lib/src");
    try writePackage(temporary.dir, io, "base/\\lib");
    const base = try temporary.dir.realPathFileAlloc(io, "base", testing.allocator);
    defer testing.allocator.free(base);

    var session = newSession(.{});
    defer session.deinit();
    const acquired = try provider.acquirePath(&session, .{ .name = "demo", .path = "\\lib" }, base);
    try testing.expectEqualStrings("demo", acquired.manifest.?.package.name);
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

test "path provider は max_bytes=0 を上限なしとし上限超過を too_large と分類する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try writePackage(temporary.dir, io, "pkg");
    const base = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);

    // 0 は「上限なし」（HTTP 取得と同じ契約）。
    var unlimited = newSession(.{ .max_bytes = 0 });
    defer unlimited.deinit();
    const acquired = try provider.acquirePath(&unlimited, .{ .name = "demo", .path = "pkg" }, base);
    try testing.expect(acquired.manifest != null);

    // 非空 manifest が上限を超える場合は too_large。
    var limited = newSession(.{ .max_bytes = 8 });
    defer limited.deinit();
    try testing.expectError(error.TooLarge, provider.acquirePath(&limited, .{ .name = "demo", .path = "pkg" }, base));
    try testing.expectEqual(fetch.FailureKind.too_large, limited.lastFailure().?.kind);
}

test "provider は返却 source の文字列を session arena へ複製する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try writePackage(temporary.dir, io, "pkg");
    const base = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);

    var session = newSession(.{});
    defer session.deinit();
    // 宣言側の文字列は session より短命な allocator で確保する。
    const dep_path = try testing.allocator.dupe(u8, "pkg");
    defer testing.allocator.free(dep_path);
    const acquired = try provider.acquirePath(&session, .{ .name = "demo", .path = dep_path, .mutable = true }, base);
    // 返却 source は dep のメモリを共有せず session arena が所有する。
    try testing.expect(acquired.source.path.?.ptr != dep_path.ptr);
    try testing.expectEqualStrings("pkg", acquired.source.path.?);
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

test "http provider は sha512 宣言も照合する" {
    const body = "sha512 payload bytes";
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(body, &digest, .{});
    const declared = try std.fmt.allocPrint(testing.allocator, "sha512:{x}", .{digest});
    defer testing.allocator.free(declared);

    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{.{ .path = "/dep512", .body = body }});
    defer server.stop();

    var session = newSession(.{});
    defer session.deinit();
    const url = try server.url("/dep512");
    defer testing.allocator.free(url);
    const acquired = try provider.acquireHttp(&session, .{ .name = "dep", .url = url, .hash = declared });
    try testing.expectEqualStrings(body, acquired.artifact_bytes.?);

    var mismatch = newSession(.{});
    defer mismatch.deinit();
    const wrong = "sha512:00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    try testing.expectError(error.HashMismatch, provider.acquireHttp(&mismatch, .{ .name = "dep", .url = url, .hash = wrong }));
    try testing.expectEqual(fetch.FailureKind.hash_mismatch, mismatch.lastFailure().?.kind);
}

test "HTTP取得は redirect 先の非 loopback 平文 http を拒否する" {
    // 初回 URL が loopback http で許可されても、redirect 先が非 loopback の
    // 平文 http なら接続前に invalid_source で拒否する（降格回避の遮断）。
    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{
        .{ .path = "/go", .status = 302, .location = "http://example.com/evil" },
    });
    defer server.stop();

    var session = newSession(.{});
    defer session.deinit();
    const url = try server.url("/go");
    defer testing.allocator.free(url);
    try testing.expectError(error.InvalidSource, fetch.fetchBytes(&session, url, .artifact));
    try testing.expectEqual(fetch.FailureKind.invalid_source, session.lastFailure().?.kind);
}

test "取得 provider は非 loopback の平文 http を拒否する" {
    // 既定 policy では loopback 以外の http:// を invalid_source で拒否する
    // （接続前に失敗するためネットワーク不要）。
    var session = newSession(.{});
    defer session.deinit();
    try testing.expectError(error.InvalidSource, provider.acquireHttp(&session, .{ .name = "dep", .url = "http://example.com/dep.tar.gz", .hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000" }));
    try testing.expectEqual(fetch.FailureKind.invalid_source, session.lastFailure().?.kind);

    // ドメイン名は数字始まりでも IP literal でなければ loopback 扱いしない。
    var deceptive = newSession(.{});
    defer deceptive.deinit();
    try testing.expectError(error.InvalidSource, provider.acquireHttp(&deceptive, .{ .name = "dep", .url = "http://127.evil.example/x", .hash = "sha256:00" }));
    try testing.expectEqual(fetch.FailureKind.invalid_source, deceptive.lastFailure().?.kind);
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
    // Windows CI の git は core.autocrlf で checkout 時に LF→CRLF 変換する。
    // cache object が作業木の byte 列をそのまま保持する契約を検証するため、
    // fixture repo では text 変換を無効化する。
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/.gitattributes", .data = "* -text\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/src/index.nako3", .data = "●表示とは\nここまで\n" });
    const repo = try temporary.dir.realPathFileAlloc(io, "repo", testing.allocator);
    errdefer testing.allocator.free(repo);

    try gitRun(io, &.{ "git", "init", "--quiet", repo });
    try gitRun(io, &.{ "git", "-C", repo, "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "-A" });
    try gitRun(io, &.{ "git", "-C", repo, "-c", "user.email=test@example.com", "-c", "user.name=test", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "init" });
    const commit = try gitStdout(io, &.{ "git", "-C", repo, "rev-parse", "HEAD" });
    errdefer testing.allocator.free(commit);
    // 正規の file:/// URL 形にする。Windows の `D:\a` をそのまま連結すると
    // バックスラッシュを含み、lock JSON へ埋め込むと不正エスケープになる。
    const url = if (builtin.os.tag == .windows) blk: {
        const fwd = try testing.allocator.dupe(u8, repo);
        defer testing.allocator.free(fwd);
        for (fwd) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        break :blk try std.fmt.allocPrint(testing.allocator, "file:///{s}", .{fwd});
    } else try std.fmt.allocPrint(testing.allocator, "file://{s}", .{repo});
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

test "git provider は dirty cached checkout を pinned commit へ戻してから読む" {
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
    const dep = manifest_mod.GitDependency{ .name = "demo", .url = repo.url, .commit = repo.commit[0..7] };

    var session = newSession(.{});
    defer session.deinit();
    const first = try provider.acquireGit(&session, dep, checkout, null);
    try temporary.dir.writeFile(io, .{ .sub_path = "checkout/nako.toml", .data = "[package]\nname = \"attacker\"\nversion = \"9.9.9\"\nlicense = \"MIT\"\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "checkout/src/index.nako3", .data = "attacker source" });
    try temporary.dir.writeFile(io, .{ .sub_path = "checkout/untracked.nako3", .data = "attacker file" });
    try gitRun(io, &.{ "git", "-C", checkout, "init", "--quiet", "nested-untracked" });

    session.policy.offline = true;
    const recovered = try provider.acquireGit(&session, dep, checkout, first.source);
    try testing.expectEqualStrings(repo.commit, recovered.source.commit.?);
    try testing.expectEqualStrings("demo", recovered.manifest.?.package.name);
    const source = try temporary.dir.readFileAlloc(io, "checkout/src/index.nako3", testing.allocator, .limited(128));
    defer testing.allocator.free(source);
    try testing.expectEqualStrings("●表示とは\nここまで\n", source);
    try testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "checkout/untracked.nako3", .{}));
    try testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "checkout/nested-untracked/.git", .{}));
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

test "git provider は既存 checkout に無い commit を fetch して解決する" {
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

    // 先に clone しておく。
    var session = newSession(.{});
    defer session.deinit();
    _ = try provider.acquireGit(&session, .{ .name = "demo", .url = repo.url, .commit = repo.commit[0..7] }, checkout, null);

    // clone 後にリモートへ commit を追加する。
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/second.txt", .data = "second" });
    try gitRun(io, &.{ "git", "-C", repo.path, "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "-A" });
    try gitRun(io, &.{ "git", "-C", repo.path, "-c", "user.email=test@example.com", "-c", "user.name=test", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "second" });
    const second = try gitStdout(io, &.{ "git", "-C", repo.path, "rev-parse", "HEAD" });
    defer testing.allocator.free(second);

    // 既存 checkout のローカル object に無い commit-ish でも fetch 経由で
    // 解決できる。
    const acquired = try provider.acquireGit(&session, .{ .name = "demo", .url = repo.url, .commit = second[0..7] }, checkout, null);
    try testing.expectEqualStrings(second, acquired.source.commit.?);
}

test "git provider は checkout 境界の外を指す path を拒否する" {
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
    try testing.expectError(error.InvalidSource, provider.acquireGit(&session, .{ .name = "demo", .url = repo.url, .commit = repo.commit[0..7], .path = "../escape" }, checkout, null));
    try testing.expectEqual(fetch.FailureKind.invalid_source, session.lastFailure().?.kind);
}

test "git provider は別 repository の既存 checkout を拒否する" {
    const io = testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var temporary_b = std.testing.tmpDir(.{});
    defer temporary_b.cleanup();
    const repo_a = try createGitRepo(&temporary, io);
    defer testing.allocator.free(repo_a.path);
    defer testing.allocator.free(repo_a.url);
    defer testing.allocator.free(repo_a.commit);
    const repo_b = try createGitRepo(&temporary_b, io);
    defer testing.allocator.free(repo_b.path);
    defer testing.allocator.free(repo_b.url);
    defer testing.allocator.free(repo_b.commit);

    const tmp_root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_root);
    const checkout = try std.fs.path.join(testing.allocator, &.{ tmp_root, "checkout" });
    defer testing.allocator.free(checkout);

    var session = newSession(.{});
    defer session.deinit();
    // repo A の checkout を作った後、同じ checkout_dir を repo B の URL で
    // 再利用すると origin 不一致として拒否する。
    _ = try provider.acquireGit(&session, .{ .name = "demo", .url = repo_a.url, .commit = repo_a.commit[0..7] }, checkout, null);
    try testing.expectError(error.SourceCollision, provider.acquireGit(&session, .{ .name = "demo", .url = repo_b.url, .commit = repo_b.commit[0..7] }, checkout, null));
    try testing.expectEqual(fetch.FailureKind.source_collision, session.lastFailure().?.kind);
}

test "git provider は bare path origin と file:// URL を同一視する" {
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

    // bare path で clone すると origin は bare path のまま記録される。
    // `file://` 表記の宣言 URL と同一 repo として扱えることを確認する。
    try gitRun(io, &.{ "git", "clone", "--quiet", "--no-checkout", repo.path, checkout });
    var session = newSession(.{});
    defer session.deinit();
    const acquired = try provider.acquireGit(&session, .{ .name = "demo", .url = repo.url, .commit = repo.commit[0..7] }, checkout, null);
    try testing.expectEqualStrings(repo.commit, acquired.source.commit.?);
}

test "git provider は末尾 .git だけが異なる別 repo を拒否する" {
    const io = testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // 末尾が .git のローカル repo（`/deps/a` と `/deps/a.git` は別物）。
    try temporary.dir.createDirPath(io, "lib.git/src");
    try writePackage(temporary.dir, io, "lib.git");
    try temporary.dir.writeFile(io, .{ .sub_path = "lib.git/src/index.nako3", .data = "●表示とは\nここまで\n" });
    const repo_path = try temporary.dir.realPathFileAlloc(io, "lib.git", testing.allocator);
    defer testing.allocator.free(repo_path);
    try gitRun(io, &.{ "git", "init", "--quiet", repo_path });
    try gitRun(io, &.{ "git", "-C", repo_path, "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "-A" });
    try gitRun(io, &.{ "git", "-C", repo_path, "-c", "user.email=test@example.com", "-c", "user.name=test", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "init" });
    const commit = try gitStdout(io, &.{ "git", "-C", repo_path, "rev-parse", "HEAD" });
    defer testing.allocator.free(commit);

    const tmp_root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_root);
    const checkout = try std.fs.path.join(testing.allocator, &.{ tmp_root, "checkout" });
    defer testing.allocator.free(checkout);
    // bare path で clone → origin は bare path <tmp>/lib.git のまま。
    try gitRun(io, &.{ "git", "clone", "--quiet", "--no-checkout", repo_path, checkout });

    // 宣言 URL は <tmp>/lib（.git 無し）。ローカル path の .git はファイル
    // 名の一部であり除去しないため、別 repo の宣言として拒否する。
    const declared = try std.fmt.allocPrint(testing.allocator, "{s}/lib", .{tmp_root});
    defer testing.allocator.free(declared);
    var session = newSession(.{});
    defer session.deinit();
    try testing.expectError(error.SourceCollision, provider.acquireGit(&session, .{ .name = "demo", .url = declared, .commit = commit[0..7] }, checkout, null));
    try testing.expectEqual(fetch.FailureKind.source_collision, session.lastFailure().?.kind);
}

test "git provider は percent-encoded な file:// URL と bare path を同一視する" {
    const io = testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // 空白を含むローカル repo。origin の bare path は空白を保持し、
    // file: URL の宣言は %20 で表現される。
    try temporary.dir.createDirPath(io, "my repo/src");
    try writePackage(temporary.dir, io, "my repo");
    try temporary.dir.writeFile(io, .{ .sub_path = "my repo/src/index.nako3", .data = "●表示とは\nここまで\n" });
    const repo_path = try temporary.dir.realPathFileAlloc(io, "my repo", testing.allocator);
    defer testing.allocator.free(repo_path);
    try gitRun(io, &.{ "git", "init", "--quiet", repo_path });
    try gitRun(io, &.{ "git", "-C", repo_path, "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "-A" });
    try gitRun(io, &.{ "git", "-C", repo_path, "-c", "user.email=test@example.com", "-c", "user.name=test", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "init" });
    const commit = try gitStdout(io, &.{ "git", "-C", repo_path, "rev-parse", "HEAD" });
    defer testing.allocator.free(commit);

    const tmp_root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_root);
    const checkout = try std.fs.path.join(testing.allocator, &.{ tmp_root, "checkout" });
    defer testing.allocator.free(checkout);
    try gitRun(io, &.{ "git", "clone", "--quiet", "--no-checkout", repo_path, checkout });

    const declared = try std.fmt.allocPrint(testing.allocator, "file://{s}/my%20repo", .{tmp_root});
    defer testing.allocator.free(declared);
    var session = newSession(.{});
    defer session.deinit();
    const acquired = try provider.acquireGit(&session, .{ .name = "demo", .url = declared, .commit = commit[0..7] }, checkout, null);
    try testing.expectEqualStrings(commit, acquired.source.commit.?);
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

test "registry は末尾以外に = を含む base64 hash を拒否する" {
    var session = newSession(.{});
    defer session.deinit();
    const bad_hash = "sha256-============================================";
    const doc = try std.fmt.allocPrint(testing.allocator,
        \\{{"schemaVersion":1,"packages":[
        \\  {{"schemaVersion":1,"id":"pkg:55555555555555555555555555555555","name":"x","owner":"o","versions":[
        \\    {{"schemaVersion":1,"version":"1.0.0","manifestHash":"{s}"}}
        \\  ]}}
        \\]}}
    , .{bad_hash});
    defer testing.allocator.free(doc);
    try testing.expectError(error.InvalidMetadata, registry.parseIndex(&session, doc, "test://index"));
    try testing.expectEqual(fetch.FailureKind.invalid_metadata, session.lastFailure().?.kind);
}

test "registry artifact url は http/https 以外の scheme を拒否する" {
    var session = newSession(.{});
    defer session.deinit();
    const doc =
        \\{"schemaVersion":1,"packages":[
        \\  {"schemaVersion":1,"id":"pkg:66666666666666666666666666666666","name":"x","owner":"o","versions":[
        \\    {"schemaVersion":1,"version":"1.0.0","manifestHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","artifacts":{"source":{"kind":"source","type":"raw","sha256":"sha256:0000000000000000000000000000000000000000000000000000000000000000","url":"file:///etc/passwd"}}}
        \\  ]}
        \\]}
    ;
    try testing.expectError(error.InvalidMetadata, registry.parseIndex(&session, doc, "test://index"));
    try testing.expectEqual(fetch.FailureKind.invalid_metadata, session.lastFailure().?.kind);
}

test "registry は任意 string フィールドの明示的 null を拒否する" {
    var session = newSession(.{});
    defer session.deinit();
    const doc =
        \\{"schemaVersion":1,"packages":[
        \\  {"schemaVersion":1,"id":"pkg:00000000000000000000000000000000","name":"x","owner":"o","humanId":null,"versions":[]}
        \\]}
    ;
    try testing.expectError(error.InvalidMetadata, registry.parseIndex(&session, doc, "test://index"));
    try testing.expectEqualStrings(diag.E023_INVALID_TYPE, session.lastFailure().?.diagnosticCode());
}

test "registry は任意 metadata フィールドの型と URI を検証する" {
    var session = newSession(.{});
    defer session.deinit();
    const bad_type =
        \\{"schemaVersion":1,"packages":[
        \\  {"schemaVersion":1,"id":"pkg:00000000000000000000000000000000","name":"x","owner":"o","description":42,"versions":[]}
        \\]}
    ;
    try testing.expectError(error.InvalidMetadata, registry.parseIndex(&session, bad_type, "test://index"));
    try testing.expectEqualStrings(diag.E023_INVALID_TYPE, session.lastFailure().?.diagnosticCode());

    var session_uri = newSession(.{});
    defer session_uri.deinit();
    const bad_uri =
        \\{"schemaVersion":1,"packages":[
        \\  {"schemaVersion":1,"id":"pkg:00000000000000000000000000000000","name":"x","owner":"o","repository":"not a uri","versions":[]}
        \\]}
    ;
    try testing.expectError(error.InvalidMetadata, registry.parseIndex(&session_uri, bad_uri, "test://index"));
    try testing.expectEqual(fetch.FailureKind.invalid_metadata, session_uri.lastFailure().?.kind);
}

test "registry は未知の artifact kind を E007 で拒否する" {
    var session = newSession(.{});
    defer session.deinit();
    const doc =
        \\{"schemaVersion":1,"packages":[
        \\  {"schemaVersion":1,"id":"pkg:00000000000000000000000000000000","name":"x","owner":"o","versions":[
        \\    {"schemaVersion":1,"version":"1.0.0","manifestHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","artifacts":{"source":{"kind":"sources","type":"raw","url":"https://example.com/x"}}}
        \\  ]}
        \\]}
    ;
    try testing.expectError(error.InvalidMetadata, registry.parseIndex(&session, doc, "test://index"));
    const failure = session.lastFailure().?;
    try testing.expectEqual(fetch.FailureKind.invalid_metadata, failure.kind);
    try testing.expectEqualStrings(diag.E007_UNKNOWN_ARTIFACT_KIND, failure.diagnosticCode());
}

test "静的registry は offline で version record 不足を offline と分類する" {
    const io = testing.io;
    var server = FixtureServer{ .io = io, .allocator = testing.allocator };
    const index_doc =
        \\{"schemaVersion":1,"packages":[
        \\  {"schemaVersion":1,"id":"pkg:00000000000000000000000000000000","name":"libeps","owner":"o","versions":[
        \\    {"schemaVersion":1,"version":"1.0.0","manifestHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}
        \\  ]}
        \\]}
    ;
    try server.start(&.{.{ .path = "/index.json", .body = index_doc }});
    defer server.stop();

    var session = newSession(.{});
    defer session.deinit();
    var reg = try registry.StaticRegistry.init(&session, server.base_url.?, .{});
    defer reg.deinit();
    // index を online で読み込んでから offline に切り替える。package record の
    // versions に無い version は個別 record の取得が必要なため offline 分類。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try reg.provider().listVersions(arena.allocator(), .{ .pkg = "libeps" });
    session.policy.offline = true;
    try testing.expectError(error.Offline, reg.acquireArtifact("libeps", "2.0.0", "source"));
    try testing.expectEqual(fetch.FailureKind.offline, session.lastFailure().?.kind);
}

test "静的registry は index と矛盾する package record を E010 で拒否する" {
    const io = testing.io;
    var server = FixtureServer{ .io = io, .allocator = testing.allocator };
    // index は versions を内包しないため package doc を取得する。
    const index_doc =
        \\{"schemaVersion":1,"packages":[
        \\  {"schemaVersion":1,"id":"pkg:77777777777777777777777777777777","name":"libgamma","owner":"alice","versions":[]}
        \\]}
    ;
    // index と同じ id だが name/owner が異なる record。
    const package_doc =
        \\{"schemaVersion":1,"id":"pkg:77777777777777777777777777777777","name":"renamed","owner":"mallory","versions":[]}
    ;
    try server.start(&.{
        .{ .path = "/index.json", .body = index_doc },
        .{ .path = "/alice/libgamma.json", .body = package_doc },
    });
    defer server.stop();

    var session = newSession(.{});
    defer session.deinit();
    var reg = try registry.StaticRegistry.init(&session, server.base_url.?, .{});
    defer reg.deinit();
    try testing.expectError(error.InvalidMetadata, reg.provider().listVersions(testing.allocator, .{ .pkg = "libgamma" }));
    const failure = session.lastFailure().?;
    try testing.expectEqual(fetch.FailureKind.invalid_metadata, failure.kind);
    try testing.expectEqualStrings(diag.E010_REGISTRY_RECORD_MISMATCH, failure.diagnosticCode());
}

test "静的registry は package record 未収録の version を個別 record から取得する" {
    const io = testing.io;
    var npkg = try buildNpkg(io);
    defer npkg.dir.cleanup();
    defer testing.allocator.free(npkg.archive);
    defer testing.allocator.free(npkg.sha);

    var server = FixtureServer{ .io = io, .allocator = testing.allocator };
    try server.start(&.{});
    defer server.stop();

    const index_doc =
        \\{"schemaVersion":1,"packages":[
        \\  {"schemaVersion":1,"id":"pkg:88888888888888888888888888888888","name":"libdelta","owner":"alice","versions":[]}
        \\]}
    ;
    // package doc に versions が無く、version record を個別取得する layout。
    const package_doc =
        \\{"schemaVersion":1,"id":"pkg:88888888888888888888888888888888","name":"libdelta","owner":"alice","versions":[]}
    ;
    const version_doc = try std.fmt.allocPrint(testing.allocator,
        \\{{"schemaVersion":1,"version":"3.0.0","manifestHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","artifacts":{{"source":{{"kind":"source","type":".npkg","sha256":"sha256:{s}","url":"{s}/artifacts/libdelta-3.0.0.npkg"}}}}}}
    , .{ npkg.sha, server.base_url.? });
    defer testing.allocator.free(version_doc);
    server.routes = &.{
        .{ .path = "/index.json", .body = index_doc },
        .{ .path = "/alice/libdelta.json", .body = package_doc },
        .{ .path = "/alice/libdelta/3.0.0.json", .body = version_doc },
        .{ .path = "/artifacts/libdelta-3.0.0.npkg", .body = npkg.archive },
    };

    var session = newSession(.{});
    defer session.deinit();
    var reg = try registry.StaticRegistry.init(&session, server.base_url.?, .{});
    defer reg.deinit();
    const artifact = try reg.acquireArtifact("libdelta", "3.0.0", "source");
    try testing.expectEqualStrings(npkg.archive, artifact.bytes);
    try testing.expectEqualStrings(npkg.sha, artifact.sha256);
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

// ---------------------------------------------------------------------------
// sync 統合（lock 駆動の取得・検証・materialize）
// ---------------------------------------------------------------------------

const sync_app_manifest =
    \\[package]
    \\name = "app"
    \\version = "0.1.0"
    \\license = "MIT"
    \\
;

/// `proj/` に app manifest と lock を書く。`lock_fmt` は manifestSha256 の
/// `{s}` を先頭に1箇所だけ含む書式文字列（残りは `args` が埋める）。
fn writeSyncProject(temporary: *std.testing.TmpDir, comptime lock_fmt: []const u8, args: anytype) ![:0]u8 {
    const io = testing.io;
    try temporary.dir.createDirPath(io, "proj");
    try temporary.dir.writeFile(io, .{ .sub_path = "proj/nako.toml", .data = sync_app_manifest });
    const manifest_sha = try fetch.sha256Hex(testing.allocator, sync_app_manifest);
    defer testing.allocator.free(manifest_sha);
    const lock = try std.fmt.allocPrint(testing.allocator, lock_fmt, .{manifest_sha} ++ args);
    defer testing.allocator.free(lock);
    try temporary.dir.writeFile(io, .{ .sub_path = "proj/nako.lock", .data = lock });
    return try temporary.dir.realPathFileAlloc(io, "proj", testing.allocator);
}

/// tar entry を gzip 圧縮した byte 列を作る（unpack.zig の検査対象を供給）。
fn buildTarGz(gpa: std.mem.Allocator, files: []const struct { path: []const u8, content: []const u8 }) ![]u8 {
    var tar_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer tar_buffer.deinit();
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &tar_buffer.writer };
    for (files) |file| try tar_writer.writeFileBytes(file.path, file.content, .{});
    try tar_writer.finishPedantically();

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // Compress.init は出力 buffer の最低容量を要求するため先に確保する。
    try out.ensureUnusedCapacity(64);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&out.writer, &window_buf, .gzip, .default);
    try compress.writer.writeAll(tar_buffer.written());
    try compress.finish();
    return try out.toOwnedSlice();
}

test "sync は static registry の package 固有 URL から .npkg を直接取得する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/src");
    try writePackage(temporary.dir, io, "pkg");
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/src/index.nako3", .data = "●表示とは\nここまで\n" });
    const pkg_root = try temporary.dir.realPathFileAlloc(io, "pkg", testing.allocator);
    defer testing.allocator.free(pkg_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var built = try npkg_build.build(testing.allocator, io, pkg_root, &list, .{});
    defer built.deinit();
    const hash = try fetch.sha256Hex(testing.allocator, built.archive);
    defer testing.allocator.free(hash);

    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    // package 固有 URL の下に index.json は無い。誤って index を引く実装は
    // 404 で失敗するため、成功と要求数で直接取得を検証する。
    try server.start(&.{.{ .path = "/alice/demo/demo.npkg", .body = built.archive }});
    defer server.stop();
    const artifact_url = try server.url("/alice/demo/demo.npkg");
    defer testing.allocator.free(artifact_url);
    const source_url = try server.url("/alice/demo");
    defer testing.allocator.free(source_url);

    const project_abs = try writeSyncProject(&temporary,
        \\{{
        \\  "schemaVersion": 1, "resolverVersion": 1,
        \\  "input": {{ "manifestSha256": "sha256:{s}", "profile": "default", "features": [], "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }} }},
        \\  "packages": {{
        \\    "pkg:33333333333333333333333333333333": {{
        \\      "id": "pkg:33333333333333333333333333333333",
        \\      "name": "demo", "version": "1.0.0",
        \\      "source": {{ "type": "static", "url": "{s}" }},
        \\      "dependencies": [], "features": [],
        \\      "implementation": "source",
        \\      "artifacts": {{ "source": {{ "kind": "source", "type": ".npkg", "sha256": "sha256:{s}", "url": "{s}" }} }}
        \\    }}
        \\  }},
        \\  "profiles": {{ "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }} }}
        \\}}
    , .{ source_url, hash, artifact_url });
    defer testing.allocator.free(project_abs);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ project_abs, "cache" });
    defer testing.allocator.free(cache_root);

    var report = try sync_mod.run(testing.allocator, io, .{
        .project_root = project_abs,
        .cache_root = cache_root,
    }, &list);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.package_count);
    // artifact 1 回だけの要求（`<pkg>/index.json` 等の index 再解決をしない）。
    try testing.expectEqual(@as(usize, 1), server.requests.load(.acquire));

    // 検証済み .npkg の内容が世代 dir に展開される。
    const index_path = try std.fs.path.join(testing.allocator, &.{ project_abs, ".nako", "env", report.generation, "deps", "demo", "src", "index.nako3" });
    defer testing.allocator.free(index_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, index_path, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("●表示とは\nここまで\n", bytes);
}

test "sync は lock の implementation で選択した artifact を取得する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const native_manifest =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\runtimes = ["lnako"]
        \\
        \\[[exports]]
        \\name = "demo"
        \\native = "lib/demo.so"
        \\
    ;
    const native_tgz = try buildTarGz(testing.allocator, &.{
        .{ .path = "nako.toml", .content = native_manifest },
        .{ .path = "lib/demo.so", .content = "NATIVE-BINARY" },
    });
    defer testing.allocator.free(native_tgz);
    const source_tgz = try buildTarGz(testing.allocator, &.{
        .{ .path = "nako.toml", .content = native_manifest },
        .{ .path = "src/index.nako3", .content = "SOURCE-DECOY" },
    });
    defer testing.allocator.free(source_tgz);
    const native_hash = try fetch.sha256Hex(testing.allocator, native_tgz);
    defer testing.allocator.free(native_hash);
    const source_hash = try fetch.sha256Hex(testing.allocator, source_tgz);
    defer testing.allocator.free(source_hash);

    var server = FixtureServer{ .io = testing.io, .allocator = testing.allocator };
    try server.start(&.{
        .{ .path = "/alice/demo/native.tar.gz", .body = native_tgz },
        .{ .path = "/alice/demo/source.tar.gz", .body = source_tgz },
    });
    defer server.stop();
    const native_url = try server.url("/alice/demo/native.tar.gz");
    defer testing.allocator.free(native_url);
    const source_url = try server.url("/alice/demo/source.tar.gz");
    defer testing.allocator.free(source_url);
    const package_url = try server.url("/alice/demo");
    defer testing.allocator.free(package_url);

    // implementation が "native" のため、source artifact ではなく native を
    // 取得・展開する。env.json の exports も native path を記録する。
    const project_abs = try writeSyncProject(&temporary,
        \\{{
        \\  "schemaVersion": 1, "resolverVersion": 1,
        \\  "input": {{ "manifestSha256": "sha256:{s}", "profile": "default", "features": [], "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }} }},
        \\  "packages": {{
        \\    "pkg:44444444444444444444444444444444": {{
        \\      "id": "pkg:44444444444444444444444444444444",
        \\      "name": "demo", "version": "1.0.0",
        \\      "source": {{ "type": "static", "url": "{s}" }},
        \\      "dependencies": [], "features": [],
        \\      "implementation": "native",
        \\      "artifacts": {{
        \\        "source": {{ "kind": "source", "type": "tar.gz", "sha256": "sha256:{s}", "url": "{s}" }},
        \\        "native": {{ "kind": "native", "type": "tar.gz", "sha256": "sha256:{s}", "url": "{s}" }}
        \\      }}
        \\    }}
        \\  }},
        \\  "profiles": {{ "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }} }}
        \\}}
    , .{ package_url, source_hash, source_url, native_hash, native_url });
    defer testing.allocator.free(project_abs);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ project_abs, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var report = try sync_mod.run(testing.allocator, io, .{
        .project_root = project_abs,
        .cache_root = cache_root,
    }, &list);
    defer report.deinit();

    // native artifact のみ取得され、その内容が materialize される。
    try testing.expectEqual(@as(usize, 1), server.requests.load(.acquire));
    const native_path = try std.fs.path.join(testing.allocator, &.{ project_abs, ".nako", "env", report.generation, "deps", "demo", "lib", "demo.so" });
    defer testing.allocator.free(native_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, native_path, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("NATIVE-BINARY", bytes);
    const decoy_path = try std.fs.path.join(testing.allocator, &.{ project_abs, ".nako", "env", report.generation, "deps", "demo", "src", "index.nako3" });
    defer testing.allocator.free(decoy_path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, decoy_path, .{}));

    // exports は lock の "native" 選択に合わせて native path を記録する。
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, report.environment_json, .{});
    defer parsed.deinit();
    const pkg = parsed.value.object.get("packages").?.object.get("pkg:44444444444444444444444444444444").?.object;
    const exports = pkg.get("exports").?.array;
    try testing.expectEqual(@as(usize, 1), exports.items.len);
    try testing.expectEqualStrings("lib/demo.so", exports.items[0].object.get("path").?.string);
}

test "sync は検証済み git object があれば checkout 無しで offline 同期する" {
    const io = testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const repo = try createGitRepo(&temporary, io);
    defer testing.allocator.free(repo.path);
    defer testing.allocator.free(repo.url);
    defer testing.allocator.free(repo.commit);

    const project_abs = try writeSyncProject(&temporary,
        \\{{
        \\  "schemaVersion": 1, "resolverVersion": 1,
        \\  "input": {{ "manifestSha256": "sha256:{s}", "profile": "default", "features": [], "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }} }},
        \\  "packages": {{
        \\    "pkg:55555555555555555555555555555555": {{
        \\      "id": "pkg:55555555555555555555555555555555",
        \\      "name": "demo", "version": "1.0.0",
        \\      "source": {{ "type": "git", "url": "{s}", "commit": "{s}" }},
        \\      "dependencies": [], "features": [],
        \\      "artifacts": {{ "source": {{ "kind": "source", "type": "raw" }} }}
        \\    }}
        \\  }},
        \\  "profiles": {{ "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }} }}
        \\}}
    , .{ repo.url, repo.commit });
    defer testing.allocator.free(project_abs);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ project_abs, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var first = try sync_mod.run(testing.allocator, io, .{
        .project_root = project_abs,
        .cache_root = cache_root,
    }, &list);
    first.deinit();

    // 可変 checkout と upstream repo を消しても、検証済み object だけで
    // materialize できる（offline で Git 起動・clone/fetch を要求しない）。
    const checkouts = try std.fs.path.join(testing.allocator, &.{ cache_root, "checkouts" });
    defer testing.allocator.free(checkouts);
    try std.Io.Dir.cwd().deleteTree(io, checkouts);
    try std.Io.Dir.cwd().deleteTree(io, repo.path);

    var second = try sync_mod.run(testing.allocator, io, .{
        .project_root = project_abs,
        .cache_root = cache_root,
        .policy = .{ .offline = true },
    }, &list);
    defer second.deinit();
    const index_path = try std.fs.path.join(testing.allocator, &.{ project_abs, ".nako", "env", second.generation, "deps", "demo", "src", "index.nako3" });
    defer testing.allocator.free(index_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, index_path, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("●表示とは\nここまで\n", bytes);
}
