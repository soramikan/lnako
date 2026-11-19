const std = @import("std");
const builtin = @import("builtin");
const state = @import("state.zig");
const shared = @import("shared.zig");
const http_ingress = @import("../../http_ingress.zig");

const aot_builtin = shared.aot_builtin;
const Runtime = state.Runtime;
const Value = state.Value;
const Object = state.Object;
const Tag = state.Tag;
const RootFrame = state.RootFrame;
const BigInt = state.BigInt;
const AotHttpRoute = state.AotHttpRoute;
const AotHttpHeader = state.AotHttpHeader;
const numberValue = state.numberValue;
const numberString = state.numberString;
const valueToNumber = state.valueToNumber;
const valueToNumberRuntime = state.valueToNumberRuntime;
const valueUtf8LossyAlloc = state.valueUtf8LossyAlloc;
const valueUtf16Alloc = state.valueUtf16Alloc;
const runtimeUtf8String = state.runtimeUtf8String;
const runtimeUtf8StringLossy = state.runtimeUtf8StringLossy;
const arrayAppendBuiltin = state.arrayAppendBuiltin;
const staticStringValue = state.staticStringValue;
const staticUtf8 = state.staticUtf8;
const dictionaryProperty = state.dictionaryProperty;
const currentTimeMilliseconds = state.currentTimeMilliseconds;
const writeBytes = state.writeBytes;
const fflush = state.fflush;
const jsonDecodeBuiltin = state.jsonDecodeBuiltin;
const nodeTemporaryDirectoryPrefixAlloc = state.nodeTemporaryDirectoryPrefixAlloc;
const AotHttpPathStat = state.AotHttpPathStat;
const resolveAotCallback = state.resolveAotCallback;
const invokeAotCallback = state.invokeAotCallback;

const AotHttpRequest = http_ingress.Request;

/// 応答保留の上限。Interpreter側`CliHost`の`max_held_http_connections`と
/// 同じ値に揃える。未登録URLや未応答ハンドラの接続を無制限に保持すると
/// fdを使い切ってacceptが枯渇するため、上限超過時は最古の接続を閉じる。
const max_held_http_connections: usize = 16;

const AotHttpChunkedBody = struct {
    body: []u8,
    too_large: bool,
};

pub fn isHttpServerCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .http_server_start, .http_server_static, .http_server_receive, .http_server_output, .http_server_headers, .http_server_redirect => true,
        else => false,
    };
}
pub fn aotHttpIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// listen socketのacceptと要求受信を接続単位のworkerへ分離するengineを起動する。
/// engineは専用std.Io.Threadedを所有し、global_single_threadedでは並行処理しない。
pub fn aotHttpIngressStart(runtime: *Runtime) !void {
    if (runtime.http_ingress != null) return error.HttpServerAlreadyStarted;
    const server = if (runtime.http_server) |*value| value else return error.HttpServerNotStarted;
    const engine = try http_ingress.Engine.create(std.heap.page_allocator, server, .{});
    errdefer engine.destroy();
    try engine.start();
    runtime.http_ingress = engine;
}

/// 受信engineを停止して破棄する。acceptor→watchdog→worker join→queue解放の順で、
/// 未完了・queue内のsocketを一度だけcloseする。応答中・保持中のsocketと
/// listen socketは呼び出し側が続けて閉じる。
pub fn aotHttpIngressStop(runtime: *Runtime) void {
    const engine = runtime.http_ingress orelse return;
    engine.stop();
    engine.destroy();
    runtime.http_ingress = null;
}

pub fn aotHttpDictionarySetUtf8(runtime: *Runtime, dictionary: Value, key: []const u8, value: Value) !void {
    var roots = [_]Value{ dictionary, value, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try runtimeUtf8String(runtime, key);
    try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[2], roots[1]);
}

pub fn httpServerBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    var frame = RootFrame{};
    if (arguments.len > 0) runtime.pushRoots(&frame, @constCast(arguments.ptr), arguments.len);
    defer if (arguments.len > 0) runtime.popRoots(&frame);

    switch (command) {
        .http_server_start => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            if (runtime.http_server_state.started) return error.HttpServerAlreadyStarted;
            const callback = try resolveAotCallback(runtime, arguments[0]);
            const port_number = try valueToNumberRuntime(runtime, arguments[1]);
            if (!std.math.isFinite(port_number) or port_number < 0 or port_number > 65535) return error.InvalidHttpServerPort;
            const port: u16 = @intFromFloat(@trunc(port_number));
            const address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(port) };
            runtime.http_server = try address.listen(aotHttpIo(), .{ .reuse_address = true });
            errdefer {
                runtime.http_server.?.deinit(aotHttpIo());
                runtime.http_server = null;
            }
            try aotHttpIngressStart(runtime);
            runtime.http_server_state.started = true;
            var message: [128]u8 = undefined;
            const line = try std.fmt.bufPrint(&message, "[簡易HTTPサーバ] ポート番号({d})で監視開始\n", .{runtime.http_server.?.socket.address.getPort()});
            aotHttpWrite(line);
            _ = try invokeAotCallback(runtime, callback, null, 0);
        },
        .http_server_static => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            try requireAotHttpStarted(runtime);
            const prefix = try aotHttpNormalizedPrefix(runtime, arguments[0]);
            errdefer runtime.allocator.free(prefix);
            const path = try valueUtf8LossyAlloc(runtime, arguments[1]);
            errdefer runtime.allocator.free(path);
            try runtime.http_server_state.routes.append(runtime.allocator, .{ .kind = .static, .prefix = prefix, .path = path });
        },
        .http_server_receive => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            try requireAotHttpStarted(runtime);
            const callback = try resolveAotCallback(runtime, arguments[0]);
            const prefix = try aotHttpNormalizedPrefix(runtime, arguments[1]);
            errdefer runtime.allocator.free(prefix);
            try runtime.http_server_state.routes.append(runtime.allocator, .{ .kind = .callback, .prefix = prefix, .callback = callback });
        },
        .http_server_headers => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            try requireAotHttpActive(runtime);
            const status_number = try valueToNumberRuntime(runtime, arguments[0]);
            if (!std.math.isFinite(status_number) or status_number < 100 or status_number > 999) return error.InvalidHttpStatus;
            runtime.http_server_state.response_status = @intFromFloat(@trunc(status_number));
            runtime.http_server_state.clearHeaders(runtime.allocator);
            const headers = arguments[1];
            if (headers.tag == @backingInt(Tag.dictionary)) {
                for (headers.object().?.payload.dictionary.entries.items) |entry| {
                    const name = try valueUtf8LossyAlloc(runtime, entry.key);
                    errdefer runtime.allocator.free(name);
                    const value = try valueUtf8LossyAlloc(runtime, entry.value);
                    errdefer runtime.allocator.free(value);
                    try runtime.http_server_state.response_headers.append(runtime.allocator, .{ .name = name, .value = value });
                }
            }
        },
        .http_server_output => {
            if (arguments.len < 1) return error.InvalidArgumentCount;
            try requireAotHttpActive(runtime);
            const body = try valueUtf8LossyAlloc(runtime, arguments[0]);
            defer runtime.allocator.free(body);
            if (runtime.http_server_state.response_headers.items.len == 0) {
                try aotHttpAppendHeader(runtime, "Content-Type", "text/html; charset=utf-8");
            }
            try aotHttpRespondSafe(runtime, body);
        },
        .http_server_redirect => {
            if (arguments.len < 1) return error.InvalidArgumentCount;
            try requireAotHttpActive(runtime);
            const url = try valueUtf8LossyAlloc(runtime, arguments[0]);
            defer runtime.allocator.free(url);
            runtime.http_server_state.response_status = 302;
            runtime.http_server_state.clearHeaders(runtime.allocator);
            try aotHttpAppendHeader(runtime, "Location", url);
            const body = try std.fmt.allocPrint(runtime.allocator, "<html><body><a href=\"{s}\">JUMP</a></body></html>", .{url});
            defer runtime.allocator.free(body);
            try aotHttpRespondSafe(runtime, body);
        },
        else => return error.UnknownCommand,
    }
    return .{};
}

pub fn requireAotHttpStarted(runtime: *Runtime) !void {
    if (!runtime.http_server_state.started or runtime.http_server == null) return error.HttpServerNotStarted;
}

pub fn requireAotHttpActive(runtime: *Runtime) !void {
    try requireAotHttpStarted(runtime);
    if (!runtime.http_server_state.request_active or runtime.http_connection == null) return error.HttpServerResponseOutsideRequest;
}

pub fn aotHttpNormalizedPrefix(runtime: *Runtime, value: Value) ![]u8 {
    const source = try valueUtf8LossyAlloc(runtime, value);
    defer runtime.allocator.free(source);
    if (source.len == 0) return runtime.allocator.dupe(u8, "/");
    if (source[0] == '/') return runtime.allocator.dupe(u8, source);
    return std.fmt.allocPrint(runtime.allocator, "/{s}", .{source});
}

pub fn aotHttpAppendHeader(runtime: *Runtime, name: []const u8, value: []const u8) !void {
    const owned_name = try runtime.allocator.dupe(u8, name);
    errdefer runtime.allocator.free(owned_name);
    const owned_value = try runtime.allocator.dupe(u8, value);
    errdefer runtime.allocator.free(owned_value);
    try runtime.http_server_state.response_headers.append(runtime.allocator, .{ .name = owned_name, .value = owned_value });
}

pub fn aotHttpRespond(runtime: *Runtime, body: []const u8) !void {
    const stream = runtime.http_connection orelse return error.HttpServerResponseOutsideRequest;
    const io = aotHttpIo();
    defer {
        stream.close(io);
        resetAotHttpConnection(runtime);
    }
    var buffer: [16 * 1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.print("HTTP/1.1 {d} {s}\r\n", .{ runtime.http_server_state.response_status, aotHttpStatusPhrase(runtime.http_server_state.response_status) }) catch |err| return mapAotHttpWriteError(&writer, err);
    var has_content_length = false;
    for (runtime.http_server_state.response_headers.items) |header| {
        if (header.name.len == 0 or std.mem.indexOfAny(u8, header.name, "\r\n\x00") != null or std.mem.indexOfAny(u8, header.value, "\r\n\x00") != null) return error.InvalidHttpHeader;
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) has_content_length = true;
        writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value }) catch |err| return mapAotHttpWriteError(&writer, err);
    }
    if (!has_content_length) writer.interface.print("Content-Length: {d}\r\n", .{body.len}) catch |err| return mapAotHttpWriteError(&writer, err);
    writer.interface.writeAll("Connection: close\r\n\r\n") catch |err| return mapAotHttpWriteError(&writer, err);
    if (!runtime.http_head_request) writer.interface.writeAll(body) catch |err| return mapAotHttpWriteError(&writer, err);
    writer.interface.flush() catch |err| return mapAotHttpWriteError(&writer, err);
}

