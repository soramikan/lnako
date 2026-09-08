const std = @import("std");

// 簡易HTTPサーバの受信エンジン。
// 接続acceptとheader/body受信を接続単位のworker threadへ分離し、
// 受信完了した要求だけを有界queue経由でメイン（言語実行）threadへ渡す。
// callback・globals・GCの操作はメインthread側に残す。
// worker側のsocket操作はengineが所有する専用 std.Io.Threaded を使い、
// global_single_threadedでは並行処理しない。

pub const Limits = struct {
    /// 受信中workerとqueue内要求を合わせた接続上限。
    max_pending: usize = 32,
    /// request lineとheader行の合計byte上限。
    max_header_bytes: usize = 64 * 1024,
    /// body上限（超過分は破棄して413応答へ回す）。
    max_body_bytes: usize = 10 * 1024 * 1024,
    /// 接続acceptから要求受信完了までの絶対期限。
    receive_timeout_ns: u64 = 30 * std.time.ns_per_s,
    /// watchdogが期限切れworkerと終了workerを回収する間隔。
    reap_interval_ns: u64 = 50 * std.time.ns_per_ms,
};

/// workerが所有するbyte buffer。`allocator`はengineのthread-safe allocatorで、
/// メイン側への所有権移譲後もdeinitはこのallocatorを使う。
pub const Request = struct {
    allocator: std.mem.Allocator,
    stream: ?std.Io.net.Stream = null,
    head_request: bool = false,
    method: []u8,
    target: []u8,
    content_type: []u8,
    body: []u8,
    too_large: bool = false,

    /// bufferだけを解放する。`stream`の所有権は受け取った側が持ち、応答または
    /// 保持・破棄のときに一度だけcloseする。
    pub fn deinit(self: *Request) void {
        const allocator = self.allocator;
        allocator.free(self.method);
        allocator.free(self.target);
        allocator.free(self.content_type);
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const ChunkedBody = struct {
    body: []u8,
    too_large: bool,
};

const header_line_buffer_bytes = 8 * 1024;

const Worker = struct {
    engine: *Engine,
    stream: std.Io.net.Stream,
    /// 受信の絶対期限（awake clockのnanoseconds）。spawn前に確定する。
    deadline_ns: i96,
    /// 以下はengine.mutexで保護する。
    thread: ?std.Thread = null,
    finished: bool = false,
    expired: bool = false,
};

pub const Engine = struct {
    /// engine内部とrequest bufferの割り当てに使う。worker threadからも触るため
    /// thread-safeなallocatorが必須。
    allocator: std.mem.Allocator,
    server: *std.Io.net.Server,
    limits: Limits,
    threaded: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    queue_updated: std.Io.Condition = .init,
    queue: std.ArrayList(Request) = .empty,
    workers: std.ArrayList(*Worker) = .empty,
    stopping: bool = false,
    started: bool = false,
    accept_thread: ?std.Thread = null,
    watchdog_thread: ?std.Thread = null,

    /// `server`の所有権は呼び出し側に残る。engineは返り値のheap配置に固定される
    /// （専用Threadedのio userdataがengine内fieldを指すためmove不可）。
    pub fn create(allocator: std.mem.Allocator, server: *std.Io.net.Server, limits: Limits) !*Engine {
        const engine = try allocator.create(Engine);
        errdefer allocator.destroy(engine);
        engine.* = .{
            .allocator = allocator,
            .server = server,
            .limits = limits,
            // 直接vtable呼び出ししか使わないためasync用の内部allocatorは不要。
            .threaded = .init(.failing, .{}),
        };
        return engine;
    }

    pub fn io(engine: *Engine) std.Io {
        return engine.threaded.io();
    }

    fn lock(engine: *Engine) void {
        engine.mutex.lockUncancelable(engine.io());
    }

    fn unlock(engine: *Engine) void {
        engine.mutex.unlock(engine.io());
    }

    /// acceptor threadと期限回収watchdogを開始する。
    pub fn start(engine: *Engine) !void {
        engine.lock();
        if (engine.started) {
            engine.unlock();
            return;
        }
        engine.stopping = false;
        engine.started = true;
        engine.accept_thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, acceptMain, .{engine}) catch |err| {
            engine.started = false;
            engine.unlock();
            return err;
        };
        engine.watchdog_thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, watchdogMain, .{engine}) catch |err| {
            engine.stopping = true;
            engine.started = false;
            engine.unlock();
            engine.wakeAcceptor();
            if (engine.accept_thread) |thread| thread.join();
            engine.accept_thread = null;
            return err;
        };
        engine.unlock();
    }

    /// 受信完了した要求を取り出す。queueが空なら要求到着かstopまで待機する。
    /// 返り値の`stream`所有権は呼び出し側へ移る。停止中はnull。
    pub fn next(engine: *Engine) ?Request {
        engine.lock();
        defer engine.unlock();
        while (true) {
            if (engine.queue.items.len > 0) return engine.queue.orderedRemove(0);
            if (engine.stopping) return null;
            engine.queue_updated.waitUncancelable(engine.io(), &engine.mutex);
        }
    }

    /// 受信中workerとqueue内要求を合わせた現在の接続数。テストと状態確認用。
    pub fn pendingCount(engine: *Engine) usize {
        engine.lock();
        defer engine.unlock();
        return engine.workers.items.len + engine.queue.items.len;
    }

    /// queue内に滞留している完了要求数。テストと状態確認用。
    pub fn queuedCount(engine: *Engine) usize {
        engine.lock();
        defer engine.unlock();
        return engine.queue.items.len;
    }

    /// acceptor停止→watchdog停止→worker socketのshutdown→join→queue内socketの
    /// closeの順で資源を一度だけ解放する。専用Threadedのdeinitはdestroy側。
    pub fn stop(engine: *Engine) void {
        const engine_io = engine.io();
        engine.lock();
        if (!engine.started or engine.stopping) {
            engine.unlock();
            return;
        }
        engine.stopping = true;
        engine.queue_updated.broadcast(engine_io);
        engine.unlock();

        // ブロック中のacceptを自身への接続で抜けさせる。
        engine.wakeAcceptor();
        if (engine.accept_thread) |thread| thread.join();
        engine.accept_thread = null;
        if (engine.watchdog_thread) |thread| thread.join();
        engine.watchdog_thread = null;

        // 受信中のsocketをshutdownしてworkerのreadを抜けさせ、全workerをjoinする。
        engine.lock();
        for (engine.workers.items) |worker| worker.stream.shutdown(engine_io, .both) catch {};
        engine.unlock();
        for (engine.workers.items) |worker| {
            if (worker.thread) |thread| thread.join();
        }
        engine.lock();
        for (engine.workers.items) |worker| engine.allocator.destroy(worker);
        engine.workers.clearRetainingCapacity();
        // 未処理のqueue内要求はstreamを一度だけcloseしてbufferを解放する。
        for (engine.queue.items) |*request| {
            if (request.stream) |*stream| stream.close(engine_io);
            request.deinit();
        }
        engine.queue.clearRetainingCapacity();
        engine.unlock();
    }

    /// stop()の後に呼ぶ。workerとqueueはstop時点で空になっている。
    pub fn destroy(engine: *Engine) void {
        engine.queue.deinit(engine.allocator);
        engine.workers.deinit(engine.allocator);
        engine.threaded.deinit();
        engine.allocator.destroy(engine);
    }

    fn wakeAcceptor(engine: *Engine) void {
        const engine_io = engine.io();
        const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(engine.server.socket.address.getPort()) };
        if (loopback.connect(engine_io, .{ .mode = .stream })) |wakeup| {
            wakeup.close(engine_io);
        } else |_| {}
    }

    /// 終了したworkerをjoinして一覧から外す。engine.mutex保持中に呼ぶ。
    fn sweepLocked(engine: *Engine) void {
        var index = engine.workers.items.len;
        while (index > 0) {
            index -= 1;
            const worker = engine.workers.items[index];
            if (!worker.finished) continue;
            if (worker.thread) |thread| thread.join();
            _ = engine.workers.orderedRemove(index);
            engine.allocator.destroy(worker);
        }
    }

    /// 絶対期限を過ぎた受信中socketをshutdownしてreadを抜けさせる。
    /// engine.mutex保持中に呼ぶ。
    fn reapExpiredLocked(engine: *Engine) void {
        const now = std.Io.Clock.awake.now(engine.io()).nanoseconds;
        for (engine.workers.items) |worker| {
            if (worker.finished or worker.expired or now <= worker.deadline_ns) continue;
            worker.expired = true;
            worker.stream.shutdown(engine.io(), .both) catch {};
        }
    }
};

