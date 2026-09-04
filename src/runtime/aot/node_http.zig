const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const Object = aot_state.Object;
const BigInt = aot_state.BigInt;
const AotClientHttpTask = aot_state.AotClientHttpTask;
const AotClientHttpMode = aot_state.AotClientHttpMode;
const AotClientHttpResult = aot_state.AotClientHttpResult;
const AotClientHttpBodyKind = aot_state.AotClientHttpBodyKind;
const numberValue = aot_state.numberValue;
const valueToNumber = aot_state.valueToNumber;
const valueUtf8LossyAlloc = aot_state.valueUtf8LossyAlloc;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const runtimeUtf8String = aot_state.runtimeUtf8String;
const runtimeUtf8StringLossy = aot_state.runtimeUtf8StringLossy;
const aotRuntimeIo = aot_state.aotRuntimeIo;
const aotHttpDictionarySetUtf8 = aot_state.aotHttpDictionarySetUtf8;
const jsonDecodeBuiltin = aot_state.jsonDecodeBuiltin;
const jsonEncodeBuiltin = aot_state.jsonEncodeBuiltin;
const nodeBasename = aot_state.nodeBasename;
const invokeAotCallback = aot_state.invokeAotCallback;
const resolveAotCallback = aot_state.resolveAotCallback;
const createAotPromise = aot_state.createAotPromise;
const resolveAotPromise = aot_state.resolveAotPromise;
const rejectAotPromise = aot_state.rejectAotPromise;
const callbackFailureReason = aot_state.callbackFailureReason;
const writeAotAjaxReceiveError = aot_state.writeAotAjaxReceiveError;
const waitAotMilliseconds = aot_state.waitAotMilliseconds;
const staticUtf8 = aot_state.staticUtf8;

const AotClientHttpHeader = struct {
    name: []u8,
    value: []u8,
};

const AotClientHttpRequest = struct {
    allocator: std.mem.Allocator,
    method: []u8,
    url: []u8,
    headers: std.ArrayList(AotClientHttpHeader) = .empty,
    body: []u8,
    has_body: bool,

    pub fn init(allocator: std.mem.Allocator, method: []const u8, url: []const u8, body: []const u8, has_body: bool) !AotClientHttpRequest {
        const owned_method = try allocator.dupe(u8, method);
        errdefer allocator.free(owned_method);
        const owned_url = try allocator.dupe(u8, url);
        errdefer allocator.free(owned_url);
        const owned_body = try allocator.dupe(u8, body);
        errdefer allocator.free(owned_body);
        return .{
            .allocator = allocator,
            .method = owned_method,
            .url = owned_url,
            .body = owned_body,
            .has_body = has_body,
        };
    }

    pub fn deinit(self: *AotClientHttpRequest) void {
        self.allocator.free(self.method);
        self.allocator.free(self.url);
        for (self.headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.headers.deinit(self.allocator);
        self.allocator.free(self.body);
        self.* = undefined;
    }

    pub fn addHeader(self: *AotClientHttpRequest, name: []const u8, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.headers.append(self.allocator, .{ .name = owned_name, .value = owned_value });
    }
};
pub fn nodePostDataBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    const parameters = arguments[0];
    if (parameters.tag == @intFromEnum(Tag.dictionary)) {
        for (parameters.object().?.payload.dictionary.items, 0..) |entry, index| {
            if (index > 0) try output.writer.writeByte('&');
            const key = try valueUtf8LossyAlloc(runtime, entry.key);
            defer runtime.allocator.free(key);
            const value = try valueUtf8LossyAlloc(runtime, entry.value);
            defer runtime.allocator.free(value);
            try appendNodeUriComponent(&output.writer, key);
            try output.writer.writeByte('=');
            try appendNodeUriComponent(&output.writer, value);
        }
    }
    return runtimeUtf8String(runtime, output.written());
}