pub fn aotHttpRespondSafe(runtime: *Runtime, body: []const u8) !void {
    aotHttpRespond(runtime, body) catch |err| {
        if (isAotHttpRecoverableConnectionError(err)) return;
        return err;
    };
}

fn mapAotHttpWriteError(writer: *std.Io.net.Stream.Writer, err: anyerror) anyerror {
    if (err != error.WriteFailed) return err;
    return switch (writer.err orelse error.WriteFailed) {
        error.ConnectionResetByPeer,
        error.SocketUnconnected,
        => error.HttpServerClientDisconnected,
        else => |underlying| underlying,
    };
}

fn isAotHttpRecoverableConnectionError(err: anyerror) bool {
    return switch (err) {
        error.HttpServerClientDisconnected,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        error.Timeout,
        error.ConnectionTimedOut,
        error.SocketUnconnected,
        error.BrokenPipe,
        => true,
        else => false,
    };
}

fn resetAotHttpConnection(runtime: *Runtime) void {
    runtime.http_connection = null;
    runtime.http_head_request = false;
    runtime.http_server_state.request_active = false;
}

pub fn aotHttpHold(runtime: *Runtime) !void {
    const stream = runtime.http_connection orelse return error.HttpServerResponseOutsideRequest;
    const io = aotHttpIo();
    // Interpreter側`holdHttpServerResponse`と同じく、保持数が上限に達して
    // いたら最古の接続を閉じて回収する。閉じた接続は`orderedRemove`で保持
    // 対象から外れるため、deinitで二重にcloseしない。
    while (runtime.held_http_connections.items.len >= max_held_http_connections) {
        runtime.held_http_connections.orderedRemove(0).close(io);
    }
    try runtime.held_http_connections.append(runtime.allocator, stream);
    resetAotHttpConnection(runtime);
}

pub fn aotHttpWrite(bytes: []const u8) void {
    writeBytes(bytes, false);
    _ = fflush(null);
}

pub fn aotHttpStatusPhrase(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "",
    };
}

pub fn pollAotHttpServer(runtime: *Runtime) !bool {
    if (!runtime.http_server_state.started) return false;
    var request = aotHttpReceiveRequest(runtime) catch |err| {
        if (isAotHttpRecoverableReceiveError(err)) {
            resetAotHttpConnection(runtime);
            return true;
        }
        return err;
    };
    defer request.deinit();
    if (request.too_large) {
        runtime.http_server_state.response_status = 413;
        runtime.http_server_state.clearHeaders(runtime.allocator);
        try aotHttpRespondSafe(runtime, "Request entity too large.");
        return true;
    }
    // メソッドはクライアントが自由に書ける要求行の先頭トークン。UTF-8でない
    // バイト列をそのまま`HTTPメソッド`へ載せると要求処理が失敗し、1件の要求が
    // プロセス全体のエラーになってしまうため、ここで400として捨てる。
    if (!std.unicode.utf8ValidateSlice(request.method)) return aotHttpReject(runtime, 400);

    var message: [256]u8 = undefined;
    const log = try std.fmt.bufPrint(&message, "[簡易HTTPサーバ] 要求あり METHOD={s} URL={s}\n", .{ request.method, request.target });
    aotHttpWrite(log);

    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    // 受信後の要求処理エラー（不正なquery・静的パス、アップロード保存の
    // 失敗）はhandleAotHttpRequest内の各処理箇所が1回だけ応答して要求を捨て、
    // プロセスを終了させない。ハンドラ（利用者プログラム）の実行エラーは
    // 握りつぶさず、イベントループの呼び出し元へ伝播させる。
    return handleAotHttpRequest(runtime, &request, &roots);
}

/// 受信済み要求の解析・配送。クライアント起因の失敗は`aotHttpReject`で
/// 400にして捨てる（Interpreter側`poll`と同じ分類）。
fn handleAotHttpRequest(runtime: *Runtime, request: *const AotHttpRequest, roots: *[4]Value) !bool {
    roots[0] = aotHttpParseQuery(runtime, request.target) catch |err| switch (err) {
        error.InvalidHttpQueryEncoding => return aotHttpReject(runtime, 400),
        else => return err,
    };
    roots[1] = try runtime.createArray(&.{});
    // multipartのアップロードは要求スコープの一時ファイル。ハンドラの成否や
    // 応答の有無に関わらず、要求の処理が終わった時点で回収する（Interpreter側
    // pollのdeferと同じ寿命）。
    defer aotHttpDeleteUploads(runtime, roots[1]);
    roots[2] = try runtime.createDictionary(&.{});
    const path = aotHttpPathOnly(request.target);
    const route = aotHttpBestRoute(runtime.http_server_state.routes.items, path) orelse {
        // 本文の解析（multipartのアップロード永続化を含む）は配送先が
        // 決まった要求だけで行う。未登録URLのPOSTで一時ファイルを残さない。
        roots[3] = try runtimeUtf8String(runtime, request.method);
        aotHttpSetRequestGlobals(runtime, roots);
        try aotHttpHold(runtime);
        return true;
    };
    if (std.ascii.eqlIgnoreCase(request.method, "POST")) {
        roots[2] = aotHttpParsePost(runtime, request.content_type, request.body, roots[1]) catch |err| {
            if (err == error.OutOfMemory) return err;
            // 本文の解析失敗は保存先の障害を含むため500で返す。
            return aotHttpReject(runtime, 500);
        };
    }
    roots[3] = try runtimeUtf8String(runtime, request.method);
    aotHttpSetRequestGlobals(runtime, roots);
    if (route.kind == .static) {
        // 静的配信の失敗（読み取り・ヘッダ生成）は1件の要求の500に閉じる。
        aotHttpServeStatic(runtime, route, path) catch |err| {
            if (err == error.OutOfMemory) return err;
            return aotHttpReject(runtime, 500);
        };
        return true;
    }
    runtime.http_server_state.request_active = true;
    runtime.http_server_state.response_status = 200;
    runtime.http_server_state.clearHeaders(runtime.allocator);
    if (route.callback.tag != @backingInt(Tag.function)) return error.HttpServerCallbackNotCallable;
    _ = try invokeAotCallback(runtime, route.callback, null, 0);
    if (runtime.http_server_state.request_active) {
        try aotHttpHold(runtime);
        runtime.http_server_state.request_active = false;
    }
    return true;
}

fn aotHttpSetRequestGlobals(runtime: *Runtime, roots: *const [4]Value) void {
    if (runtime.http_globals) |globals| {
        if (globals.method) |pointer| pointer.* = roots[3];
        if (globals.get_data) |pointer| pointer.* = roots[0];
        if (globals.post_data) |pointer| pointer.* = roots[2];
        if (globals.files_data) |pointer| pointer.* = roots[1];
    }
}

/// 受信後の要求処理で起きた失敗は1回だけ応答して捨てる。
fn aotHttpReject(runtime: *Runtime, status: u16) !bool {
    try aotHttpRespondWith(runtime, status, &.{}, if (status >= 500) aot_http_internal_error_body else aot_http_bad_request_body);
    return true;
}

const aot_http_bad_request_body = "<html><meta charset=\"utf-8\"><body><h1>400 要求が不正です。</h1></body></html>";
const aot_http_internal_error_body = "<html><meta charset=\"utf-8\"><body><h1>500 サーバ内部エラーです。</h1></body></html>";
const aot_http_not_found_body = "<html><meta charset=\"utf-8\"><body><h1>404 見当たりません。</h1></body></html>";
const aot_http_static_too_large_body = "<html><meta charset=\"utf-8\"><body><h1>413 要求が大きすぎます。</h1></body></html>";

/// 受信完了した要求をengineのqueueから取り出す。header/body受信自体は
/// 接続単位のworker threadが担うため、低速・切断した接続はこのloopを
/// 停滞させない。
pub fn aotHttpReceiveRequest(runtime: *Runtime) !AotHttpRequest {
    if (runtime.http_server == null) return error.HttpServerNotStarted;
    if (runtime.http_connection != null) return error.PreviousHttpResponseNotFinished;
    const engine = runtime.http_ingress orelse return error.HttpServerNotStarted;
    const received = engine.next() orelse return error.HttpServerStopped;
    runtime.http_connection = received.stream orelse {
        var broken = received;
        broken.deinit();
        return error.InvalidHttpRequest;
    };
    runtime.http_head_request = received.head_request;
    return received;
}

fn isAotHttpRecoverableReceiveError(err: anyerror) bool {
    return switch (err) {
        error.HttpServerClientDisconnected,
        error.InvalidHttpRequest,
        error.InvalidHttpHeader,
        error.InvalidHttpChunk,
        error.EndOfStream,
        error.StreamTooLong,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        error.Timeout,
        error.SocketUnconnected,
        error.BrokenPipe,
        => true,
        else => false,
    };
}

pub fn aotHttpReadChunkedBody(allocator: std.mem.Allocator, reader: *std.Io.Reader, maximum_size: usize) !AotHttpChunkedBody {
    const chunked = try http_ingress.readChunkedBody(allocator, reader, maximum_size);
    return .{ .body = chunked.body, .too_large = chunked.too_large };
}