fn acceptMain(engine: *Engine) void {
    const io = engine.io();
    while (true) {
        const stream = engine.server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return,
        };
        engine.lock();
        if (engine.stopping) {
            engine.unlock();
            stream.close(io);
            return;
        }
        engine.sweepLocked();
        const pending = engine.workers.items.len + engine.queue.items.len;
        if (pending >= engine.limits.max_pending) {
            engine.unlock();
            respondServiceUnavailable(io, stream);
            continue;
        }
        const worker = engine.allocator.create(Worker) catch {
            engine.unlock();
            stream.close(io);
            continue;
        };
        worker.* = .{
            .engine = engine,
            .stream = stream,
            .deadline_ns = std.Io.Clock.awake.now(io).nanoseconds + @as(i96, @intCast(engine.limits.receive_timeout_ns)),
        };
        engine.workers.append(engine.allocator, worker) catch {
            engine.unlock();
            stream.close(io);
            engine.allocator.destroy(worker);
            continue;
        };
        worker.thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, workerMain, .{worker}) catch {
            _ = engine.workers.pop();
            engine.unlock();
            stream.close(io);
            engine.allocator.destroy(worker);
            continue;
        };
        engine.unlock();
    }
}

fn watchdogMain(engine: *Engine) void {
    const io = engine.io();
    const interval = std.Io.Duration.fromNanoseconds(@intCast(engine.limits.reap_interval_ns));
    while (true) {
        std.Io.sleep(io, interval, .awake) catch return;
        engine.lock();
        engine.sweepLocked();
        engine.reapExpiredLocked();
        const stopping = engine.stopping;
        engine.unlock();
        if (stopping) return;
    }
}

