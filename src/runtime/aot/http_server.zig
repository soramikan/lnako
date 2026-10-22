const std = @import("std");
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

pub fn aotHttpServeStatic(runtime: *Runtime, route: AotHttpRoute, path: []const u8) !void {
    const io = aotHttpIo();
    const relative_raw = path[@min(route.prefix.len, path.len)..];
    const sanitized = try aotHttpRemoveParentSegments(runtime.allocator, relative_raw);
    defer runtime.allocator.free(sanitized);
    // docrootと配信対象の両方を実パスへ解決し、配信対象がdocroot配下に
    // あることを確認する。文字列比較だけではdocroot内のsymlinkが外を
    // 指す場合を検出できない（Interpreter側resolveHttpServerStaticPathと
    // 同じ判定）。
    const root_real = std.Io.Dir.cwd().realPathFileAlloc(io, route.path, runtime.allocator) catch |err| switch (err) {
        error.FileNotFound => return aotHttpRespondWith(runtime, 404, &.{}, aot_http_not_found_body),
        else => return err,
    };
    defer runtime.allocator.free(root_real);
    var target = try std.fs.path.join(runtime.allocator, &.{ root_real, std.mem.trimStart(u8, sanitized, "/\\") });
    defer runtime.allocator.free(target);
    switch (try aotHttpStatPath(target)) {
        .missing => return aotHttpRespondWith(runtime, 404, &.{}, aot_http_not_found_body),
        .directory => {
            const index_path = try std.fs.path.join(runtime.allocator, &.{ target, "index.html" });
            runtime.allocator.free(target);
            target = index_path;
            if (try aotHttpStatPath(target) != .file) return aotHttpRespondWith(runtime, 404, &.{}, aot_http_not_found_body);
        },
        .file => {},
    }
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, target, runtime.allocator) catch |err| switch (err) {
        error.FileNotFound => return aotHttpRespondWith(runtime, 404, &.{}, aot_http_not_found_body),
        else => return err,
    };
    defer runtime.allocator.free(resolved);
    if (!aotHttpIsUnderRoot(resolved, root_real)) return aotHttpRespondWith(runtime, 404, &.{}, aot_http_not_found_body);
    const body = try std.Io.Dir.cwd().readFileAlloc(io, resolved, runtime.allocator, .limited(1024 * 1024 * 1024));
    defer runtime.allocator.free(body);
    const saved_status = runtime.http_server_state.response_status;
    runtime.http_server_state.response_status = 200;
    runtime.http_server_state.clearHeaders(runtime.allocator);
    try aotHttpAppendHeader(runtime, "Content-Type", aotHttpMimeType(resolved));
    defer runtime.http_server_state.response_status = saved_status;
    return aotHttpRespondSafe(runtime, body);
}

fn aotHttpIsUnderRoot(resolved: []const u8, root: []const u8) bool {
    if (resolved.len < root.len) return false;
    if (!std.mem.startsWith(u8, resolved, root)) return false;
    if (resolved.len == root.len) return true;
    return std.fs.path.isSep(resolved[root.len]);
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

pub fn aotHttpStatPath(path: []const u8) !AotHttpPathStat {
    const stat = std.Io.Dir.cwd().statFile(aotHttpIo(), path, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        else => err,
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

/// 接続が応答なしで閉じられたことを確認する。RST由来のread errorも切断として扱う。
fn expectAotHttpClientClosed(client: std.Io.net.Stream, io: std.Io) !void {
    var buffer: [512]u8 = undefined;
    var reader = client.reader(io, &buffer);
    const line = reader.interface.takeDelimiter('\n') catch return;
    try std.testing.expect(line == null);
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
    try std.testing.expectError(error.CallbackExecutionFailed, pollAotHttpServer(runtime));
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
        try expectAotHttpClientClosed(client, io);
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