pub fn aotHttpPathOnly(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

pub fn aotHttpBestRoute(routes: []const AotHttpRoute, path: []const u8) ?AotHttpRoute {
    var result: ?AotHttpRoute = null;
    for (routes) |route| {
        if (!std.mem.startsWith(u8, path, route.prefix)) continue;
        if (result == null or route.prefix.len > result.?.prefix.len) result = route;
    }
    return result;
}

pub fn aotHttpParseQuery(runtime: *Runtime, target: []const u8) !Value {
    var roots = [_]Value{ try runtime.createDictionary(&.{}), .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try aotHttpDictionarySetUtf8(runtime, roots[0], "?URL", try runtimeUtf8String(runtime, aotHttpPathOnly(target)));
    const marker = std.mem.indexOfScalar(u8, target, '?') orelse return roots[0];
    const query_source = target[marker + 1 ..];
    const query_end = std.mem.indexOfScalar(u8, query_source, '?') orelse query_source.len;
    var pairs = std.mem.splitScalar(u8, query_source[0..query_end], '&');
    while (pairs.next()) |pair| {
        const equal = std.mem.indexOfScalar(u8, pair, '=');
        const key = try aotHttpPercentDecode(runtime.allocator, if (equal) |index| pair[0..index] else pair, false, true);
        defer runtime.allocator.free(key);
        const value_source = if (equal) |index| blk: {
            const rest = pair[index + 1 ..];
            break :blk rest[0 .. std.mem.indexOfScalar(u8, rest, '=') orelse rest.len];
        } else "undefined";
        const decoded_value = try aotHttpPercentDecode(runtime.allocator, value_source, false, true);
        defer runtime.allocator.free(decoded_value);
        roots[1] = try runtimeUtf8StringLossy(runtime, key);
        roots[2] = try runtimeUtf8StringLossy(runtime, decoded_value);
        try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
    }
    return roots[0];
}

pub fn aotHttpParsePost(runtime: *Runtime, content_type: []const u8, body: []const u8, files: Value) !Value {
    if (std.mem.indexOf(u8, content_type, "multipart/form-data") != null) {
        const boundary = aotHttpMultipartBoundary(content_type) orelse return runtime.createDictionary(&.{});
        return aotHttpParseMultipart(runtime, body, boundary, files);
    }
    if (std.ascii.findIgnoreCase(content_type, "application/json") != null) {
        var source = try runtimeUtf8StringLossy(runtime, body);
        var frame = RootFrame{};
        runtime.pushRoots(&frame, @ptrCast(&source), 1);
        defer runtime.popRoots(&frame);
        return jsonDecodeBuiltin(runtime, source) catch source;
    }
    if (std.ascii.findIgnoreCase(content_type, "application/x-www-form-urlencoded") != null) return aotHttpParseUrlEncoded(runtime, body);
    return runtimeUtf8StringLossy(runtime, body);
}

pub fn aotHttpMultipartBoundary(content_type: []const u8) ?[]const u8 {
    var search_start: usize = 0;
    while (search_start <= content_type.len) {
        const relative_marker = std.mem.indexOf(u8, content_type[search_start..], "boundary=") orelse return null;
        const marker = search_start + relative_marker;
        const value_start = marker + "boundary=".len;

        if (value_start < content_type.len and content_type[value_start] == '"') {
            if (std.mem.indexOfScalarPos(u8, content_type, value_start + 1, '"')) |quote| {
                if (quote > value_start + 1) return std.mem.trim(u8, content_type[value_start + 1 .. quote], " \t\r\n");
            }
        }

        var value_end = value_start;
        while (value_end < content_type.len and content_type[value_end] != ';') value_end += 1;
        if (value_end > value_start) return std.mem.trim(u8, content_type[value_start..value_end], " \t\r\n");
        search_start = marker + 1;
    }
    return null;
}

pub fn aotHttpParseUrlEncoded(runtime: *Runtime, body: []const u8) !Value {
    var roots = [_]Value{ try runtime.createDictionary(&.{}), .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const equal = std.mem.indexOfScalar(u8, pair, '=');
        const key = try aotHttpPercentDecode(runtime.allocator, if (equal) |index| pair[0..index] else pair, true, false);
        defer runtime.allocator.free(key);
        const decoded_value = try aotHttpPercentDecode(runtime.allocator, if (equal) |index| pair[index + 1 ..] else "", true, false);
        defer runtime.allocator.free(decoded_value);
        roots[1] = try runtimeUtf8StringLossy(runtime, key);
        roots[2] = try runtimeUtf8StringLossy(runtime, decoded_value);
        try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
    }
    return roots[0];
}

pub fn aotHttpParseMultipart(runtime: *Runtime, body: []const u8, boundary: []const u8, files: Value) !Value {
    var roots = [_]Value{ try runtime.createDictionary(&.{}), files, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const delimiter = try std.fmt.allocPrint(runtime.allocator, "--{s}", .{boundary});
    defer runtime.allocator.free(delimiter);
    var parts = std.mem.splitSequence(u8, body, delimiter);
    while (parts.next()) |raw_part| {
        var part = raw_part;
        if (std.mem.startsWith(u8, part, "\r\n")) part = part[2..] else if (std.mem.startsWith(u8, part, "\n")) part = part[1..];
        if (std.mem.endsWith(u8, part, "\r\n")) part = part[0 .. part.len - 2] else if (std.mem.endsWith(u8, part, "\n")) part = part[0 .. part.len - 1];
        if (part.len == 0 or std.mem.eql(u8, part, "--")) continue;
        const crlf_separator = std.mem.indexOf(u8, part, "\r\n\r\n");
        const separator = crlf_separator orelse std.mem.indexOf(u8, part, "\n\n") orelse continue;
        const separator_length: usize = if (crlf_separator != null) 4 else 2;
        const head = part[0..separator];
        part = part[separator + separator_length ..];
        const disposition = aotHttpFindHeader(head, "content-disposition") orelse continue;
        const field_name = aotHttpDispositionParameter(disposition, "name") orelse continue;
        if (aotHttpDispositionParameter(disposition, "filename")) |filename| {
            const content_type = aotHttpFindHeader(head, "content-type") orelse "application/octet-stream";
            const path = try aotHttpSaveUpload(runtime, filename, part);
            defer runtime.allocator.free(path);
            // FILESへ載る前の失敗（不正UTF-8のフィールド名など）では
            // `aotHttpDeleteUploads`の走査対象にならず一時ファイルが残るため、
            // 保存直後からこのスコープのerror経路で削除する。
            errdefer std.Io.Dir.cwd().deleteFile(aotHttpIo(), path) catch {};
            roots[2] = try runtime.createDictionary(&.{});
            try aotHttpDictionarySetUtf8(runtime, roots[2], "fieldName", try runtimeUtf8String(runtime, field_name));
            try aotHttpDictionarySetUtf8(runtime, roots[2], "name", try runtimeUtf8String(runtime, filename));
            try aotHttpDictionarySetUtf8(runtime, roots[2], "path", try runtimeUtf8String(runtime, path));
            try aotHttpDictionarySetUtf8(runtime, roots[2], "size", numberValue(@floatFromInt(part.len)));
            try aotHttpDictionarySetUtf8(runtime, roots[2], "type", try runtimeUtf8String(runtime, content_type));
            try roots[1].object().?.payload.array.append(runtime.allocator, roots[2]);
        } else {
            try aotHttpDictionarySetUtf8(runtime, roots[0], field_name, try runtimeUtf8StringLossy(runtime, part));
        }
    }
    return roots[0];
}

pub fn aotHttpFindHeader(head: []const u8, expected: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (std.mem.endsWith(u8, line, "\r")) line = line[0 .. line.len - 1];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), expected)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

pub fn aotHttpDispositionParameter(disposition: []const u8, expected: []const u8) ?[]const u8 {
    var search_start: usize = 0;
    while (search_start <= disposition.len) {
        const relative_marker = std.mem.indexOf(u8, disposition[search_start..], expected) orelse return null;
        const marker = search_start + relative_marker;
        const value_start = marker + expected.len;
        if (value_start + 2 < disposition.len and disposition[value_start] == '=' and disposition[value_start + 1] == '"') {
            if (std.mem.indexOfScalarPos(u8, disposition, value_start + 2, '"')) |quote| {
                if (quote > value_start + 2) return disposition[value_start + 2 .. quote];
            }
        }
        search_start = marker + 1;
    }
    return null;
}

pub fn aotHttpPercentDecode(allocator: std.mem.Allocator, source: []const u8, plus_as_space: bool, strict: bool) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '%' and index + 2 < source.len) {
            const byte = std.fmt.parseInt(u8, source[index + 1 .. index + 3], 16) catch {
                if (strict) return error.InvalidHttpQueryEncoding;
                try result.append(allocator, source[index]);
                index += 1;
                continue;
            };
            try result.append(allocator, byte);
            index += 3;
        } else {
            if (strict and source[index] == '%') return error.InvalidHttpQueryEncoding;
            try result.append(allocator, if (plus_as_space and source[index] == '+') ' ' else source[index]);
            index += 1;
        }
    }
    const decoded = try result.toOwnedSlice(allocator);
    if (strict and !std.unicode.utf8ValidateSlice(decoded)) {
        allocator.free(decoded);
        return error.InvalidHttpQueryEncoding;
    }
    return decoded;
}

/// 静的配信で開いたファイル。`name`はContent-Type判定に使う相対名で、
/// `aotHttpServeStatic`の`sanitized`か静的リテラルを指す（所有しない）。
const AotHttpStaticFile = struct {
    file: std.Io.File,
    name: []const u8,
};

const aot_http_static_max_bytes = 1024 * 1024 * 1024;

pub fn aotHttpServeStatic(runtime: *Runtime, route: AotHttpRoute, path: []const u8) !void {
    const io = aotHttpIo();
    const relative_raw = path[@min(route.prefix.len, path.len)..];
    const sanitized = try aotHttpRemoveParentSegments(runtime.allocator, relative_raw);
    defer runtime.allocator.free(sanitized);
    // docrootと配信対象を`realPathFileAlloc`で照合した後、解決済みの文字列を
    // 開き直すと、照合とopenの間に中間ディレクトリをsymlinkへ差し替えられて
    // docroot外を読む（TOCTOU）。ここではdocrootのディレクトリハンドルを
    // 起点に各成分を`symlink非追従`で1段ずつ辿り、開いたfdから読む。
    var opened = (try aotHttpOpenStaticFile(io, route.path, sanitized)) orelse
        return aotHttpRespondWith(runtime, 404, &.{}, aot_http_not_found_body);
    defer opened.file.close(io);
    const body = aotHttpReadStaticFile(io, opened.file, runtime.allocator) catch |err| {
        const status = aotHttpStaticReadErrorStatus(err) orelse return err;
        return aotHttpRespondWith(runtime, status, &.{}, switch (status) {
            404 => aot_http_not_found_body,
            413 => aot_http_static_too_large_body,
            else => aot_http_internal_error_body,
        });
    };
    defer runtime.allocator.free(body);
    const saved_status = runtime.http_server_state.response_status;
    runtime.http_server_state.response_status = 200;
    runtime.http_server_state.clearHeaders(runtime.allocator);
    try aotHttpAppendHeader(runtime, "Content-Type", aotHttpMimeType(opened.name));
    defer runtime.http_server_state.response_status = saved_status;
    return aotHttpRespondSafe(runtime, body);
}