fn workerMain(worker: *Worker) void {
    const engine = worker.engine;
    const io = engine.io();
    var request = readRequest(engine.allocator, io, worker.stream, engine.limits) catch |err| {
        if (err == error.HttpHeaderTooLarge) respondHeaderTooLarge(io, worker.stream) else worker.stream.close(io);
        finishWorker(engine, worker);
        return;
    };
    engine.lock();
    engine.queue.append(engine.allocator, request) catch {
        engine.unlock();
        if (request.stream) |*stream| stream.close(io);
        request.deinit();
        finishWorker(engine, worker);
        return;
    };
    worker.finished = true;
    engine.queue_updated.signal(io);
    engine.unlock();
}

fn finishWorker(engine: *Engine, worker: *Worker) void {
    engine.lock();
    worker.finished = true;
    engine.queue_updated.signal(engine.io());
    engine.unlock();
}

/// worker側の受信入口。parse結果へstream所有権を載せて返す。
fn readRequest(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, limits: Limits) !Request {
    var buffer: [header_line_buffer_bytes]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    var request = parseRequest(allocator, &reader.interface, limits) catch |err| return mapReadError(&reader, err);
    request.stream = stream;
    return request;
}

/// header・bodyを読み切った要求を組み立てる。bufferは`allocator`（engine側の
/// thread-safe allocator）で割り当て、返り値と一緒に所有権を移す。
pub fn parseRequest(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) !Request {
    var header_bytes: usize = 0;
    const request_line_raw = (try takeHeaderLine(reader, &header_bytes, limits)) orelse return error.InvalidHttpRequest;
    const request_line = std.mem.trimEnd(u8, request_line_raw, "\r");
    var request_parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_source = request_parts.next() orelse return error.InvalidHttpRequest;
    const target_source = request_parts.next() orelse return error.InvalidHttpRequest;
    if (method_source.len == 0 or std.mem.indexOfAny(u8, method_source, "\r\n\x00") != null) return error.InvalidHttpRequest;
    if (target_source.len == 0 or std.mem.indexOfAny(u8, target_source, "\r\n\x00") != null) return error.InvalidHttpRequest;
    const method = try allocator.dupe(u8, method_source);
    errdefer allocator.free(method);
    for (method) |*byte| byte.* = std.ascii.toUpper(byte.*);
    const target = try allocator.dupe(u8, target_source);
    errdefer allocator.free(target);
    var content_length: usize = 0;
    var transfer_chunked = false;
    var content_type = try allocator.alloc(u8, 0);
    errdefer allocator.free(content_type);
    while (true) {
        const line_raw = (try takeHeaderLine(reader, &header_bytes, limits)) orelse return error.InvalidHttpRequest;
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");
        const header_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (header_name.len == 0 or std.mem.indexOfAny(u8, header_name, "\r\n\x00") != null or std.mem.indexOfAny(u8, header_value, "\r\n\x00") != null) return error.InvalidHttpHeader;
        if (std.ascii.eqlIgnoreCase(header_name, "content-length")) {
            content_length = std.fmt.parseInt(usize, header_value, 10) catch return error.InvalidHttpHeader;
        } else if (std.ascii.eqlIgnoreCase(header_name, "transfer-encoding")) {
            transfer_chunked = std.ascii.indexOfIgnoreCase(header_value, "chunked") != null;
        } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
            const replacement = try allocator.dupe(u8, header_value);
            allocator.free(content_type);
            content_type = replacement;
        }
    }
    if (transfer_chunked and content_length > 0) return error.InvalidHttpRequest;
    const head_request = std.ascii.eqlIgnoreCase(method, "HEAD");
    if (transfer_chunked) {
        const chunked = try readChunkedBody(allocator, reader, limits.max_body_bytes);
        return .{ .allocator = allocator, .head_request = head_request, .method = method, .target = target, .content_type = content_type, .body = chunked.body, .too_large = chunked.too_large };
    }
    if (content_length > limits.max_body_bytes) {
        const discarded = try reader.discardShort(content_length);
        if (discarded != content_length) return error.InvalidHttpRequest;
        const empty_body = try allocator.alloc(u8, 0);
        return .{ .allocator = allocator, .head_request = head_request, .method = method, .target = target, .content_type = content_type, .body = empty_body, .too_large = true };
    }
    const body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);
    try reader.readSliceAll(body);
    return .{ .allocator = allocator, .head_request = head_request, .method = method, .target = target, .content_type = content_type, .body = body };
}