pub fn aotClientDictionaryGetAscii(value: Value, name: []const u8) ?Value {
    if (value.tag != @intFromEnum(Tag.dictionary)) return null;
    const object = value.object() orelse return null;
    if (object.payload != .dictionary) return null;
    for (object.payload.dictionary.items) |entry| {
        const matches = switch (@as(Tag, @enumFromInt(entry.key.tag))) {
            .static_utf8_string => std.mem.eql(u8, staticUtf8(entry.key), name),
            .utf16_string => if (entry.key.object()) |key_object| blk: {
                const units = key_object.payload.utf16_string;
                if (units.len != name.len) break :blk false;
                for (units, name) |unit, byte| if (unit != byte) break :blk false;
                break :blk true;
            } else false,
            else => false,
        };
        if (matches) return entry.value;
    }
    return null;
}

pub fn aotClientValueBytes(runtime: *Runtime, value: Value) ![]u8 {
    if (value.tag == @intFromEnum(Tag.byte_buffer)) {
        const object = value.object() orelse return error.InvalidByteBuffer;
        if (object.payload != .byte_buffer) return error.InvalidByteBuffer;
        return runtime.allocator.dupe(u8, object.payload.byte_buffer.bytes);
    }
    return valueUtf8LossyAlloc(runtime, value);
}

pub fn aotClientPrepareAjax(runtime: *Runtime, ajax_options: ?*Value, url_value: Value) !AotClientHttpRequest {
    const url = try valueUtf8LossyAlloc(runtime, url_value);
    defer runtime.allocator.free(url);
    var request = try AotClientHttpRequest.init(runtime.allocator, "GET", url, &.{}, false);
    errdefer request.deinit();
    if (ajax_options) |pointer| if (aotClientDictionaryGetAscii(pointer.*, "method")) |method_value| {
        const method = try valueUtf8LossyAlloc(runtime, method_value);
        defer runtime.allocator.free(method);
        const upper = try runtime.allocator.dupe(u8, method);
        for (upper) |*byte| byte.* = std.ascii.toUpper(byte.*);
        runtime.allocator.free(request.method);
        request.method = upper;
    };
    if (ajax_options) |pointer| if (aotClientDictionaryGetAscii(pointer.*, "body")) |body_value| {
        const body = try aotClientValueBytes(runtime, body_value);
        runtime.allocator.free(request.body);
        request.body = body;
        request.has_body = true;
    };
    if (ajax_options) |pointer| if (aotClientDictionaryGetAscii(pointer.*, "headers")) |headers_value| {
        if (headers_value.tag != @intFromEnum(Tag.dictionary)) return request;
        const headers_object = headers_value.object() orelse return request;
        if (headers_object.payload != .dictionary) return request;
        for (headers_object.payload.dictionary.items) |entry| {
            const name = try valueUtf8LossyAlloc(runtime, entry.key);
            defer runtime.allocator.free(name);
            const value = try valueUtf8LossyAlloc(runtime, entry.value);
            defer runtime.allocator.free(value);
            try request.addHeader(name, value);
        }
    };
    return request;
}