/// docroot配下の静的配信対象を堅牢に開く。
///
/// `std.Io.Dir.openDir`/`openFile`の`follow_symlinks = false`は、POSIXでは
/// `O_NOFOLLOW`、Windowsでは`FILE_OPEN_REPARSE_POINT`に対応する。ただし
/// いずれも指定したパスの最終成分だけが対象なので、多段パスを一度に渡すと
/// 中間成分のsymlinkを辿ってしまう。そのため1成分ずつ親ハンドルからの相対で
/// 開く。各openは既に開いたハンドルを起点に解決されるため、途中で名前を
/// 差し替えられても開いたハンドルの外へは移動しない。
///
/// Windowsの`OPEN_REPARSE_POINT`はreparse point自体のハンドルを返すことが
/// あり、そこからの相対openがlink先へ解決されうる。開いた後に対象の実体が
/// 通常のディレクトリ／ファイルであることを`stat`で確認し、symlinkや
/// reparse point（`unknown`）は配信しない（fail closed）。
fn aotHttpOpenStaticFile(io: std.Io, docroot: []const u8, relative: []const u8) !?AotHttpStaticFile {
    var directory = std.Io.Dir.cwd().openDir(io, docroot, .{}) catch |err| return if (aotHttpIsStaticPathMiss(err)) null else err;
    defer directory.close(io);

    var components: AotHttpStaticPathIterator = .{ .path = relative };
    const first = components.next() orelse return aotHttpOpenIndexFile(io, directory);
    if (!aotHttpValidStaticComponent(first)) return null;
    var component = first;
    while (components.next()) |next_component| {
        if (!aotHttpValidStaticComponent(next_component)) return null;
        const child = try aotHttpOpenChildDirectory(io, directory, component) orelse return null;
        directory.close(io);
        directory = child;
        component = next_component;
    }
    return aotHttpOpenStaticTarget(io, directory, component);
}

/// 最終成分を開く。ディレクトリなら従来どおり`index.html`を配信する。
fn aotHttpOpenStaticTarget(io: std.Io, directory: std.Io.Dir, component: []const u8) !?AotHttpStaticFile {
    // 通常ファイル以外（FIFO・socket・device・symlink）は開かない。特にFIFOは
    // 読み取りopenが書き手待ちで停止するため、open前にkindを確認する。
    const stat = directory.statFile(io, component, .{ .follow_symlinks = false }) catch |err| return if (aotHttpIsStaticPathMiss(err)) null else err;
    if (stat.kind == .directory) {
        const child = try aotHttpOpenChildDirectory(io, directory, component) orelse return null;
        defer child.close(io);
        return aotHttpOpenIndexFile(io, child);
    }
    if (stat.kind != .file) return null;
    const file = directory.openFile(io, component, .{ .follow_symlinks = false, .allow_directory = false }) catch |err| return if (aotHttpIsStaticPathMiss(err)) null else err;
    return aotHttpRequireRegularStaticFile(io, file, component);
}

/// `directory/index.html`を開く。docroot直下と、ディレクトリ指定の両方で使う。
fn aotHttpOpenIndexFile(io: std.Io, directory: std.Io.Dir) !?AotHttpStaticFile {
    const file = directory.openFile(io, "index.html", .{ .follow_symlinks = false, .allow_directory = false }) catch |err| return if (aotHttpIsStaticPathMiss(err)) null else err;
    return aotHttpRequireRegularStaticFile(io, file, "index.html");
}

/// 開いたファイルが通常ファイルであることをfdから確認する。所有権は常に
/// この関数が引き取り、失敗時はcloseしてnull/エラーを返す。
fn aotHttpRequireRegularStaticFile(io: std.Io, file: std.Io.File, name: []const u8) !?AotHttpStaticFile {
    const stat = file.stat(io) catch |err| {
        file.close(io);
        return err;
    };
    if (stat.kind != .file) {
        file.close(io);
        return null;
    }
    return .{ .file = file, .name = name };
}

/// 中間ディレクトリを1成分だけ、symlinkを辿らずに開く。
fn aotHttpOpenChildDirectory(io: std.Io, parent: std.Io.Dir, component: []const u8) !?std.Io.Dir {
    const child = parent.openDir(io, component, .{ .follow_symlinks = false }) catch |err| return if (aotHttpIsStaticPathMiss(err)) null else err;
    const stat = child.stat(io) catch |err| {
        child.close(io);
        return err;
    };
    if (stat.kind != .directory) {
        child.close(io);
        return null;
    }
    return child;
}

fn aotHttpReadStaticFile(io: std.Io, file: std.Io.File, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(aot_http_static_max_bytes));
}

/// 経路が存在しない／配信対象でない（クライアント起因）エラーを404にする。
/// 権限やデバイス等のホスト側障害は404に隠さず、要求1件の500として伝播させる
/// （Interpreter側`serveStatic`の分類に合わせる）。
fn aotHttpIsStaticPathMiss(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.IsDir,
        // POSIXのO_NOFOLLOW / WindowsのOPEN_REPARSE_POINTがsymlinkを検出した場合。
        error.SymLinkLoop,
        error.BadPathName,
        error.NameTooLong,
        error.NetworkNotFound,
        => true,
        else => false,
    };
}

/// 静的配信の読み込みI/Oエラーを要求スコープのstatusへ分類する。
/// 解決後に消えた・種別が変わったファイルは404、容量超過は413、
/// 権限等のホスト側障害は500。OOMだけは伝播させる（null）。
fn aotHttpStaticReadErrorStatus(err: anyerror) ?u16 {
    return switch (err) {
        error.OutOfMemory => null,
        error.StreamTooLong => 413,
        error.FileNotFound, error.NotDir, error.IsDir => 404,
        else => 500,
    };
}

const AotHttpStaticPathIterator = struct {
    path: []const u8,
    index: usize = 0,

    fn next(self: *AotHttpStaticPathIterator) ?[]const u8 {
        while (self.index < self.path.len) {
            while (self.index < self.path.len and aotHttpIsStaticPathSeparator(self.path[self.index])) self.index += 1;
            if (self.index == self.path.len) return null;
            const start = self.index;
            while (self.index < self.path.len and !aotHttpIsStaticPathSeparator(self.path[self.index])) self.index += 1;
            const component = self.path[start..self.index];
            // `.`は現在のディレクトリなので無視する（従来のパス解決と同じ）。
            if (std.mem.eql(u8, component, ".")) continue;
            return component;
        }
        return null;
    }
};

fn aotHttpIsStaticPathSeparator(byte: u8) bool {
    if (byte == '/') return true;
    // Windowsでは`\`も区切り。成分へ分割しないと`openDir`が多段パスとして
    // 中間のsymlinkを辿ってしまう。
    return switch (builtin.os.tag) {
        .windows => byte == '\\',
        else => false,
    };
}

fn aotHttpValidStaticComponent(component: []const u8) bool {
    if (component.len == 0) return false;
    if (std.mem.eql(u8, component, "..")) return false;
    if (std.mem.indexOfScalar(u8, component, 0) != null) return false;
    if (builtin.os.tag == .windows) {
        // `C:`等のドライブ指定は親ハンドルからの相対解決を迂回しうるため拒否する。
        // Windowsのファイル名に`:`は使えないので既存の配信対象は失われない。
        if (std.mem.indexOfScalar(u8, component, ':') != null) return false;
    }
    return true;
}

pub fn aotHttpRespondWith(runtime: *Runtime, status: u16, headers: []const AotHttpHeader, body: []const u8) !void {
    const saved_status = runtime.http_server_state.response_status;
    runtime.http_server_state.response_status = status;
    runtime.http_server_state.clearHeaders(runtime.allocator);
    for (headers) |header| {
        try aotHttpAppendHeader(runtime, header.name, header.value);
    }
    defer runtime.http_server_state.response_status = saved_status;
    return aotHttpRespondSafe(runtime, body);
}

pub fn aotHttpRemoveParentSegments(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) {
        if (index + 1 < source.len and source[index] == '.' and source[index + 1] == '.') {
            index += 2;
            continue;
        }
        try result.append(allocator, source[index]);
        index += 1;
    }
    return result.toOwnedSlice(allocator);
}

fn aotHttpIsMissingStaticPath(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir, error.SymLinkLoop, error.NameTooLong, error.BadPathName => true,
        else => false,
    };
}

pub fn aotHttpStatPath(path: []const u8) !AotHttpPathStat {
    const stat = std.Io.Dir.cwd().statFile(aotHttpIo(), path, .{}) catch |err| {
        // 存在しない・種別違い・解決不能はmissing（404）。権限等の
        // ホスト側障害は呼び出し元の500へ伝播させる。
        if (!aotHttpIsMissingStaticPath(err)) return err;
        return .missing;
    };
    return switch (stat.kind) {
        .file => .file,
        .directory => .directory,
        else => .missing,
    };
}

pub fn aotHttpMimeType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".html")) return "text/html";
    if (std.ascii.eqlIgnoreCase(extension, ".css")) return "text/css";
    if (std.ascii.eqlIgnoreCase(extension, ".js") or std.ascii.eqlIgnoreCase(extension, ".mjs")) return "text/javascript";
    if (std.ascii.eqlIgnoreCase(extension, ".nako3")) return "text/nadesiko3";
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".svg")) return "svg+xml";
    return "text/plain";
}

/// 要求で保存したアップロード一時ファイルを回収する。FILESデータの`path`は
/// 応答後も値としては残るが、ファイル自体は要求スコープで消える。
fn aotHttpDeleteUploads(runtime: *Runtime, files: Value) void {
    if (files.tag != @backingInt(Tag.array)) return;
    for (files.object().?.payload.array.items) |file| {
        if (file.tag != @backingInt(Tag.dictionary)) continue;
        const path_value = aotHttpDictionaryGetUtf8(runtime, file.object().?.payload.dictionary.entries.items, "path") orelse continue;
        const path = valueUtf8LossyAlloc(runtime, path_value) catch continue;
        defer runtime.allocator.free(path);
        // 回収の失敗（既に消えている等）で要求を失敗させない。
        std.Io.Dir.cwd().deleteFile(aotHttpIo(), path) catch {};
    }
}

fn aotHttpDictionaryGetUtf8(runtime: *Runtime, entries: []const state.DictionaryEntry, expected: []const u8) ?Value {
    for (entries) |entry| {
        const key = valueUtf8LossyAlloc(runtime, entry.key) catch continue;
        defer runtime.allocator.free(key);
        if (std.mem.eql(u8, key, expected)) return entry.value;
    }
    return null;
}