/// request line・header行を1行読み、合計byte数を`header_bytes`へ累計する。
/// 合計が上限を超えるとerror.HttpHeaderTooLarge。
fn takeHeaderLine(reader: *std.Io.Reader, header_bytes: *usize, limits: Limits) !?[]u8 {
    const raw = try reader.takeDelimiter('\n');
    const line = raw orelse return null;
    header_bytes.* += line.len + 1;
    if (header_bytes.* > limits.max_header_bytes) return error.HttpHeaderTooLarge;
    return raw;
}

fn mapReadError(reader: *std.Io.net.Stream.Reader, err: anyerror) anyerror {
    if (err != error.ReadFailed) return err;
    return switch (reader.err orelse error.ReadFailed) {
        error.ConnectionResetByPeer,
        error.Timeout,
        error.SocketUnconnected,
        => error.HttpServerClientDisconnected,
        else => |underlying| underlying,
    };
}

/// header量上限を超えた接続へ431をbest effortで返して閉じる。worker側の
/// 固定byte応答で、言語runtimeには触れない。
fn respondHeaderTooLarge(io: std.Io, stream: std.Io.net.Stream) void {
    respondFixed(io, stream, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
}

/// 接続上限に達した接続へ503をbest effortで返して閉じる。
fn respondServiceUnavailable(io: std.Io, stream: std.Io.net.Stream) void {
    respondFixed(io, stream, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
}

fn respondFixed(io: std.Io, stream: std.Io.net.Stream, response: []const u8) void {
    defer stream.close(io);
    var buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(response) catch {};
    writer.interface.flush() catch {};
}

pub fn readChunkedBody(allocator: std.mem.Allocator, reader: *std.Io.Reader, maximum_size: usize) !ChunkedBody {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    var too_large = false;
    while (true) {
        const size_line_raw = (try reader.takeDelimiter('\n')) orelse return error.InvalidHttpChunk;
        const size_line = std.mem.trim(u8, std.mem.trimEnd(u8, size_line_raw, "\r"), " \t");
        const extension = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const size_text = std.mem.trim(u8, size_line[0..extension], " \t");
        if (size_text.len == 0) return error.InvalidHttpChunk;
        const chunk_size = std.fmt.parseInt(usize, size_text, 16) catch return error.InvalidHttpChunk;
        if (chunk_size == 0) {
            while (true) {
                const trailer_raw = (try reader.takeDelimiter('\n')) orelse return error.InvalidHttpChunk;
                if (std.mem.trimEnd(u8, trailer_raw, "\r").len == 0) break;
            }
            break;
        }
        if (too_large or chunk_size > maximum_size - body.items.len) {
            too_large = true;
            if (try reader.discardShort(chunk_size) != chunk_size) return error.InvalidHttpChunk;
        } else {
            const destination = try body.addManyAsSlice(allocator, chunk_size);
            try reader.readSliceAll(destination);
        }
        const terminator_raw = (try reader.takeDelimiter('\n')) orelse return error.InvalidHttpChunk;
        if (std.mem.trimEnd(u8, terminator_raw, "\r").len != 0) return error.InvalidHttpChunk;
    }
    if (too_large) {
        body.deinit(allocator);
        return .{ .body = try allocator.alloc(u8, 0), .too_large = true };
    }
    return .{ .body = try body.toOwnedSlice(allocator), .too_large = false };
}

fn ingressTestConnect(io: std.Io, port: u16) !std.Io.net.Stream {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    return address.connect(io, .{ .mode = .stream });
}

fn ingressTestSend(io: std.Io, port: u16, bytes: []const u8, half_close: bool) !std.Io.net.Stream {
    var client = try ingressTestConnect(io, port);
    errdefer client.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = client.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    if (half_close) try client.shutdown(io, .send);
    return client;
}

/// 応答なしに閉じられたことを確認する。RST由来のread errorも切断として扱う。
fn ingressTestExpectClosed(client: std.Io.net.Stream, io: std.Io) !void {
    var buffer: [512]u8 = undefined;
    var reader = client.reader(io, &buffer);
    const line = reader.interface.takeDelimiter('\n') catch return;
    try std.testing.expect(line == null);
}

/// engineの条件成立を短い間隔で確認する。期限超過は失敗。
fn ingressTestWait(engine: *Engine, io: std.Io, pending: bool) !void {
    for (0..200) |_| {
        const reached = if (pending) engine.pendingCount() > 0 else engine.queuedCount() > 0;
        if (reached) return;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch return error.Unexpected;
    }
    return error.Timeout;
}

test "受信parseはrequest lineとheaderとbodyを解釈する" {
    var reader: std.Io.Reader = .fixed("post /Echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello");
    var request = try parseRequest(std.testing.allocator, &reader, .{});
    defer request.deinit();
    try std.testing.expectEqualStrings("POST", request.method);
    try std.testing.expectEqualStrings("/Echo", request.target);
    try std.testing.expectEqualStrings("text/plain", request.content_type);
    try std.testing.expectEqualStrings("hello", request.body);
    try std.testing.expect(!request.head_request);
    try std.testing.expect(!request.too_large);
}

test "受信parseはHEAD要求とchunked bodyを解釈する" {
    var head_reader: std.Io.Reader = .fixed("HEAD /h HTTP/1.1\r\n\r\n");
    var head = try parseRequest(std.testing.allocator, &head_reader, .{});
    defer head.deinit();
    try std.testing.expect(head.head_request);

    var chunked_reader: std.Io.Reader = .fixed("POST /c HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n");
    var chunked = try parseRequest(std.testing.allocator, &chunked_reader, .{});
    defer chunked.deinit();
    try std.testing.expectEqualStrings("Wikipedia", chunked.body);
    try std.testing.expect(!chunked.too_large);
}

test "受信parseはheader量上限をHttpHeaderTooLargeで返す" {
    var reader: std.Io.Reader = .fixed("GET / HTTP/1.1\r\nX-Long-Header: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n");
    try std.testing.expectError(error.HttpHeaderTooLarge, parseRequest(std.testing.allocator, &reader, .{ .max_header_bytes = 64 }));
}

test "受信parseはbody上限超過をtoo_largeで返す" {
    var reader: std.Io.Reader = .fixed("POST /b HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789");
    var request = try parseRequest(std.testing.allocator, &reader, .{ .max_body_bytes = 4 });
    defer request.deinit();
    try std.testing.expect(request.too_large);
    try std.testing.expectEqual(0, request.body.len);
}

test "受信parseはchunkedとcontent-length併記を拒否する" {
    var reader: std.Io.Reader = .fixed("POST /x HTTP/1.1\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n");
    try std.testing.expectError(error.InvalidHttpRequest, parseRequest(std.testing.allocator, &reader, .{}));
}

test "受信parseは割り当て失敗時にbufferを残さない" {
    const bytes = "POST /oom HTTP/1.1\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var reader: std.Io.Reader = .fixed(bytes);
            var request = try parseRequest(allocator, &reader, .{});
            defer request.deinit();
            try std.testing.expectEqualStrings("POST", request.method);
        }
    }.run, .{});
}

