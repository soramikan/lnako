const std = @import("std");
const state = @import("state.zig");
const shared = @import("shared.zig");

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

const AotHttpRequest = struct {
    method: []u8,
    target: []u8,
    content_type: []u8,
    body: []u8,
    too_large: bool = false,

    pub fn deinit(self: *AotHttpRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.target);
        allocator.free(self.content_type);
        allocator.free(self.body);
        self.* = undefined;
    }
};

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
            if (headers.tag == @intFromEnum(Tag.dictionary)) {
                for (headers.object().?.payload.dictionary.items) |entry| {
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
            try aotHttpRespond(runtime, body);
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
            try aotHttpRespond(runtime, body);
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
        runtime.http_connection = null;
        runtime.http_head_request = false;
        runtime.http_server_state.request_active = false;
    }
    var buffer: [16 * 1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.print("HTTP/1.1 {d} {s}\r\n", .{ runtime.http_server_state.response_status, aotHttpStatusPhrase(runtime.http_server_state.response_status) });
    var has_content_length = false;
    for (runtime.http_server_state.response_headers.items) |header| {
        if (std.mem.indexOf(u8, header.name, "\r\n") != null or std.mem.indexOf(u8, header.value, "\r\n") != null) return error.InvalidHttpHeader;
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) has_content_length = true;
        try writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value });
    }
    if (!has_content_length) try writer.interface.print("Content-Length: {d}\r\n", .{body.len});
    try writer.interface.writeAll("Connection: close\r\n\r\n");
    if (!runtime.http_head_request) try writer.interface.writeAll(body);
    try writer.interface.flush();
}

pub fn aotHttpHold(runtime: *Runtime) !void {
    const stream = runtime.http_connection orelse return error.HttpServerResponseOutsideRequest;
    try runtime.held_http_connections.append(runtime.allocator, stream);
    runtime.http_connection = null;
    runtime.http_head_request = false;
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
    var request = try aotHttpReceiveRequest(runtime);
    defer request.deinit(runtime.allocator);
    if (request.too_large) {
        runtime.http_server_state.response_status = 413;
        runtime.http_server_state.clearHeaders(runtime.allocator);
        try aotHttpRespond(runtime, "Request entity too large.");
        return true;
    }

    var message: [256]u8 = undefined;
    const log = try std.fmt.bufPrint(&message, "[簡易HTTPサーバ] 要求あり METHOD={s} URL={s}\n", .{ request.method, request.target });
    aotHttpWrite(log);

    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try aotHttpParseQuery(runtime, request.target);
    roots[1] = try runtime.createArray(&.{});
    roots[2] = try runtime.createDictionary(&.{});
    if (std.ascii.eqlIgnoreCase(request.method, "POST")) roots[2] = try aotHttpParsePost(runtime, request.content_type, request.body, roots[1]);
    roots[3] = try runtimeUtf8String(runtime, request.method);
    if (runtime.http_globals) |globals| {
        if (globals.method) |pointer| pointer.* = roots[3];
        if (globals.get_data) |pointer| pointer.* = roots[0];
        if (globals.post_data) |pointer| pointer.* = roots[2];
        if (globals.files_data) |pointer| pointer.* = roots[1];
    }

    const path = aotHttpPathOnly(request.target);
    const route = aotHttpBestRoute(runtime.http_server_state.routes.items, path) orelse {
        try aotHttpHold(runtime);
        return true;
    };
    if (route.kind == .static) {
        try aotHttpServeStatic(runtime, route, path);
        return true;
    }
    runtime.http_server_state.request_active = true;
    runtime.http_server_state.response_status = 200;
    runtime.http_server_state.clearHeaders(runtime.allocator);
    if (route.callback.tag != @intFromEnum(Tag.function)) return error.HttpServerCallbackNotCallable;
    _ = try invokeAotCallback(runtime, route.callback, null, 0);
    if (runtime.http_server_state.request_active) {
        try aotHttpHold(runtime);
        runtime.http_server_state.request_active = false;
    }
    return true;
}