pub fn aotHttpSaveUpload(runtime: *Runtime, filename: []const u8, body: []const u8) ![]u8 {
    const prefix = try nodeTemporaryDirectoryPrefixAlloc(runtime);
    defer runtime.allocator.free(prefix);
    const upload_directory = try std.fs.path.join(runtime.allocator, &.{ prefix, "nako3-plugin_httpserver_upload" });
    defer runtime.allocator.free(upload_directory);
    try std.Io.Dir.cwd().createDirPath(aotHttpIo(), upload_directory);
    const safe_name = aotHttpUploadBasename(filename);
    const unique_name = try std.fmt.allocPrint(runtime.allocator, "{d}_{d}_{s}", .{ currentTimeMilliseconds(runtime), runtime.upload_sequence, safe_name });
    defer runtime.allocator.free(unique_name);
    runtime.upload_sequence +%= 1;
    const path = try std.fs.path.join(runtime.allocator, &.{ upload_directory, unique_name });
    errdefer runtime.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(aotHttpIo(), .{ .sub_path = path, .data = body });
    return path;
}

pub fn aotHttpUploadBasename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '/' or byte == '\\') start = index + 1;
    }
    return path[start..];
}

fn aotHttpTestSendRequest(io: std.Io, port: u16, request: []const u8) !std.Io.net.Stream {
    var client = try aotHttpTestSendBytes(io, port, request);
    errdefer client.close(io);
    try client.shutdown(io, .send);
    return client;
}

fn aotHttpTestSendBytes(io: std.Io, port: u16, bytes: []const u8) !std.Io.net.Stream {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var client = try address.connect(io, .{ .mode = .stream });
    errdefer client.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = client.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    return client;
}

const AotHttpClientProbe = enum { eof, open, data };

const AfdPollHandleInfo = extern struct {
    handle: std.os.windows.HANDLE,
    events: u32,
    status: std.os.windows.NTSTATUS,
};
const AfdPollInfo = extern struct {
    timeout: std.os.windows.LARGE_INTEGER,
    number_of_handles: u32,
    exclusive: u32,
    handles: [1]AfdPollHandleInfo,
};
const afd_poll_receive: u32 = 0x0001;
const afd_poll_disconnect: u32 = 0x0008;
const afd_poll_abort: u32 = 0x0010;
const afd_poll_relevant_events = afd_poll_receive | afd_poll_disconnect | afd_poll_abort;
const AfdPollInterpretation = enum { open, ready };

/// AFD_POLLの出力をOS非依存で解釈する。Linuxの単体テストからも直接呼べる。
fn interpretAfdPollOutput(
    ioctl_status: std.os.windows.NTSTATUS,
    information: usize,
    output: *const AfdPollInfo,
    expected_handle: std.os.windows.HANDLE,
) !AfdPollInterpretation {
    switch (ioctl_status) {
        .SUCCESS => {},
        .TIMEOUT => return .open,
        else => |status| return std.os.windows.unexpectedStatus(status),
    }
    // ヘッダー未満（0を含む）は出力なしとみなさず不正出力にする。
    if (information < @offsetOf(AfdPollInfo, "handles")) return error.InvalidAfdPollOutput;
    if (output.number_of_handles == 0) return .open;
    if (output.number_of_handles != 1) return error.InvalidAfdPollOutput;
    if (information < @sizeOf(AfdPollInfo)) return error.InvalidAfdPollOutput;
    if (output.handles[0].handle != expected_handle) return error.InvalidAfdPollOutput;
    switch (output.handles[0].status) {
        .SUCCESS => {},
        .TIMEOUT => return .open,
        else => |status| return std.os.windows.unexpectedStatus(status),
    }
    if ((output.handles[0].events & afd_poll_relevant_events) == 0) return error.InvalidAfdPollOutput;
    return .ready;
}

/// WindowsのソケットはWinsockのSOCKETではなくAFDハンドルであり、
/// `operateTimeout`の並行`net_read`は`error.ConcurrencyUnavailable`になる。
/// そのためAFD_POLLで期限付きに読み取り可能/切断を待ち、イベントが
/// 出てから通常のreadでEOFとデータを厳密に分類する。
const probeAotHttpClientWindows = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;

    fn probe(client: std.Io.net.Stream, io: std.Io, timeout_ms: i64) !AotHttpClientProbe {
        var poll_input = AfdPollInfo{
            .timeout = -timeout_ms * 10_000,
            .number_of_handles = 1,
            .exclusive = 0,
            .handles = .{.{
                .handle = client.socket.handle,
                .events = afd_poll_relevant_events,
                .status = .SUCCESS,
            }},
        };
        // 入出力を同じバッファにすると、ドライバがヘッダーだけ書き戻した場合に
        // 入力のイベントマスクが残り、読み取り可能と誤認する。出力は0初期化
        // した別バッファにし、件数・ハンドル・出力長を検証する。
        var poll_output: AfdPollInfo = std.mem.zeroes(AfdPollInfo);
        const result = try io.operate(.{ .device_io_control = .{
            .file = .{ .handle = client.socket.handle, .flags = .{ .nonblocking = true } },
            .code = windows.IOCTL.AFD.POLL,
            .in = std.mem.asBytes(&poll_input),
            .out = std.mem.asBytes(&poll_output),
        } });
        const iosb = result.device_io_control;
        switch (try interpretAfdPollOutput(iosb.u.Status, iosb.Information, &poll_output, client.socket.handle)) {
            .open => return .open,
            .ready => {},
        }
        // AFD_POLLが読み取り可能/切断を通知済みなので、通常のnet_readは
        // 待たずに完了する。`Stream.read`はWindowsでReadResultを分解できず
        // コンパイルできないため、ここでは生のnet_read結果を使う。
        var byte: [1]u8 = undefined;
        var buffers = [_][]u8{byte[0..]};
        const read_result = try (try io.operate(.{ .net_read = .{
            .socket_handle = client.socket.handle,
            .data = buffers[0..],
        } })).net_read;
        if (read_result.data_len == 0) return .eof;
        return .data;
    }
}.probe else struct {
    fn probe(_: std.Io.net.Stream, _: std.Io, _: i64) !AotHttpClientProbe {
        unreachable;
    }
}.probe;

/// 1バイト読み取りに期限を付け、接続状態を判定する。`error.Timeout`だけを
/// 「開いたまま」とし、読み取りエラーは失敗として伝播する。EOFは0バイト
/// 読み取りだけで判定し、RSTなどの読み取りエラーを切断成功として扱わない。
fn probeAotHttpClientTimeout(client: std.Io.net.Stream, io: std.Io, timeout_ms: i64) !AotHttpClientProbe {
    var byte: [1]u8 = undefined;
    var buffers = [_][]u8{byte[0..]};
    const result = io.operateTimeout(.{ .net_read = .{
        .socket_handle = client.socket.handle,
        .data = buffers[0..],
    } }, .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => return .open,
        else => return err,
    };
    const read_result = try result.net_read;
    if (read_result.data_len == 0) return .eof;
    return .data;
}

fn probeAotHttpClient(client: std.Io.net.Stream, io: std.Io, timeout_ms: i64) !AotHttpClientProbe {
    if (builtin.os.tag == .windows) return probeAotHttpClientWindows(client, io, timeout_ms);
    return probeAotHttpClientTimeout(client, io, timeout_ms);
}

/// 期限内に厳密なEOF（0バイト読み取り）を観測する。タイムアウト（接続生存）
/// や読み取りエラー、予期しないデータはすべてテスト失敗にする。
fn expectAotHttpClientEof(client: std.Io.net.Stream, io: std.Io) !void {
    try std.testing.expectEqual(AotHttpClientProbe.eof, try probeAotHttpClient(client, io, 2000));
}

/// 期限まで読み取りイベントが無いことで、接続が開いたまま残っていることを
/// 確認する。EOFやデータ到着はテスト失敗にする。
fn expectAotHttpClientStaysOpen(client: std.Io.net.Stream, io: std.Io) !void {
    try std.testing.expectEqual(AotHttpClientProbe.open, try probeAotHttpClient(client, io, 100));
}

/// 不正な要求を送った接続は、サーバーが未読データを残して閉じるためRSTに
/// なることがある。ここではEOFまたは接続リセットだけを「閉じた」とみなす。
/// 保留接続の検証は上の厳密EOFヘルパーを使い、この緩和を適用しない。
fn expectAotHttpClientClosedAfterMalformed(client: std.Io.net.Stream, io: std.Io) !void {
    const probe = probeAotHttpClient(client, io, 2000) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.SocketUnconnected => return,
        else => return err,
    };
    try std.testing.expectEqual(AotHttpClientProbe.eof, probe);
}