test "受信engineは低速接続中も別接続の完了要求をqueueへ渡す" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const engine = try Engine.create(std.testing.allocator, &server, .{});
    defer {
        engine.stop();
        engine.destroy();
    }
    try engine.start();
    const port = server.socket.address.getPort();

    // body未完のまま送り切らない接続。send shutdownしないためworkerのreadが保留される。
    var slow = try ingressTestSend(io, port, "POST /slow HTTP/1.1\r\nContent-Length: 100\r\n\r\npart", false);
    defer slow.close(io);

    var fast = try ingressTestSend(io, port, "GET /fast HTTP/1.1\r\n\r\n", true);
    defer fast.close(io);
    var request = engine.next() orelse return error.Unexpected;
    defer request.deinit();
    if (request.stream) |*stream| stream.close(io);
    try std.testing.expectEqualStrings("GET", request.method);
    try std.testing.expectEqualStrings("/fast", request.target);
}

test "受信engineは接続上限超過を拒否し上限内へ回復する" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const engine = try Engine.create(std.testing.allocator, &server, .{ .max_pending = 1 });
    defer {
        engine.stop();
        engine.destroy();
    }
    try engine.start();
    const port = server.socket.address.getPort();

    var first = try ingressTestSend(io, port, "POST /hold HTTP/1.1\r\nContent-Length: 10\r\n\r\nx", false);
    defer first.close(io);
    try ingressTestWait(engine, io, true);

    // 上限到達中の接続は503または無応答closeで拒否される。
    var rejected = try ingressTestConnect(io, port);
    defer rejected.close(io);
    var reject_buffer: [512]u8 = undefined;
    var reject_reader = rejected.reader(io, &reject_buffer);
    const reject_line = reject_reader.interface.takeDelimiter('\n') catch null;
    if (reject_line) |line| try std.testing.expect(std.mem.startsWith(u8, line, "HTTP/1.1 503"));

    // 先の接続がbodyを送り切るとqueueへ乗り、以後の接続は再び受け付く。
    var rest_buffer: [128]u8 = undefined;
    var rest_writer = first.writer(io, &rest_buffer);
    try rest_writer.interface.writeAll("xxxxxxxxx");
    try rest_writer.interface.flush();
    try first.shutdown(io, .send);
    var request = engine.next() orelse return error.Unexpected;
    defer request.deinit();
    if (request.stream) |*stream| stream.close(io);
    try std.testing.expectEqualStrings("POST", request.method);
    try std.testing.expectEqualStrings("/hold", request.target);
    try std.testing.expectEqualStrings("x" ** 10, request.body);

    var second = try ingressTestSend(io, port, "GET /again HTTP/1.1\r\n\r\n", true);
    defer second.close(io);
    var second_request = engine.next() orelse return error.Unexpected;
    defer second_request.deinit();
    if (second_request.stream) |*stream| stream.close(io);
    try std.testing.expectEqualStrings("GET", second_request.method);
    try std.testing.expectEqualStrings("/again", second_request.target);
}

