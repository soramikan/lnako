//! テスト専用の最小 HTTP registry fixture。
//!
//! `project_test.zig`（npm registry E2E）と `package_test.zig`（static
//! registry への publish E2E）が共有する。単一接続ずつ処理し、
//! `Connection: close` で応答する。GET に加えて PUT の本文と
//! `Authorization` / `Content-Type` を記録するため、publish の transport
//! 契約（認証ヘッダ・artifact バイト列・再実行時の GET のみ）を
//! 実際の HTTP 往復で観測できる。
//!
//! 外部ネットワークには一切接続しない。listen で port を確定してから
//! serve で thread を起動するため、port を含む URL を spawn 前に
//! 組み立てられる。

const std = @import("std");
const builtin = @import("builtin");

/// capture する本文の上限（fixture 用の安全弁）。
const max_capture_body: usize = 32 * 1024 * 1024;

/// 応答へ追加するヘッダ（例: redirect の Location）。
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// 1 route 分の応答。`method` が空文字なら任意 method に一致する。
pub const Route = struct {
    method: []const u8 = "GET",
    path: []const u8,
    body: []const u8 = "",
    status: u16 = 200,
    headers: []const Header = &.{},
};

/// 受理した 1 request の観測値。文字列は fixture の allocator が所有する。
pub const CapturedRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
    authorization: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