/// Linuxでは`/proc/self/fd`を数えてfdの解放を確認する。fd数を観測できない
/// OSでは`null`を返し、呼び出し側はfd検査を省略する。
fn aotHttpTestOpenFileDescriptorCount() !?usize {
    if (builtin.os.tag != .linux) return null;
    const io = aotHttpIo();
    var directory = std.Io.Dir.cwd().openDir(io, "/proc/self/fd", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

/// テストが開いたfdがすべて解放され、ベースラインへ戻ったことを確認する。
/// スレッド終了直後の回収を待つため、短い間隔で限定的に再試行する。
fn expectAotHttpTestFileDescriptorsRestored(baseline: ?usize) !void {
    const expected = baseline orelse return;
    const io = aotHttpIo();
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        const current = (try aotHttpTestOpenFileDescriptorCount()) orelse return;
        if (current == expected) return;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(expected, (try aotHttpTestOpenFileDescriptorCount()).?);
}

/// テスト用: 1要求を受信して`handleAotHttpRequest`へ渡す。`pollAotHttpServer`は
/// 要求ログをstdoutへ書くため、test-runnerのserver mode（stdoutが制御チャネル）
/// では使えない。
fn expectAotHttpRequestHandled(runtime: *Runtime) !bool {
    var request = try aotHttpReceiveRequest(runtime);
    defer request.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    return handleAotHttpRequest(runtime, &request, &roots);
}

/// 応答全体を読み、status行・本文断片・禁止断片を検査する。
fn expectAotHttpResponse(client: std.Io.net.Stream, io: std.Io, status: []const u8, body: ?[]const u8, forbidden: ?[]const u8) !void {
    var buffer: [4096]u8 = undefined;
    var reader = client.reader(io, &buffer);
    const response = try reader.interface.allocRemaining(std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.startsWith(u8, response, status));
    if (body) |expected| try std.testing.expect(std.mem.indexOf(u8, response, expected) != null);
    if (forbidden) |unexpected| try std.testing.expect(std.mem.indexOf(u8, response, unexpected) == null);
}

test "AOT HTTPは不正query encodingを400で捨てて要求処理を続ける" {
    const io = aotHttpIo();
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();

    for (0..2) |_| {
        var client = try aotHttpTestSendRequest(io, port, "GET /echo?x=%GG HTTP/1.1\r\nHost: localhost\r\n\r\n");
        defer client.close(io);
        // pollはエラーを返さず400を書き、次の要求を受け付ける。
        try std.testing.expect(try expectAotHttpRequestHandled(&runtime));
        try std.testing.expect(runtime.http_connection == null);
        try expectAotHttpResponse(client, io, "HTTP/1.1 400", null, null);
    }
}

test "AOT静的配信の読み込みI/Oエラーは要求スコープのstatusへ分類する" {
    try std.testing.expectEqual(@as(?u16, 404), aotHttpStaticReadErrorStatus(error.FileNotFound));
    try std.testing.expectEqual(@as(?u16, 404), aotHttpStaticReadErrorStatus(error.NotDir));
    try std.testing.expectEqual(@as(?u16, 404), aotHttpStaticReadErrorStatus(error.IsDir));
    try std.testing.expectEqual(@as(?u16, 413), aotHttpStaticReadErrorStatus(error.StreamTooLong));
    try std.testing.expectEqual(@as(?u16, 500), aotHttpStaticReadErrorStatus(error.AccessDenied));
    try std.testing.expectEqual(@as(?u16, 500), aotHttpStaticReadErrorStatus(error.InputOutput));
    // OOMだけはイベントループへ伝播する。
    try std.testing.expectEqual(@as(?u16, null), aotHttpStaticReadErrorStatus(error.OutOfMemory));
}

test "AOT HTTP静的配信はdocroot外を指すsymlinkを404にする" {
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try docroot.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello" });
    try outside.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "OUTSIDE-SECRET" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    const outside_path = try outside.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(outside_path);
    const secret_path = try std.fs.path.join(std.testing.allocator, &.{ outside_path, "secret.txt" });
    defer std.testing.allocator.free(secret_path);
    const link_path = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "leak" });
    defer std.testing.allocator.free(link_path);
    try std.Io.Dir.symLinkAbsolute(io, secret_path, link_path, .{});

    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();
    var route = AotHttpRoute{
        .kind = .static,
        .prefix = try runtime.allocator.dupe(u8, "/static"),
        .path = try runtime.allocator.dupe(u8, docroot_path),
    };
    defer route.deinit(runtime.allocator);

    var inside = try aotHttpTestSendRequest(io, port, "GET /static/hello.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer inside.close(io);
    var inside_request = try aotHttpReceiveRequest(&runtime);
    defer inside_request.deinit();
    try aotHttpServeStatic(&runtime, route, aotHttpPathOnly(inside_request.target));
    try expectAotHttpResponse(inside, io, "HTTP/1.1 200", "hello", null);

    var escaped = try aotHttpTestSendRequest(io, port, "GET /static/leak HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer escaped.close(io);
    var escaped_request = try aotHttpReceiveRequest(&runtime);
    defer escaped_request.deinit();
    try aotHttpServeStatic(&runtime, route, aotHttpPathOnly(escaped_request.target));
    try expectAotHttpResponse(escaped, io, "HTTP/1.1 404", null, "OUTSIDE-SECRET");
}

test "AOT HTTPは未登録URLへのmultipart POSTで本文を解析しない" {
    const io = aotHttpIo();
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();

    var method: Value = .{};
    var get_data: Value = .{};
    var post_data: Value = .{};
    var files_data: Value = .{};
    runtime.http_globals = .{ .method = &method, .get_data = &get_data, .post_data = &post_data, .files_data = &files_data };

    const body = "--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"leak.bin\"\r\n\r\nDATA\r\n--X--\r\n";
    const request_bytes = try std.fmt.allocPrint(runtime.allocator, "POST /nohandler HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=X\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer runtime.allocator.free(request_bytes);
    var client = try aotHttpTestSendRequest(io, port, request_bytes);
    defer client.close(io);
    try std.testing.expect(try expectAotHttpRequestHandled(&runtime));
    // 未登録URLは接続を保持するだけで、本文の解析もアップロード保存もしない。
    try std.testing.expectEqual(@as(usize, 1), runtime.held_http_connections.items.len);
    try std.testing.expectEqual(@as(usize, 0), files_data.object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), post_data.object().?.payload.dictionary.entries.items.len);
}

test "AOT HTTPは登録済みURLへのmultipart POSTでアップロードを要求終了時に削除する" {
    const io = aotHttpIo();
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();

    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    try runtime.http_server_state.routes.append(runtime.allocator, .{
        .kind = .static,
        .prefix = try runtime.allocator.dupe(u8, "/upload"),
        .path = try runtime.allocator.dupe(u8, docroot_path),
    });

    var method: Value = .{};
    var get_data: Value = .{};
    var post_data: Value = .{};
    var files_data: Value = .{};
    runtime.http_globals = .{ .method = &method, .get_data = &get_data, .post_data = &post_data, .files_data = &files_data };

    const body = "--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"ok.bin\"\r\n\r\nDATA\r\n--X--\r\n";
    const request_bytes = try std.fmt.allocPrint(runtime.allocator, "POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=X\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer runtime.allocator.free(request_bytes);
    var client = try aotHttpTestSendRequest(io, port, request_bytes);
    defer client.close(io);

    try std.testing.expect(try expectAotHttpRequestHandled(&runtime));
    try std.testing.expectEqual(@as(usize, 1), files_data.object().?.payload.array.items.len);
    const file = files_data.object().?.payload.array.items[0];
    const path_value = aotHttpDictionaryGetUtf8(&runtime, file.object().?.payload.dictionary.entries.items, "path").?;
    const path = try valueUtf8LossyAlloc(&runtime, path_value);
    defer runtime.allocator.free(path);
    // 保存しただけでなく、要求の処理が終わった時点で削除されている。
    try std.testing.expectEqual(AotHttpPathStat.missing, try aotHttpStatPath(path));
}

/// `aotHttpSaveUpload`と同じ保存先（`$TMPDIR/nako3-plugin_httpserver_upload`）。
fn aotHttpTestUploadDirectory(runtime: *Runtime) ![]u8 {
    const prefix = try nodeTemporaryDirectoryPrefixAlloc(runtime);
    defer runtime.allocator.free(prefix);
    return std.fs.path.join(runtime.allocator, &.{ prefix, "nako3-plugin_httpserver_upload" });
}

/// 保存先に`token`を含むファイルが残っているか。テストは一意なファイル名を
/// 使うため、他のテストが同時に走っても取り違えない。
fn aotHttpTestUploadExists(runtime: *Runtime, token: []const u8) !bool {
    const io = aotHttpIo();
    const directory = try aotHttpTestUploadDirectory(runtime);
    defer runtime.allocator.free(directory);
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(runtime.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (std.mem.indexOf(u8, entry.path, token) != null) return true;
    }
    return false;
}

test "AOT HTTPはFILES登録前の失敗でアップロードを残さない" {
    const io = aotHttpIo();
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();

    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    try runtime.http_server_state.routes.append(runtime.allocator, .{
        .kind = .static,
        .prefix = try runtime.allocator.dupe(u8, "/upload"),
        .path = try runtime.allocator.dupe(u8, docroot_path),
    });

    var method: Value = .{};
    var get_data: Value = .{};
    var post_data: Value = .{};
    var files_data: Value = .{};
    runtime.http_globals = .{ .method = &method, .get_data = &get_data, .post_data = &post_data, .files_data = &files_data };

    const token = try std.fmt.allocPrint(runtime.allocator, "leak{d}.bin", .{currentTimeMilliseconds(&runtime)});
    defer runtime.allocator.free(token);
    // フィールド名がUTF-8でないため`FILESデータ`へ載せる直前で失敗する。
    const body = try std.fmt.allocPrint(runtime.allocator, "--X\r\nContent-Disposition: form-data; name=\"f\xff\"; filename=\"{s}\"\r\n\r\nDATA\r\n--X--\r\n", .{token});
    defer runtime.allocator.free(body);
    const request_bytes = try std.fmt.allocPrint(runtime.allocator, "POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=X\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer runtime.allocator.free(request_bytes);
    var client = try aotHttpTestSendRequest(io, port, request_bytes);
    defer client.close(io);

    // 本文の解析失敗は500で1件だけ捨て、プロセスは止めない。
    try std.testing.expect(try expectAotHttpRequestHandled(&runtime));
    try expectAotHttpResponse(client, io, "HTTP/1.1 500", null, null);
    // FILESに載らなかった保存済みファイルは、回収対象外になる前に消えている。
    try std.testing.expect(!try aotHttpTestUploadExists(&runtime, token));
}

fn testAotHttpFailingHandler(out: *state.Value, _: *anyopaque, _: ?[*]const state.Value, _: usize) callconv(.c) void {
    out.* = .{};
    if (state.active_runtime) |*active| active.setFailure(error.CallbackExecutionFailed);
}

/// 応答も`HTTP出力`もせずに戻るハンドラ。`request_active`が残るため、
/// 要求は`aotHttpHold`の保留経路へ入る。呼び出し回数はルート解決が
/// 実際にこのハンドラへ届いたことの検証に使う。
var test_aot_http_noop_callback_count: usize = 0;

fn testAotHttpNoopHandler(out: *state.Value, _: *anyopaque, _: ?[*]const state.Value, _: usize) callconv(.c) void {
    out.* = .{};
    test_aot_http_noop_callback_count += 1;
}

test "AOT HTTPはハンドラの実行エラーを呼び出し元へ伝播する" {
    const io = aotHttpIo();
    // ハンドラは生成コードと同じく`active_runtime`経由で失敗を記録するため、
    // Runtimeはグローバル側に置き、local変数と二重に持たない。
    state.active_runtime = Runtime{ .allocator = std.testing.allocator };
    defer {
        if (state.active_runtime) |*active| active.deinit();
        state.active_runtime = null;
    }
    const runtime = if (state.active_runtime) |*active| active else unreachable;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();

    try runtime.http_server_state.routes.append(runtime.allocator, .{
        .kind = .callback,
        .prefix = try runtime.allocator.dupe(u8, "/fail"),
        .callback = try runtime.createFunction(testAotHttpFailingHandler, 0, &.{}),
    });

    var client = try aotHttpTestSendRequest(io, port, "GET /fail HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer client.close(io);
    // 利用者プログラムの例外を500応答へ丸めず、イベントループへ返す。
    try std.testing.expectError(error.CallbackExecutionFailed, expectAotHttpRequestHandled(runtime));
}

test "AOT HTTPは未登録URLの保留が上限を超えると最古の接続を閉じる" {
    const io = aotHttpIo();
    // 仕様値は実装定数から導出せず、テスト側で16件を独立に固定する。
    try std.testing.expectEqual(@as(usize, 16), max_held_http_connections);
    const expected_held_http_connections: usize = 16;
    const fd_baseline = try aotHttpTestOpenFileDescriptorCount();
    if (builtin.os.tag == .linux) try std.testing.expect(fd_baseline != null);

    var runtime = Runtime{ .allocator = std.testing.allocator };
    var runtime_live = true;
    defer if (runtime_live) runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();

    var clients: [expected_held_http_connections + 1]std.Io.net.Stream = undefined;
    var client_count: usize = 0;
    defer {
        for (clients[0..client_count]) |*client| client.close(io);
    }
    var accepted: [expected_held_http_connections + 1]std.Io.net.Socket.Handle = undefined;
    for (&clients, 0..) |*client, index| {
        // 17件目を送る直前は、まだ最古の接続が閉じられていない。
        if (index == expected_held_http_connections) try expectAotHttpClientStaysOpen(clients[0], io);
        client.* = try aotHttpTestSendRequest(io, port, "GET /nohandler HTTP/1.1\r\nHost: localhost\r\n\r\n");
        client_count += 1;
        try std.testing.expect(try expectAotHttpRequestHandled(&runtime));
        const held = runtime.held_http_connections.items;
        // 17件目で最古が外れ、以後は16件で頭打ちになる。
        try std.testing.expectEqual(@min(index + 1, expected_held_http_connections), held.len);
        accepted[index] = held[held.len - 1].socket.handle;
    }
    try std.testing.expectEqual(expected_held_http_connections, runtime.held_http_connections.items.len);
    // 最新16件は受け付けた順のまま保持され、先頭の1件だけが閉じている。
    var retained: [expected_held_http_connections]std.Io.net.Socket.Handle = undefined;
    for (runtime.held_http_connections.items, 0..) |stream, index| retained[index] = stream.socket.handle;
    try std.testing.expectEqualSlices(std.Io.net.Socket.Handle, accepted[1..], retained[0..]);
    // hold後は応答中接続とrequest_activeが残らない。
    try std.testing.expect(runtime.http_connection == null);
    try std.testing.expect(!runtime.http_server_state.request_active);

    // (b) 押し出された最古の接続はdeinit前に厳密なEOFで閉じている。
    try expectAotHttpClientEof(clients[0], io);
    // (a) 残り16件はdeinit直前まで開いたまま（期限内に読み取りイベントなし）。
    for (clients[1..]) |*client| try expectAotHttpClientStaysOpen(client.*, io);

    runtime.deinit();
    runtime_live = false;
    // (c) deinit後は残り16件も厳密なEOFで閉じる。
    for (clients[1..]) |*client| try expectAotHttpClientEof(client.*, io);
    for (&clients) |*client| client.close(io);
    client_count = 0;
    // (d) サーバー側fdを含む自プロセスのfdがベースラインへ戻る。
    try expectAotHttpTestFileDescriptorsRestored(fd_baseline);
}

test "AOT HTTPは未応答ハンドラの保留でも上限で最古を閉じdeinitで接続を解放する" {
    const io = aotHttpIo();
    // 仕様値は実装定数から導出せず、テスト側で16件を独立に固定する。
    try std.testing.expectEqual(@as(usize, 16), max_held_http_connections);
    const expected_held_http_connections: usize = 16;
    test_aot_http_noop_callback_count = 0;
    // 基準値の取得・検査はグローバル状態を設定する前に行い、失敗時に
    // active_runtimeへRuntimeが残らないようにする。
    const fd_baseline = try aotHttpTestOpenFileDescriptorCount();
    if (builtin.os.tag == .linux) try std.testing.expect(fd_baseline != null);
    // ハンドラは生成コードと同じく`active_runtime`経由で呼ばれるため、
    // Runtimeはグローバル側に置いてlocal変数と二重に持たない。
    state.active_runtime = Runtime{ .allocator = std.testing.allocator };
    defer {
        if (state.active_runtime) |*active| active.deinit();
        state.active_runtime = null;
    }
    const runtime = if (state.active_runtime) |*active| active else unreachable;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();
    try runtime.http_server_state.routes.append(runtime.allocator, .{
        .kind = .callback,
        .prefix = try runtime.allocator.dupe(u8, "/noop"),
        .callback = try runtime.createFunction(testAotHttpNoopHandler, 0, &.{}),
    });

    var clients: [expected_held_http_connections + 1]std.Io.net.Stream = undefined;
    var client_count: usize = 0;
    defer {
        for (clients[0..client_count]) |*client| client.close(io);
    }
    var accepted: [expected_held_http_connections + 1]std.Io.net.Socket.Handle = undefined;
    for (&clients, 0..) |*client, index| {
        // 17件目を送る直前は、まだ最古の接続が閉じられていない。
        if (index == expected_held_http_connections) try expectAotHttpClientStaysOpen(clients[0], io);
        client.* = try aotHttpTestSendRequest(io, port, "GET /noop HTTP/1.1\r\nHost: localhost\r\n\r\n");
        client_count += 1;
        try std.testing.expect(try expectAotHttpRequestHandled(runtime));
        // 未登録URL分岐ではなく、登録済みの未応答ハンドラが毎回1回実行された。
        try std.testing.expectEqual(index + 1, test_aot_http_noop_callback_count);
        const held = runtime.held_http_connections.items;
        try std.testing.expectEqual(@min(index + 1, expected_held_http_connections), held.len);
        accepted[index] = held[held.len - 1].socket.handle;
    }
    try std.testing.expectEqual(expected_held_http_connections, runtime.held_http_connections.items.len);
    try std.testing.expectEqual(clients.len, test_aot_http_noop_callback_count);
    var retained: [expected_held_http_connections]std.Io.net.Socket.Handle = undefined;
    for (runtime.held_http_connections.items, 0..) |stream, index| retained[index] = stream.socket.handle;
    try std.testing.expectEqualSlices(std.Io.net.Socket.Handle, accepted[1..], retained[0..]);
    // 応答も保留もしなかったハンドラでも、hold後は応答中接続が残らない。
    try std.testing.expect(runtime.http_connection == null);
    try std.testing.expect(!runtime.http_server_state.request_active);

    // (b) 押し出された最古の接続はdeinit前に厳密なEOFで閉じている。
    try expectAotHttpClientEof(clients[0], io);
    // (a) 残り16件はdeinit直前まで開いたまま（期限内に読み取りイベントなし）。
    for (clients[1..]) |*client| try expectAotHttpClientStaysOpen(client.*, io);

    // deinitは保持中の16件をすべて閉じる。明示的に呼んでクライアント側の
    // EOFまで確認し、外側のdeferはactive_runtimeをnullにして二重解放を避ける。
    runtime.deinit();
    state.active_runtime = null;
    // (c) deinit後は残り16件も厳密なEOFで閉じる。
    for (clients[1..]) |*client| try expectAotHttpClientEof(client.*, io);
    for (&clients) |*client| client.close(io);
    client_count = 0;
    // (d) サーバー側fdを含む自プロセスのfdがベースラインへ戻る。
    try expectAotHttpTestFileDescriptorsRestored(fd_baseline);
}

test "AOT HTTPのAFD_POLL出力判定は不完全な出力とキャンセルを拒否する" {
    const windows = std.os.windows;
    const handle: windows.HANDLE = @ptrFromInt(0x1234);
    const other: windows.HANDLE = @ptrFromInt(0x5678);
    const header_len = @offsetOf(AfdPollInfo, "handles");
    const full_len = @sizeOf(AfdPollInfo);
    var output: AfdPollInfo = std.mem.zeroes(AfdPollInfo);
    output.handles[0].handle = handle;
    output.handles[0].events = afd_poll_receive;
    output.handles[0].status = .SUCCESS;

    // ヘッダー未満（0を含む）は0件とみなさず不正出力。
    try std.testing.expectError(error.InvalidAfdPollOutput, interpretAfdPollOutput(.SUCCESS, 0, &output, handle));
    try std.testing.expectError(error.InvalidAfdPollOutput, interpretAfdPollOutput(.SUCCESS, header_len - 1, &output, handle));

    // ヘッダー長以上で0件なら期限切れ。
    output.number_of_handles = 0;
    try std.testing.expectEqual(AfdPollInterpretation.open, try interpretAfdPollOutput(.SUCCESS, header_len, &output, handle));

    // 1件でも全体長未満・ハンドル不一致は不正出力。
    output.number_of_handles = 1;
    try std.testing.expectError(error.InvalidAfdPollOutput, interpretAfdPollOutput(.SUCCESS, full_len - 1, &output, handle));
    try std.testing.expectError(error.InvalidAfdPollOutput, interpretAfdPollOutput(.SUCCESS, full_len, &output, other));

    // 個別ハンドルのタイムアウトのみ生存、キャンセルはエラー。
    output.handles[0].status = .TIMEOUT;
    try std.testing.expectEqual(AfdPollInterpretation.open, try interpretAfdPollOutput(.SUCCESS, full_len, &output, handle));
    output.handles[0].status = .CANCELLED;
    try std.testing.expectError(error.Unexpected, interpretAfdPollOutput(.SUCCESS, full_len, &output, handle));

    // 1件出力で対象イベント0は不正出力、有効イベントありはready。
    output.handles[0].status = .SUCCESS;
    output.handles[0].events = 0;
    try std.testing.expectError(error.InvalidAfdPollOutput, interpretAfdPollOutput(.SUCCESS, full_len, &output, handle));
    output.handles[0].events = afd_poll_disconnect;
    try std.testing.expectEqual(AfdPollInterpretation.ready, try interpretAfdPollOutput(.SUCCESS, full_len, &output, handle));

    // IOCTL全体のタイムアウトのみ生存、キャンセルはエラー。
    try std.testing.expectEqual(AfdPollInterpretation.open, try interpretAfdPollOutput(.TIMEOUT, 0, &output, handle));
    try std.testing.expectError(error.Unexpected, interpretAfdPollOutput(.CANCELLED, full_len, &output, handle));
}

test "AOT HTTPは途中切断と不正chunk/header後に次の要求を受け付ける" {
    const io = aotHttpIo();
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();

    const malformed = [_][]const u8{
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 20\r\n\r\nshort",
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\nZZ\r\nbad\r\n",
        "GET /echo HTTP/1.1\r\nHost: localhost\r\nX-Bad: \x00\r\n\r\n",
    };
    for (malformed) |case| {
        var client = try aotHttpTestSendRequest(io, port, case);
        defer client.close(io);
        // 不正な要求は接続単位の受信workerが吸収し、応答なしで閉じる。
        try expectAotHttpClientClosedAfterMalformed(client, io);
        try std.testing.expect(runtime.http_connection == null);
        try std.testing.expect(!runtime.http_head_request);
        try std.testing.expect(!runtime.http_server_state.request_active);
    }

    var client = try aotHttpTestSendRequest(io, port, "GET /healthy HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer client.close(io);
    var request = try aotHttpReceiveRequest(&runtime);
    defer request.deinit();
    try std.testing.expectEqualStrings("GET", request.method);
    try std.testing.expectEqualStrings("/healthy", request.target);
    try std.testing.expect(runtime.http_connection != null);
    try aotHttpRespondSafe(&runtime, "ok");
    try std.testing.expect(runtime.http_connection == null);
    try std.testing.expect(!runtime.http_server_state.request_active);
}

test "AOT HTTPは受信中の低速接続に関わらず別接続の完了要求を処理する" {
    const io = aotHttpIo();
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();

    // body未完のまま送り切らない低速接続。send shutdownしないため
    // 受信workerのreadが接続内で保留される。
    var slow = try aotHttpTestSendBytes(io, port, "POST /slow HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\npart");
    defer slow.close(io);

    var fast = try aotHttpTestSendRequest(io, port, "GET /fast HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer fast.close(io);
    // 低速接続が受信中でも、完了した別接続の要求がqueue経由で返る。
    var request = try aotHttpReceiveRequest(&runtime);
    defer request.deinit();
    try std.testing.expectEqualStrings("GET", request.method);
    try std.testing.expectEqualStrings("/fast", request.target);
    try aotHttpRespondSafe(&runtime, "ok");

    var response_buffer: [256]u8 = undefined;
    var response_reader = fast.reader(io, &response_buffer);
    const status_line = try response_reader.interface.takeDelimiter('\n');
    try std.testing.expect(status_line != null);
    try std.testing.expect(std.mem.startsWith(u8, status_line.?, "HTTP/1.1 200"));
}

test "AOT HTTP静的配信はファイル、index、404の経路で一時パスを解放する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = aotHttpIo();
    try temporary.dir.writeFile(io, .{ .sub_path = "index.html", .data = "root" });
    try temporary.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello" });
    try temporary.dir.createDirPath(io, "nested");
    try temporary.dir.writeFile(io, .{ .sub_path = "nested/index.html", .data = "nested" });
    try temporary.dir.createDirPath(io, "empty");

    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const root = try temporary.dir.realPathFileAlloc(io, ".", runtime.allocator);
    defer runtime.allocator.free(root);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();

    var route = AotHttpRoute{
        .kind = .static,
        .prefix = try runtime.allocator.dupe(u8, "/static"),
        .path = try runtime.allocator.dupe(u8, root),
    };
    defer route.deinit(runtime.allocator);

    const targets = [_][]const u8{
        "/static/hello.txt",
        "/static/",
        "/static/nested/",
        "/static/empty/",
        "/static/missing.txt",
    };
    for (targets) |target| {
        const request_bytes = try std.fmt.allocPrint(runtime.allocator, "GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{target});
        defer runtime.allocator.free(request_bytes);
        var client = try aotHttpTestSendRequest(io, port, request_bytes);
        defer client.close(io);
        var request = try aotHttpReceiveRequest(&runtime);
        defer request.deinit();
        try aotHttpServeStatic(&runtime, route, aotHttpPathOnly(request.target));
        try std.testing.expect(runtime.http_connection == null);
    }
}

/// `parent/name`の実ディレクトリを、`target`へのsymlinkへ置き換える
/// （攻撃者が照合後・open前に中間ディレクトリを差し替える状況の再現）。
fn replaceDirectoryWithSymlink(io: std.Io, parent: std.Io.Dir, name: []const u8, target: []const u8) !void {
    try parent.deleteTree(io, name);
    const link_path = try parent.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(link_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ link_path, name });
    defer std.testing.allocator.free(path);
    try std.Io.Dir.symLinkAbsolute(io, target, path, .{});
}

test "AOT HTTP静的配信はopen済みfdから読むため照合後のsymlink差し替えに影響されない" {
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try docroot.dir.createDirPath(io, "sub");
    try docroot.dir.writeFile(io, .{ .sub_path = "sub/hello.txt", .data = "INSIDE" });
    try outside.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "OUTSIDE-SECRET" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    const outside_path = try outside.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(outside_path);

    // `aotHttpServeStatic`と同じ順序で開く。旧実装はここでrealpath文字列を
    // 照合し、後から同じ文字列を開き直していた。
    var opened = (try aotHttpOpenStaticFile(io, docroot_path, "sub/hello.txt")).?;
    defer opened.file.close(io);
    try std.testing.expectEqualStrings("hello.txt", opened.name);

    // 開いた後（読み取り前）に中間ディレクトリをdocroot外へのsymlinkへ差し替える。
    try replaceDirectoryWithSymlink(io, docroot.dir, "sub", outside_path);

    const body = try aotHttpReadStaticFile(io, opened.file, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("INSIDE", body);
}

test "AOT HTTP静的配信は中間・最終成分のsymlinkをdocroot内でも追従しない" {
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    try docroot.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello" });
    try docroot.dir.createDirPath(io, "nested");
    try docroot.dir.writeFile(io, .{ .sub_path = "nested/index.html", .data = "nested" });

    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    const hello_path = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "hello.txt" });
    defer std.testing.allocator.free(hello_path);
    const alias_path = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "alias.txt" });
    defer std.testing.allocator.free(alias_path);
    try std.Io.Dir.symLinkAbsolute(io, hello_path, alias_path, .{});
    const nested_path = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "nested" });
    defer std.testing.allocator.free(nested_path);
    const nested_link = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "nested_link" });
    defer std.testing.allocator.free(nested_link);
    try std.Io.Dir.symLinkAbsolute(io, nested_path, nested_link, .{});

    // 通常ファイルはこれまでどおり配信する。
    var plain = (try aotHttpOpenStaticFile(io, docroot_path, "hello.txt")).?;
    plain.file.close(io);

    // docroot内を指すsymlinkでも追従しない（fail closed）。
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "alias.txt")) == null);
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "nested_link/index.html")) == null);
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "nested_link")) == null);
    // ディレクトリ指定はindex.htmlをfdから開く。
    var index = (try aotHttpOpenStaticFile(io, docroot_path, "nested")).?;
    defer index.file.close(io);
    try std.testing.expectEqualStrings("index.html", index.name);
}