pub fn aotClientAppendUriComponent(writer: *std.Io.Writer, source: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (source) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-_.!~*'()", byte) != null) {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

pub fn aotClientFormEncodedBody(runtime: *Runtime, parameters: Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    if (parameters.tag == @intFromEnum(Tag.dictionary)) {
        const object = parameters.object() orelse return error.InvalidDictionary;
        if (object.payload != .dictionary) return error.InvalidDictionary;
        for (object.payload.dictionary.items, 0..) |entry, index| {
            if (index > 0) try output.writer.writeByte('&');
            const key = try valueUtf8LossyAlloc(runtime, entry.key);
            defer runtime.allocator.free(key);
            const value = try valueUtf8LossyAlloc(runtime, entry.value);
            defer runtime.allocator.free(value);
            try aotClientAppendUriComponent(&output.writer, key);
            try output.writer.writeByte('=');
            try aotClientAppendUriComponent(&output.writer, value);
        }
    }
    return output.toOwnedSlice();
}

pub fn aotClientMultipartFields(runtime: *Runtime, parameters: Value, boundary: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    if (parameters.tag == @intFromEnum(Tag.dictionary)) {
        const object = parameters.object() orelse return error.InvalidDictionary;
        if (object.payload != .dictionary) return error.InvalidDictionary;
        for (object.payload.dictionary.items) |entry| {
            const key = try valueUtf8LossyAlloc(runtime, entry.key);
            defer runtime.allocator.free(key);
            const value = try valueUtf8LossyAlloc(runtime, entry.value);
            defer runtime.allocator.free(value);
            try output.writer.print("--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{ boundary, key, value });
        }
    }
    try output.writer.print("--{s}--\r\n", .{boundary});
    return output.toOwnedSlice();
}

pub fn aotClientPreparePost(runtime: *Runtime, url_value: Value, parameters: Value, multipart: bool, omit_boundary_header: bool) !AotClientHttpRequest {
    const url = try valueUtf8LossyAlloc(runtime, url_value);
    defer runtime.allocator.free(url);
    if (!multipart) {
        const body = try aotClientFormEncodedBody(runtime, parameters);
        defer runtime.allocator.free(body);
        var request = try AotClientHttpRequest.init(runtime.allocator, "POST", url, body, true);
        errdefer request.deinit();
        try request.addHeader("Content-Type", "application/x-www-form-urlencoded");
        return request;
    }
    const boundary = "----lnako-form-boundary-3.7.24";
    const body = try aotClientMultipartFields(runtime, parameters, boundary);
    defer runtime.allocator.free(body);
    var request = try AotClientHttpRequest.init(runtime.allocator, "POST", url, body, true);
    errdefer request.deinit();
    if (omit_boundary_header) {
        try request.addHeader("Content-Type", "multipart/form-data");
    } else {
        const content_type = try std.fmt.allocPrint(runtime.allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer runtime.allocator.free(content_type);
        try request.addHeader("Content-Type", content_type);
    }
    return request;
}

pub fn aotClientPrepareDiscord(runtime: *Runtime, url_value: Value, message_value: Value) !AotClientHttpRequest {
    const url = try valueUtf8LossyAlloc(runtime, url_value);
    defer runtime.allocator.free(url);
    var roots = [_]Value{ message_value, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createDictionary(&.{});
    try aotHttpDictionarySetUtf8(runtime, roots[1], "content", roots[0]);
    roots[2] = try jsonEncodeBuiltin(runtime, roots[1], false);
    const body = try valueUtf8LossyAlloc(runtime, roots[2]);
    defer runtime.allocator.free(body);
    var request = try AotClientHttpRequest.init(runtime.allocator, "POST", url, body, true);
    errdefer request.deinit();
    try request.addHeader("Content-Type", "application/json");
    return request;
}

pub fn aotClientPrepareDiscordFile(runtime: *Runtime, url_value: Value, file_value: Value, message_value: Value) !AotClientHttpRequest {
    const url = try valueUtf8LossyAlloc(runtime, url_value);
    defer runtime.allocator.free(url);
    const path = try valueUtf8LossyAlloc(runtime, file_value);
    defer runtime.allocator.free(path);
    const message = try valueUtf8LossyAlloc(runtime, message_value);
    defer runtime.allocator.free(message);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(aotRuntimeIo(runtime), path, runtime.allocator, .limited(1024 * 1024 * 1024));
    defer runtime.allocator.free(bytes);
    const boundary = "----lnako-discord-boundary-3.7.24";
    var body: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer body.deinit();
    try body.writer.print("--{s}\r\nContent-Disposition: form-data; name=\"content\"\r\n\r\n{s}\r\n", .{ boundary, message });
    try body.writer.print("--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{ boundary, nodeBasename(path) });
    try body.writer.writeAll(bytes);
    try body.writer.print("\r\n--{s}--\r\n", .{boundary});
    var request = try AotClientHttpRequest.init(runtime.allocator, "POST", url, body.written(), true);
    errdefer request.deinit();
    const content_type = try std.fmt.allocPrint(runtime.allocator, "multipart/form-data; boundary={s}", .{boundary});
    defer runtime.allocator.free(content_type);
    try request.addHeader("Content-Type", content_type);
    return request;
}

pub fn aotClientHttpMethod(source: []const u8) !std.http.Method {
    inline for (@typeInfo(std.http.Method).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(source, field.name)) return @enumFromInt(field.value);
    }
    return error.UnsupportedHttpMethod;
}

pub fn aotClientHttpRequest(runtime: *Runtime, request: *const AotClientHttpRequest) !AotClientHttpResult {
    var client: std.http.Client = .{ .allocator = runtime.allocator, .io = aotRuntimeIo(runtime) };
    defer client.deinit();
    const headers = try runtime.allocator.alloc(std.http.Header, request.headers.items.len);
    defer runtime.allocator.free(headers);
    for (request.headers.items, headers) |source, *target| target.* = .{ .name = source.name, .value = source.value };
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    errdefer output.deinit();
    const fetched = try client.fetch(.{
        .location = .{ .url = request.url },
        .method = try aotClientHttpMethod(request.method),
        .payload = if (request.has_body) request.body else null,
        .extra_headers = headers,
        .response_writer = &output.writer,
    });
    const body = try output.toOwnedSlice();
    return .{
        .body = body,
        .status = @intFromEnum(fetched.status),
        .content_length_zero = body.len == 0,
    };
}

pub fn aotClientHttpBodyValue(runtime: *Runtime, body: []const u8, kind: AotClientHttpBodyKind, status: u16, content_length_zero: bool) !Value {
    return switch (kind) {
        .text => runtimeUtf8StringLossy(runtime, body),
        .binary => runtime.createArrayBuffer(body),
        .json => blk: {
            if (body.len == 0 and (status == 204 or status == 205 or content_length_zero)) break :blk .{ .tag = @intFromEnum(Tag.null_value) };
            var source = try runtimeUtf8StringLossy(runtime, body);
            var frame = RootFrame{};
            runtime.pushRoots(&frame, @ptrCast(&source), 1);
            defer runtime.popRoots(&frame);
            break :blk try jsonDecodeBuiltin(runtime, source);
        },
    };
}

pub fn aotClientHttpResponseValue(runtime: *Runtime, result: AotClientHttpResult) !Value {
    var roots = [_]Value{ try runtime.createDictionary(&.{}), .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = numberValue(@floatFromInt(result.status));
    try aotHttpDictionarySetUtf8(runtime, roots[0], "status", roots[1]);
    roots[2] = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(result.status >= 200 and result.status < 300) };
    try aotHttpDictionarySetUtf8(runtime, roots[0], "ok", roots[2]);
    roots[3] = .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 };
    try aotHttpDictionarySetUtf8(runtime, roots[0], "__lnako_http_response", roots[3]);
    roots[4] = try runtime.createBytes(result.body);
    try aotHttpDictionarySetUtf8(runtime, roots[0], "__lnako_body", roots[4]);
    return roots[0];
}

pub fn isAotHttpResponse(value: Value) bool {
    const marker = aotClientDictionaryGetAscii(value, "__lnako_http_response") orelse return false;
    return marker.tag == @intFromEnum(Tag.boolean) and marker.payload != 0;
}

pub fn aotClientHttpResponseBody(value: Value) !Value {
    if (!isAotHttpResponse(value)) return error.HttpResponseExpected;
    const body = aotClientDictionaryGetAscii(value, "__lnako_body") orelse return error.HttpResponseExpected;
    if (body.tag != @intFromEnum(Tag.byte_buffer)) return error.HttpResponseExpected;
    return body;
}

pub fn aotClientHttpResponseStatus(value: Value) u16 {
    const status = aotClientDictionaryGetAscii(value, "status") orelse return 0;
    if (status.tag != @intFromEnum(Tag.number)) return 0;
    const number: f64 = @bitCast(status.payload);
    return if (std.math.isFinite(number) and number >= 0 and number <= 999) @intFromFloat(number) else 0;
}

pub fn aotClientHttpBodyKind(runtime: *Runtime, value: Value) !?AotClientHttpBodyKind {
    const text = try valueUtf8LossyAlloc(runtime, value);
    defer runtime.allocator.free(text);
    if (std.ascii.eqlIgnoreCase(text, "TEXT") or std.mem.eql(u8, text, "テキスト")) return .text;
    if (std.ascii.eqlIgnoreCase(text, "JSON")) return .json;
    if (std.ascii.eqlIgnoreCase(text, "BLOB") or std.ascii.eqlIgnoreCase(text, "ARRAY") or std.mem.eql(u8, text, "配列")) return .binary;
    if (std.ascii.eqlIgnoreCase(text, "BODY") or std.mem.eql(u8, text, "本体")) return null;
    return error.InvalidAjaxContentType;
}

pub fn aotClientPrepareHttpCommand(runtime: *Runtime, ajax_options: ?*Value, command: aot_builtin.Command, arguments: []const Value) !AotClientHttpRequest {
    return switch (command) {
        .node_ajax_send_callback, .node_ajax_receive_callback, .node_get_send_callback => blk: {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            break :blk try aotClientPrepareAjax(runtime, ajax_options, arguments[1]);
        },
        .node_post_send_callback => blk: {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            break :blk try aotClientPreparePost(runtime, arguments[1], arguments[2], false, false);
        },
        .node_post_form_send_callback => blk: {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            break :blk try aotClientPreparePost(runtime, arguments[1], arguments[2], true, true);
        },
        .node_ajax_response_promise, .node_http_response_promise, .node_get_response_promise => blk: {
            if (arguments.len < 1) return error.InvalidArgumentCount;
            break :blk try aotClientPrepareAjax(runtime, ajax_options, arguments[0]);
        },
        .node_post_response_promise => blk: {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            break :blk try aotClientPreparePost(runtime, arguments[0], arguments[1], false, false);
        },
        .node_post_form_response_promise => blk: {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            break :blk try aotClientPreparePost(runtime, arguments[0], arguments[1], true, false);
        },
        .node_ajax_receive, .node_ajax_text_get, .node_ajax_json_get, .node_ajax_binary_get => blk: {
            if (arguments.len < 1) return error.InvalidArgumentCount;
            break :blk try aotClientPrepareAjax(runtime, ajax_options, arguments[0]);
        },
        .node_post_send, .node_post_form_send => blk: {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            break :blk try aotClientPreparePost(runtime, arguments[0], arguments[1], command == .node_post_form_send, false);
        },
        .node_discord_send => blk: {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            break :blk try aotClientPrepareDiscord(runtime, arguments[0], arguments[1]);
        },
        .node_discord_file_send => blk: {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            break :blk try aotClientPrepareDiscordFile(runtime, arguments[0], arguments[1], arguments[2]);
        },
        else => error.UnknownCommand,
    };
}

pub fn aotClientIsCallbackCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_ajax_send_callback, .node_ajax_receive_callback, .node_get_send_callback, .node_post_send_callback, .node_post_form_send_callback => true,
        else => false,
    };
}

pub fn aotClientIsResponsePromiseCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_ajax_response_promise, .node_http_response_promise, .node_get_response_promise, .node_post_response_promise, .node_post_form_response_promise => true,
        else => false,
    };
}