/// 単一接続ずつ処理する最小 registry サーバ。
pub const Server = struct {
    io: std.Io,
    /// listen 時などテストスレッド側で使う allocator（caller 所有）。
    allocator: std.mem.Allocator,
    /// request 観測値の確保に使う thread-safe allocator。server thread が
    /// 使う一方で test 側も fetch のため同じ arena へ確保するため、arena を
    /// 共有すると data race になる。capture 専用に分離し `stop` で解放する。
    capture_allocator: std.mem.Allocator = std.heap.smp_allocator,
    listener: ?std.Io.net.Server = null,
    thread: ?std.Thread = null,
    base_url: ?[]u8 = null,
    routes: []const Route = &.{},
    /// true のとき、route に無い GET を最後に受理した同一 path の PUT 本文で
    /// 200 応答する。publish の再実行（公開済み version record の照会）を
    /// 単一サーバで観測するために使う。
    echo_puts: bool = false,
    requests: std.atomic.Value(usize) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    captured: std.ArrayList(CapturedRequest) = .empty,

    pub fn listen(self: *Server) !void {
        const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.listener = try loopback.listen(self.io, .{ .reuse_address = true });
        self.base_url = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}", .{self.listener.?.socket.address.getPort()});
    }

    pub fn serve(self: *Server, routes: []const Route) !void {
        self.routes = routes;
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{ self, self.listener.? });
    }

    pub fn stop(self: *Server) void {
        if (self.listener) |*listener| {
            self.stopping.store(true, .release);
            // `accept` を解除する。Windows の listening socket shutdown は
            // INVALID_PARAMETER で panic するため自接続でも起こす。
            if (builtin.os.tag != .windows) {
                const wake: std.Io.net.Stream = .{ .socket = listener.socket };
                wake.shutdown(self.io, .both) catch {};
            }
            if (listener.socket.address.connect(self.io, .{ .mode = .stream })) |stream| {
                stream.close(self.io);
            } else |_| {}
            if (self.thread) |thread| thread.join();
            self.thread = null;
            listener.deinit(self.io);
            self.listener = null;
        }
        if (self.base_url) |base| self.allocator.free(base);
        self.base_url = null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.captured.items) |request| {
            self.capture_allocator.free(request.method);
            self.capture_allocator.free(request.path);
            self.capture_allocator.free(request.body);
            if (request.authorization) |value| self.capture_allocator.free(value);
            if (request.content_type) |value| self.capture_allocator.free(value);
        }
        self.captured.deinit(self.capture_allocator);
        self.captured = .empty;
    }

    pub fn url(self: *const Server, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ self.base_url.?, path });
    }

    pub fn requestCount(self: *const Server) usize {
        return self.requests.load(.acquire);
    }

    pub fn captureCount(self: *Server) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.captured.items.len;
    }

    /// 受理順の capture を返す。範囲外は null。
    pub fn captureAt(self: *Server, index: usize) ?CapturedRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (index >= self.captured.items.len) return null;
        return self.captured.items[index];
    }

    /// method と path が一致する最初の capture を返す（存在確認用）。
    pub fn findCapture(self: *Server, method: []const u8, path: []const u8) ?CapturedRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.captured.items) |request| {
            if (std.mem.eql(u8, request.method, method) and std.mem.eql(u8, request.path, path)) return request;
        }
        return null;
    }

    /// method 一致の capture 件数。
    pub fn countCaptures(self: *Server, method: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.captured.items) |request| {
            if (std.mem.eql(u8, request.method, method)) count += 1;
        }
        return count;
    }

    /// capture を追加する。成功時は request のメモリ所有権を Server が
    /// 引き取り、失敗時は呼出し側が解放する。
    fn record(self: *Server, request: CapturedRequest) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.captured.append(self.capture_allocator, request) catch return false;
        return true;
    }

    fn serveLoop(self: *Server, server: std.Io.net.Server) void {
        var listener = server;
        while (true) {
            var stream = listener.accept(self.io) catch return;
            if (self.stopping.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            self.handle(&stream);
        }
    }

    fn handle(self: *Server, stream: *std.Io.net.Stream) void {
        defer stream.close(self.io);
        _ = self.requests.fetchAdd(1, .release);
        var read_buffer: [512]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        // 要求ヘッダの終端は 1 byte ずつ読んで CRLFCRLF を検出する。
        var header_bytes: [8192]u8 = undefined;
        var total: usize = 0;
        var window: u32 = 0;
        while (true) {
            var byte: [1]u8 = undefined;
            const n = reader.interface.readSliceShort(&byte) catch return;
            if (n == 0) return;
            if (total < header_bytes.len) {
                header_bytes[total] = byte[0];
                total += 1;
            }
            window = (window << 8) | byte[0];
            if (window == std.mem.readInt(u32, "\r\n\r\n", .big)) break;
        }
        const head = header_bytes[0..total];
        const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return;
        const line = head[0..line_end];
        const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return;
        const rest = line[first_space + 1 ..];
        const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
        const method = line[0..first_space];
        const path = rest[0..second_space];

        const declared = headerValue(head, "content-length");
        const body_len: usize = if (declared) |text| std.fmt.parseInt(usize, std.mem.trim(u8, text, " \t"), 10) catch 0 else 0;
        // 申告された巨大 Content-Length で確保しない（fixture は小さい本文のみ）。
        if (body_len > max_capture_body) return;
        const body = self.capture_allocator.alloc(u8, body_len) catch return;
        var body_owned = true;
        defer if (body_owned) self.capture_allocator.free(body);
        var filled: usize = 0;
        while (filled < body_len) {
            const n = reader.interface.readSliceShort(body[filled..]) catch return;
            if (n == 0) break;
            filled += n;
        }
        // 途中で切れた要求は Content-Length と一致しないため観測対象にしない。
        if (filled != body_len) return;
        const request = CapturedRequest{
            .method = self.capture_allocator.dupe(u8, method) catch return,
            .path = self.capture_allocator.dupe(u8, path) catch return,
            .body = body,
            .authorization = dupeOptional(self.capture_allocator, headerValue(head, "authorization")),
            .content_type = dupeOptional(self.capture_allocator, headerValue(head, "content-type")),
        };
        if (self.record(request)) {
            body_owned = false;
        } else {
            self.capture_allocator.free(request.method);
            self.capture_allocator.free(request.path);
            if (request.authorization) |value| self.capture_allocator.free(value);
            if (request.content_type) |value| self.capture_allocator.free(value);
        }

        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        for (self.routes) |route| {
            if (route.method.len != 0 and !std.mem.eql(u8, route.method, method)) continue;
            if (!std.mem.eql(u8, route.path, path)) continue;
            writer.interface.print("HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nContent-Type: application/octet-stream\r\n", .{ route.status, statusText(route.status), route.body.len }) catch return;
            for (route.headers) |header| {
                writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value }) catch return;
            }
            writer.interface.writeAll("Connection: close\r\n\r\n") catch return;
            writer.interface.writeAll(route.body) catch return;
            writer.interface.flush() catch return;
            return;
        }
        if (self.echo_puts and std.mem.eql(u8, method, "GET")) {
            if (self.lastPutBody(path)) |echo_body| {
                writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n", .{echo_body.len}) catch return;
                writer.interface.writeAll(echo_body) catch return;
                writer.interface.flush() catch return;
                return;
            }
        }
        writer.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch return;
        writer.interface.flush() catch return;
    }

    fn lastPutBody(self: *Server, path: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var index = self.captured.items.len;
        while (index > 0) {
            index -= 1;
            const request = self.captured.items[index];
            if (std.mem.eql(u8, request.method, "PUT") and std.mem.eql(u8, request.path, path)) return request.body;
        }
        return null;
    }

    fn statusText(status: u16) []const u8 {
        return switch (status) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            301 => "Moved Permanently",
            302 => "Found",
            307 => "Temporary Redirect",
            308 => "Permanent Redirect",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            409 => "Conflict",
            500 => "Internal Server Error",
            503 => "Service Unavailable",
            else => "Status",
        };
    }
};

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) ?[]const u8 {
    const source = value orelse return null;
    return allocator.dupe(u8, source) catch null;
}

/// ヘッダ領域から `name`（大小文字無視）の値を返す。値は CRLF まで。
/// 同名ヘッダが複数ある場合は最初の1件。
fn headerValue(head: []const u8, comptime name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}
