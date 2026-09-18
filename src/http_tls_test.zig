const std = @import("std");

/// テスト用ハーネス。平文HTTPサーバが301で別ポートのHTTPSリスナへ
/// リダイレクトし、そのHTTPSリスナは接続を受理した直後に閉じる。HTTP→HTTPS
/// リダイレクトがTLS文脈の未初期化でpanicしないことをInterpreter/AOT双方で
/// 検証するために使う。
///
/// `defer pair.stop()` を `start()` の成否に関わらず安全に呼べるよう、
/// すべての資源をnull許容で保持する。
pub const RedirectToClosedTls = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    tls_server: ?std.Io.net.Server = null,
    http_server: ?std.Io.net.Server = null,
    location: ?[]u8 = null,
    url: ?[]u8 = null,
    tls_accepted: std.atomic.Value(bool) = .init(false),
    tls_thread: ?std.Thread = null,
    http_thread: ?std.Thread = null,

    pub fn start(self: *@This()) !void {
        const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.tls_server = try loopback.listen(self.io, .{ .reuse_address = true });
        self.http_server = try loopback.listen(self.io, .{ .reuse_address = true });
        self.location = try std.fmt.allocPrint(self.allocator, "https://127.0.0.1:{d}/binary", .{self.tls_server.?.socket.address.getPort()});
        self.url = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}/redirect", .{self.http_server.?.socket.address.getPort()});
        self.tls_thread = try std.Thread.spawn(.{}, acceptAndClose, .{ &self.tls_server.?, self.io, &self.tls_accepted });
        self.http_thread = try std.Thread.spawn(.{}, redirect, .{ &self.http_server.?, self.io, self.location.? });
    }

    pub fn stop(self: *@This()) void {
        // joinより先にlisten socketを閉じ、accept中のthreadを解く。
        if (self.tls_server) |*server| {
            server.deinit(self.io);
            self.tls_server = null;
        }
        if (self.http_server) |*server| {
            server.deinit(self.io);
            self.http_server = null;
        }
        if (self.http_thread) |thread| thread.join();
        if (self.tls_thread) |thread| thread.join();
        if (self.location) |text| self.allocator.free(text);
        if (self.url) |text| self.allocator.free(text);
    }

    fn acceptAndClose(listener: *std.Io.net.Server, listener_io: std.Io, accepted: *std.atomic.Value(bool)) void {
        const stream = listener.accept(listener_io) catch return;
        accepted.store(true, .release);
        stream.close(listener_io);
    }

    fn redirect(listener: *std.Io.net.Server, listener_io: std.Io, target: []const u8) void {
        var stream = listener.accept(listener_io) catch return;
        defer stream.close(listener_io);
        var read_buffer: [512]u8 = undefined;
        var reader = stream.reader(listener_io, &read_buffer);
        // 要求ヘッダの終端（CRLFCRLF）まで読み切ってから応答する。
        var window: u32 = 0;
        while (true) {
            var byte: [1]u8 = undefined;
            const n = reader.interface.readSliceShort(&byte) catch break;
            if (n == 0) break;
            window = (window << 8) | byte[0];
            if (window == std.mem.readInt(u32, "\r\n\r\n", .big)) break;
        }
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(listener_io, &write_buffer);
        writer.interface.print("HTTP/1.1 301 Moved Permanently\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{target}) catch return;
        writer.interface.flush() catch return;
    }
};