pub fn nodeHttpBuiltin(runtime: *Runtime, ajax_options: ?*Value, ajax_onerror: ?*Value, target: ?*Value, command: aot_builtin.Command, arguments: []const Value) !Value {
    var arguments_frame = RootFrame{};
    if (arguments.len > 0) runtime.pushRoots(&arguments_frame, @constCast(arguments.ptr), arguments.len);
    defer if (arguments.len > 0) runtime.popRoots(&arguments_frame);

    if (command == .node_ajax_content_get) {
        if (arguments.len < 2) return error.InvalidArgumentCount;
        const body = try aotClientHttpResponseBody(arguments[0]);
        const kind = try aotClientHttpBodyKind(runtime, arguments[1]);
        if (kind == null) return body;
        var roots = [_]Value{ try createAotPromise(runtime), .{} };
        var frame = RootFrame{};
        runtime.pushRoots(&frame, &roots, roots.len);
        defer runtime.popRoots(&frame);
        const body_buffer = body.object().?.payload.byte_buffer;
        roots[1] = aotClientHttpBodyValue(runtime, body_buffer.bytes, kind.?, aotClientHttpResponseStatus(arguments[0]), body_buffer.bytes.len == 0) catch |failure| {
            roots[1] = try callbackFailureReason(runtime, failure);
            try rejectAotPromise(runtime, roots[0].object().?, roots[1]);
            return roots[0];
        };
        try resolveAotPromise(runtime, roots[0].object().?, roots[1]);
        return roots[0];
    }

    if (aotClientIsCallbackCommand(command)) {
        if (arguments.len < 2) return error.InvalidArgumentCount;
        var callback = try resolveAotCallback(runtime, arguments[0]);
        var callback_frame = RootFrame{};
        runtime.pushRoots(&callback_frame, @ptrCast(&callback), 1);
        defer runtime.popRoots(&callback_frame);
        var request = try aotClientPrepareHttpCommand(runtime, ajax_options, command, arguments);
        defer request.deinit();
        var result = aotClientHttpRequest(runtime, &request) catch |failure| AotClientHttpResult{
            .body = try runtime.allocator.dupe(u8, &.{}),
            .failure = failure,
        };
        runtime.client_http_tasks.append(runtime.allocator, .{
            .result = result,
            .mode = .callback,
            .callback = callback,
            .target = target,
            .onerror = ajax_onerror,
        }) catch |failure| {
            result.deinit(runtime.allocator);
            return failure;
        };
        return .{};
    }

    if (aotClientIsResponsePromiseCommand(command)) {
        var roots = [_]Value{ try createAotPromise(runtime), .{} };
        var frame = RootFrame{};
        runtime.pushRoots(&frame, &roots, roots.len);
        defer runtime.popRoots(&frame);
        var request = try aotClientPrepareHttpCommand(runtime, ajax_options, command, arguments);
        defer request.deinit();
        var result = aotClientHttpRequest(runtime, &request) catch |failure| AotClientHttpResult{
            .body = try runtime.allocator.dupe(u8, &.{}),
            .failure = failure,
        };
        runtime.client_http_tasks.append(runtime.allocator, .{
            .result = result,
            .mode = .response_promise,
            .promise = roots[0],
        }) catch |failure| {
            result.deinit(runtime.allocator);
            return failure;
        };
        return roots[0];
    }

    if (command == .node_ajax_receive) {
        var request = try aotClientPrepareHttpCommand(runtime, ajax_options, command, arguments);
        defer request.deinit();
        var result = aotClientHttpRequest(runtime, &request) catch |failure| AotClientHttpResult{
            .body = try runtime.allocator.dupe(u8, &.{}),
            .failure = failure,
        };
        runtime.client_http_tasks.append(runtime.allocator, .{ .result = result, .mode = .set_target, .target = target }) catch |failure| {
            result.deinit(runtime.allocator);
            return failure;
        };
        return .{};
    }

    if (command == .node_discord_send or command == .node_discord_file_send) {
        var request = try aotClientPrepareHttpCommand(runtime, ajax_options, command, arguments);
        defer request.deinit();
        var result = try aotClientHttpRequest(runtime, &request);
        defer result.deinit(runtime.allocator);
        if (result.status < 200 or result.status >= 300) return error.DiscordRequestFailed;
        return .{};
    }

    const result_kind: ?AotClientHttpBodyKind = switch (command) {
        .node_post_send, .node_post_form_send, .node_ajax_text_get => .text,
        .node_ajax_json_get => .json,
        .node_ajax_binary_get => .binary,
        else => null,
    };
    if (result_kind) |kind| {
        var request = try aotClientPrepareHttpCommand(runtime, ajax_options, command, arguments);
        defer request.deinit();
        var result = try aotClientHttpRequest(runtime, &request);
        defer result.deinit(runtime.allocator);
        if (result.failure) |failure| return failure;
        return aotClientHttpBodyValue(runtime, result.body, kind, result.status, result.content_length_zero);
    }
    return error.UnknownCommand;
}

pub fn appendNodeUriComponent(writer: *std.Io.Writer, source: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (source) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-_.!~*'()", byte) != null) {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}