test "AOT HTTP静的配信は中間ディレクトリのsymlink差し替えと競合してもdocroot外を読まない" {
    // RENAME_EXCHANGEで実ディレクトリとdocroot外へのsymlinkを原子的に入れ替え、
    // 照合とopenの間の実時間ウィンドウを攻撃者が継続的に狙う状況を作る。
    // 修正前はこのテストでdocroot外の`OUTSIDE-SECRET`が返る（PoC）。
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try docroot.dir.createDirPath(io, "sub");
    try docroot.dir.writeFile(io, .{ .sub_path = "sub/hello.txt", .data = "INSIDE" });
    try outside.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "OUTSIDE-SECRET" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    const outside_path = try outside.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(outside_path);
    const swap_dir = try std.fs.path.joinZ(std.testing.allocator, &.{ docroot_path, "sub" });
    defer std.testing.allocator.free(swap_dir);
    const swap_link = try std.fs.path.joinZ(std.testing.allocator, &.{ docroot_path, "sub_link" });
    defer std.testing.allocator.free(swap_link);
    try std.Io.Dir.symLinkAbsolute(io, outside_path, swap_link, .{});

    const swapper = struct {
        fn run(dir: [:0]const u8, link: [:0]const u8, stop: *std.atomic.Value(bool), swaps: *std.atomic.Value(u64)) void {
            const linux = std.os.linux;
            while (!stop.load(.acquire)) {
                _ = linux.renameat2(linux.AT.FDCWD, dir.ptr, linux.AT.FDCWD, link.ptr, .{ .EXCHANGE = true });
                _ = swaps.fetchAdd(1, .monotonic);
            }
        }
    };

    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();
    var route = AotHttpRoute{
        .kind = .static,
        .prefix = try runtime.allocator.dupe(u8, "/static"),
        .path = try runtime.allocator.dupe(u8, docroot_path),
    };
    defer route.deinit(runtime.allocator);

    var stop = std.atomic.Value(bool).init(false);
    var swaps = std.atomic.Value(u64).init(0);
    const thread = try std.Thread.spawn(.{}, swapper.run, .{ swap_dir, swap_link, &stop, &swaps });
    var joined = false;
    defer if (!joined) {
        stop.store(true, .release);
        thread.join();
    };

    var leaks: usize = 0;
    for (0..400) |_| {
        var client = try aotHttpTestSendRequest(io, port, "GET /static/sub/hello.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
        defer client.close(io);
        var request = try aotHttpReceiveRequest(&runtime);
        defer request.deinit();
        try aotHttpServeStatic(&runtime, route, aotHttpPathOnly(request.target));
        var buffer: [4096]u8 = undefined;
        var reader = client.reader(io, &buffer);
        const response = try reader.interface.allocRemaining(std.testing.allocator, .limited(64 * 1024));
        defer std.testing.allocator.free(response);
        if (std.mem.indexOf(u8, response, "OUTSIDE-SECRET") != null) leaks += 1;
    }
    stop.store(true, .release);
    thread.join();
    joined = true;
    std.debug.print("\n[AOT静的配信TOCTOU回帰] swaps={d} requests=400 docroot外読み出し={d}\n", .{ swaps.load(.monotonic), leaks });
    try std.testing.expectEqual(@as(usize, 0), leaks);
}