pub fn aotHttpReceiveRequest(runtime: *Runtime) !AotHttpRequest {
    const server = if (runtime.http_server) |*value| value else return error.HttpServerNotStarted;
    const io = aotHttpIo();
    if (runtime.http_connection != null) return error.PreviousHttpResponseNotFinished;
    const stream = try server.accept(io);
    errdefer stream.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    const request_line_raw = (try reader.interface.takeDelimiter('\n')) orelse return error.InvalidHttpRequest;
    const request_line = std.mem.trimEnd(u8, request_line_raw, "\r");
    var request_parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_source = request_parts.next() orelse return error.InvalidHttpRequest;
    const target_source = request_parts.next() orelse return error.InvalidHttpRequest;
    const method = try runtime.allocator.dupe(u8, method_source);
    errdefer runtime.allocator.free(method);
    for (method) |*byte| byte.* = std.ascii.toUpper(byte.*);
    const target = try runtime.allocator.dupe(u8, target_source);
    errdefer runtime.allocator.free(target);
    var content_length: usize = 0;
    var transfer_chunked = false;
    var content_type = try runtime.allocator.alloc(u8, 0);
    errdefer runtime.allocator.free(content_type);
    while (true) {
        const line_raw = (try reader.interface.takeDelimiter('\n')) orelse return error.InvalidHttpRequest;
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");
        const header_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(header_name, "content-length")) {
            content_length = try std.fmt.parseInt(usize, header_value, 10);
        } else if (std.ascii.eqlIgnoreCase(header_name, "transfer-encoding")) {
            transfer_chunked = std.ascii.indexOfIgnoreCase(header_value, "chunked") != null;
        } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
            runtime.allocator.free(content_type);
            content_type = try runtime.allocator.dupe(u8, header_value);
        }
    }
    runtime.http_connection = stream;
    runtime.http_head_request = std.ascii.eqlIgnoreCase(method, "HEAD");
    if (transfer_chunked) {
        const chunked = try aotHttpReadChunkedBody(runtime.allocator, &reader.interface, 10 * 1024 * 1024);
        return .{ .method = method, .target = target, .content_type = content_type, .body = chunked.body, .too_large = chunked.too_large };
    }
    if (content_length > 10 * 1024 * 1024) {
        _ = try reader.interface.discardShort(content_length);
        return .{ .method = method, .target = target, .content_type = content_type, .body = try runtime.allocator.alloc(u8, 0), .too_large = true };
    }
    const body = try runtime.allocator.alloc(u8, content_length);
    errdefer runtime.allocator.free(body);
    try reader.interface.readSliceAll(body);
    return .{ .method = method, .target = target, .content_type = content_type, .body = body };
}

pub fn aotHttpReadChunkedBody(allocator: std.mem.Allocator, reader: *std.Io.Reader, maximum_size: usize) !AotHttpChunkedBody {
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
    if (std.ascii.indexOfIgnoreCase(content_type, "application/json") != null) {
        var source = try runtimeUtf8StringLossy(runtime, body);
        var frame = RootFrame{};
        runtime.pushRoots(&frame, @ptrCast(&source), 1);
        defer runtime.popRoots(&frame);
        return jsonDecodeBuiltin(runtime, source) catch source;
    }
    if (std.ascii.indexOfIgnoreCase(content_type, "application/x-www-form-urlencoded") != null) return aotHttpParseUrlEncoded(runtime, body);
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
    const relative_raw = path[@min(route.prefix.len, path.len)..];
    const sanitized = try aotHttpRemoveParentSegments(runtime.allocator, relative_raw);
    defer runtime.allocator.free(sanitized);
    var full_path = try std.fs.path.join(runtime.allocator, &.{ route.path, std.mem.trimStart(u8, sanitized, "/\\") });
    defer runtime.allocator.free(full_path);
    switch (try aotHttpStatPath(full_path)) {
        .missing => return aotHttpRespondWith(runtime, 404, &.{}, "<html><meta charset=\"utf-8\"><body><h1>404 見当たりません。</h1></body></html>"),
        .directory => {
            const index_path = try std.fs.path.join(runtime.allocator, &.{ full_path, "index.html" });
            runtime.allocator.free(full_path);
            full_path = index_path;
            if (try aotHttpStatPath(full_path) != .file) return aotHttpRespondWith(runtime, 404, &.{}, "<html><meta charset=\"utf-8\"><body><h1>404 見当たりません。</h1></body></html>");
        },
        .file => {},
    }
    const body = try std.Io.Dir.cwd().readFileAlloc(aotHttpIo(), full_path, runtime.allocator, .limited(1024 * 1024 * 1024));
    defer runtime.allocator.free(body);
    const saved_status = runtime.http_server_state.response_status;
    runtime.http_server_state.response_status = 200;
    runtime.http_server_state.clearHeaders(runtime.allocator);
    try aotHttpAppendHeader(runtime, "Content-Type", aotHttpMimeType(full_path));
    defer runtime.http_server_state.response_status = saved_status;
    return aotHttpRespond(runtime, body);
}

pub fn aotHttpRespondWith(runtime: *Runtime, status: u16, headers: []const AotHttpHeader, body: []const u8) !void {
    const saved_status = runtime.http_server_state.response_status;
    runtime.http_server_state.response_status = status;
    runtime.http_server_state.clearHeaders(runtime.allocator);
    for (headers) |header| {
        try aotHttpAppendHeader(runtime, header.name, header.value);
    }
    defer runtime.http_server_state.response_status = saved_status;
    return aotHttpRespond(runtime, body);
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