test "受信engineは絶対期限切れの接続を閉じて他接続へ継続する" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const engine = try Engine.create(std.testing.allocator, &server, .{
        .receive_timeout_ns = 150 * std.time.ns_per_ms,
        .reap_interval_ns = 20 * std.time.ns_per_ms,
    });
    defer {
        engine.stop();
        engine.destroy();
    }
    try engine.start();
    const port = server.socket.address.getPort();

    // header未完のまま放置する接続は絶対期限でshutdown→closeされる。
    var expired = try ingressTestSend(io, port, "GET /expire HTTP/1.1\r\nHost: localhost\r\n", false);
    defer expired.close(io);
    try ingressTestExpectClosed(expired, io);

    var valid = try ingressTestSend(io, port, "GET /after HTTP/1.1\r\n\r\n", true);
    defer valid.close(io);
    var request = engine.next() orelse return error.Unexpected;
    defer request.deinit();
    if (request.stream) |*stream| stream.close(io);
    try std.testing.expectEqualStrings("/after", request.target);
}

test "受信engineのstopはqueue内socketを一度だけ閉じてworkerを回収する" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const engine = try Engine.create(std.testing.allocator, &server, .{});
    try engine.start();
    const port = server.socket.address.getPort();

    // 完了済みだがnext()で取り出されていない要求をqueueへ滞留させる。
    var queued = try ingressTestSend(io, port, "GET /queued HTTP/1.1\r\n\r\n", true);
    defer queued.close(io);
    try ingressTestWait(engine, io, false);
    // 受信中の接続も残す。
    var inflight = try ingressTestSend(io, port, "POST /held HTTP/1.1\r\nContent-Length: 10\r\n\r\n", false);
    defer inflight.close(io);

    engine.stop();
    try std.testing.expect(engine.next() == null);
    engine.destroy();
    // stopでqueue内socketは一度だけcloseされ、client側は切断を観測する。
    try ingressTestExpectClosed(queued, io);
    try ingressTestExpectClosed(inflight, io);
}
