const std = @import("std");
const common = @import("../system/common.zig");
const json = @import("../system/json.zig");
const shared = @import("shared.zig");
const fs = @import("filesystem.zig");

const Value = shared.Value;
const Runtime = shared.Runtime;
const Context = shared.Context;
const State = shared.State;
const Effects = shared.Effects;
const CommandResult = shared.CommandResult;
const HttpRequest = shared.HttpRequest;
const HttpHeader = shared.HttpHeader;
const HttpResultKind = shared.HttpResultKind;
const valueUtf8 = shared.valueUtf8;
const valueBytes = shared.valueBytes;
const isAny = shared.isAny;
const dictionaryGetAscii = shared.dictionaryGetAscii;
const setDictionary = shared.setDictionary;
const upperAsciiAlloc = shared.upperAsciiAlloc;

pub fn callHttp(runtime: *Runtime, state: *State, context: Context, effects_optional: ?Effects, name: []const u8, arguments: []const Value) !?Value {
    const effects = effects_optional;
    if (std.mem.eql(u8, name, "POSTデータ生成")) return @as(?Value, try postData(runtime, common.argument(arguments, 0)));
    if (std.mem.eql(u8, name, "AJAXオプション設定")) {
        const actual = effects orelse return error.CallbackExecutionUnavailable;
        try actual.setGlobal("AJAXオプション", common.argument(arguments, 0));
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "AJAX失敗時")) {
        const actual = effects orelse return error.CallbackExecutionUnavailable;
        try actual.setGlobal("AJAX:ONERROR", common.argument(arguments, 0));
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "LINE送信") or std.mem.eql(u8, name, "LINE画像送信")) {
        const message = try std.fmt.allocPrint(
            runtime.allocator(),
            "『{s}』は2025年4月で使えなくなりました。[詳細URL] https://nadesi.com/v3/doc/go.php?4670",
            .{name},
        );
        defer runtime.allocator().free(message);
        try runtime.setFailureMessage(message);
        return error.LineNotifyDiscontinued;
    }
    if (std.mem.eql(u8, name, "AJAX内容取得")) {
        const response = common.argument(arguments, 0);
        const kind_text = try valueUtf8(runtime, common.argument(arguments, 1));
        defer runtime.allocator().free(kind_text);
        const kind = if (std.ascii.eqlIgnoreCase(kind_text, "TEXT") or std.mem.eql(u8, kind_text, "テキスト"))
            HttpResultKind.text
        else if (std.ascii.eqlIgnoreCase(kind_text, "JSON"))
            HttpResultKind.json
        else if (std.ascii.eqlIgnoreCase(kind_text, "BLOB") or std.ascii.eqlIgnoreCase(kind_text, "ARRAY") or std.mem.eql(u8, kind_text, "配列"))
            HttpResultKind.binary
        else if (std.ascii.eqlIgnoreCase(kind_text, "BODY") or std.mem.eql(u8, kind_text, "本体"))
            return @as(?Value, try responseBody(response))
        else
            return error.InvalidAjaxContentType;
        return @as(?Value, try settledHttpContent(runtime, response, kind));
    }

    const callback_kind = isAny(name, &.{ "AJAX送信時", "AJAX受信時", "GET送信時", "POST送信時", "POSTフォーム送信時" });
    const response_promise = isAny(name, &.{ "AJAX保障送信", "HTTP保障取得", "GET保障送信", "POST保障送信", "POSTフォーム保障送信" });
    const text_promise = isAny(name, &.{ "POST送信", "POSTフォーム送信", "AJAXテキスト取得" });
    const json_promise = std.mem.eql(u8, name, "AJAX_JSON取得");
    const binary_promise = std.mem.eql(u8, name, "AJAXバイナリ取得");
    const set_target = std.mem.eql(u8, name, "AJAX受信");
    const discord = std.mem.eql(u8, name, "DISCORD送信") or std.mem.eql(u8, name, "DISCORDファイル送信");
    if (!callback_kind and !response_promise and !text_promise and !json_promise and !binary_promise and !set_target and !discord) return null;

    const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
    var request = if (std.mem.eql(u8, name, "POST送信時") or std.mem.eql(u8, name, "POST保障送信") or std.mem.eql(u8, name, "POST送信"))
        try preparePostRequest(runtime, common.argument(arguments, if (callback_kind) 1 else 0), common.argument(arguments, if (callback_kind) 2 else 1), false, false)
    else if (std.mem.eql(u8, name, "POSTフォーム送信時") or std.mem.eql(u8, name, "POSTフォーム保障送信") or std.mem.eql(u8, name, "POSTフォーム送信"))
        try preparePostRequest(runtime, common.argument(arguments, if (callback_kind) 1 else 0), common.argument(arguments, if (callback_kind) 2 else 1), true, std.mem.eql(u8, name, "POSTフォーム送信時"))
    else if (std.mem.eql(u8, name, "DISCORD送信"))
        try prepareDiscordRequest(runtime, common.argument(arguments, 0), common.argument(arguments, 1))
    else if (std.mem.eql(u8, name, "DISCORDファイル送信"))
        try prepareDiscordFileRequest(runtime, context, common.argument(arguments, 0), common.argument(arguments, 1), common.argument(arguments, 2))
    else
        try prepareAjaxRequest(runtime, actual_effects, common.argument(arguments, if (callback_kind) 1 else 0));
    defer request.deinit();
    if (text_promise or json_promise or binary_promise or discord) {
        const perform = context.httpRequestFn orelse return error.HttpRequestUnavailable;
        var result = try perform(context.context, runtime.allocator(), request.view());
        defer result.deinit(runtime.allocator());
        if (result.exit_code != 0) return error.HttpRequestFailed;
        const status = result.http_status orelse 0;
        if (discord) {
            if (status < 200 or status >= 300) return error.DiscordRequestFailed;
            return @as(?Value, .undefined);
        }
        return @as(?Value, try httpBodyValue(runtime, result.stdout, if (json_promise) .json else if (binary_promise) .binary else .text, status));
    }
    const start = context.startHttpFn orelse return error.HttpRequestUnavailable;
    const token = try start(context.context, request.view());
    if (set_target) {
        try state.pending_operations.append(runtime.allocator(), .{ .token = token, .mode = .http_set_target });
        return @as(?Value, .undefined);
    }
    if (callback_kind) {
        var callback = try actual_effects.resolve(common.argument(arguments, 0));
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&callback);
        try state.pending_operations.append(runtime.allocator(), .{ .token = token, .mode = .http_callback, .callback = callback });
        return @as(?Value, .undefined);
    }
    var promise = try runtime.createPromise();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&promise);
    try state.pending_operations.append(runtime.allocator(), .{
        .token = token,
        .mode = .http_promise,
        .promise = promise,
        .http_result = if (response_promise) .response else .text,
        .require_success = response_promise,
    });
    return @as(?Value, promise);
}

const PreparedHttpRequest = struct {
    allocator: std.mem.Allocator,
    method: []u8,
    url: []u8,
    headers: std.ArrayList(HttpHeader) = .empty,
    body: []u8,
    has_body: bool,

    fn init(allocator: std.mem.Allocator, method: []const u8, url: []const u8, body: []const u8, has_body: bool) !PreparedHttpRequest {
        const owned_method = try allocator.dupe(u8, method);
        errdefer allocator.free(owned_method);
        const owned_url = try allocator.dupe(u8, url);
        errdefer allocator.free(owned_url);
        return .{
            .allocator = allocator,
            .method = owned_method,
            .url = owned_url,
            .body = try allocator.dupe(u8, body),
            .has_body = has_body,
        };
    }

    fn deinit(self: *PreparedHttpRequest) void {
        self.allocator.free(self.method);
        self.allocator.free(self.url);
        self.allocator.free(self.body);
        for (self.headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.headers.deinit(self.allocator);
        self.* = undefined;
    }

    fn addHeader(self: *PreparedHttpRequest, name: []const u8, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.headers.append(self.allocator, .{ .name = owned_name, .value = owned_value });
    }

    fn view(self: PreparedHttpRequest) HttpRequest {
        return .{ .method = self.method, .url = self.url, .headers = self.headers.items, .body = self.body, .has_body = self.has_body };
    }
};

fn prepareAjaxRequest(runtime: *Runtime, effects: Effects, url_value: Value) !PreparedHttpRequest {
    const url = try valueUtf8(runtime, url_value);
    defer runtime.allocator().free(url);
    var result = try PreparedHttpRequest.init(runtime.allocator(), "GET", url, &.{}, false);
    errdefer result.deinit();
    const option = effects.getGlobal("AJAXオプション") orelse .undefined;
    if (option != .dictionary) return result;
    if (dictionaryGetAscii(option.dictionary, "method")) |method_value| {
        const method = try valueUtf8(runtime, method_value);
        defer runtime.allocator().free(method);
        runtime.allocator().free(result.method);
        result.method = try upperAsciiAlloc(runtime.allocator(), method);
    }
    if (dictionaryGetAscii(option.dictionary, "body")) |body_value| {
        runtime.allocator().free(result.body);
        result.body = try valueBytes(runtime, body_value);
        result.has_body = true;
    }
    if (dictionaryGetAscii(option.dictionary, "headers")) |headers_value| if (headers_value == .dictionary) {
        for (headers_value.dictionary.keys(), headers_value.dictionary.values()) |key, value| {
            const key_utf8 = try key.toUtf8Lossy(runtime.allocator());
            defer runtime.allocator().free(key_utf8);
            const value_utf8 = try valueUtf8(runtime, value);
            defer runtime.allocator().free(value_utf8);
            try result.addHeader(key_utf8, value_utf8);
        }
    };
    return result;
}

fn preparePostRequest(runtime: *Runtime, url_value: Value, parameters: Value, multipart: bool, omit_boundary_header: bool) !PreparedHttpRequest {
    const url = try valueUtf8(runtime, url_value);
    defer runtime.allocator().free(url);
    if (!multipart) {
        const body_value = try postData(runtime, parameters);
        const body = try body_value.string.toUtf8Lossy(runtime.allocator());
        defer runtime.allocator().free(body);
        var result = try PreparedHttpRequest.init(runtime.allocator(), "POST", url, body, true);
        errdefer result.deinit();
        try result.addHeader("Content-Type", "application/x-www-form-urlencoded");
        return result;
    }
    const boundary = "----lnako-form-boundary-3.7.24";
    const body = try multipartFields(runtime, parameters, boundary);
    defer runtime.allocator().free(body);
    var result = try PreparedHttpRequest.init(runtime.allocator(), "POST", url, body, true);
    errdefer result.deinit();
    if (omit_boundary_header) {
        try result.addHeader("Content-Type", "multipart/form-data");
    } else {
        const content_type = try std.fmt.allocPrint(runtime.allocator(), "multipart/form-data; boundary={s}", .{boundary});
        defer runtime.allocator().free(content_type);
        try result.addHeader("Content-Type", content_type);
    }
    return result;
}

fn prepareDiscordRequest(runtime: *Runtime, url_value: Value, message_value: Value) !PreparedHttpRequest {
    const url = try valueUtf8(runtime, url_value);
    defer runtime.allocator().free(url);
    var payload = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&payload);
    try common.dictionarySetUtf8(runtime, payload.dictionary, "content", message_value);
    const encoded = (try json.call(runtime, "JSON変換", &.{payload})).?;
    const body = try encoded.string.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(body);
    var result = try PreparedHttpRequest.init(runtime.allocator(), "POST", url, body, true);
    errdefer result.deinit();
    try result.addHeader("Content-Type", "application/json");
    return result;
}

fn prepareDiscordFileRequest(runtime: *Runtime, context: Context, url_value: Value, file_value: Value, message_value: Value) !PreparedHttpRequest {
    const url = try valueUtf8(runtime, url_value);
    defer runtime.allocator().free(url);
    const path = try valueUtf8(runtime, file_value);
    defer runtime.allocator().free(path);
    const message = try valueUtf8(runtime, message_value);
    defer runtime.allocator().free(message);
    const bytes = try context.readFile(runtime.allocator(), path);
    defer runtime.allocator().free(bytes);
    const boundary = "----lnako-discord-boundary-3.7.24";
    var body: std.Io.Writer.Allocating = .init(runtime.allocator());
    defer body.deinit();
    try body.writer.print("--{s}\r\nContent-Disposition: form-data; name=\"content\"\r\n\r\n{s}\r\n", .{ boundary, message });
    try body.writer.print("--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{ boundary, fs.nodeBasename(path) });
    try body.writer.writeAll(bytes);
    try body.writer.print("\r\n--{s}--\r\n", .{boundary});
    var result = try PreparedHttpRequest.init(runtime.allocator(), "POST", url, body.written(), true);
    errdefer result.deinit();
    const content_type = try std.fmt.allocPrint(runtime.allocator(), "multipart/form-data; boundary={s}", .{boundary});
    defer runtime.allocator().free(content_type);
    try result.addHeader("Content-Type", content_type);
    return result;
}

fn postData(runtime: *Runtime, parameters: Value) !Value {
    var output: std.Io.Writer.Allocating = .init(runtime.allocator());
    defer output.deinit();
    if (parameters == .dictionary) {
        for (parameters.dictionary.keys(), parameters.dictionary.values(), 0..) |key, value, index| {
            if (index > 0) try output.writer.writeByte('&');
            const key_utf8 = try key.toUtf8Lossy(runtime.allocator());
            defer runtime.allocator().free(key_utf8);
            const value_utf8 = try valueUtf8(runtime, value);
            defer runtime.allocator().free(value_utf8);
            try appendUriComponent(&output.writer, key_utf8);
            try output.writer.writeByte('=');
            try appendUriComponent(&output.writer, value_utf8);
        }
    }
    return runtime.stringUtf8(output.written());
}

fn multipartFields(runtime: *Runtime, parameters: Value, boundary: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(runtime.allocator());
    defer output.deinit();
    if (parameters == .dictionary) for (parameters.dictionary.keys(), parameters.dictionary.values()) |key, value| {
        const key_utf8 = try key.toUtf8Lossy(runtime.allocator());
        defer runtime.allocator().free(key_utf8);
        const value_utf8 = try valueUtf8(runtime, value);
        defer runtime.allocator().free(value_utf8);
        try output.writer.print("--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{ boundary, key_utf8, value_utf8 });
    };
    try output.writer.print("--{s}--\r\n", .{boundary});
    return output.toOwnedSlice();
}

fn appendUriComponent(writer: *std.Io.Writer, source: []const u8) !void {
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

pub fn settledHttpContent(runtime: *Runtime, response: Value, kind: HttpResultKind) !Value {
    var promise = try runtime.createPromise();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&promise);
    var body = try responseBody(response);
    try roots.protect(&body);
    const value = httpBodyValue(runtime, body.bytes.bytes, kind, responseStatus(response)) catch |err| {
        const reason = try runtime.stringUtf8(@errorName(err));
        try runtime.rejectPromise(promise.promise, reason);
        return promise;
    };
    try runtime.resolvePromise(promise.promise, value);
    return promise;
}

pub fn responseBody(response: Value) !Value {
    if (response != .dictionary) return error.HttpResponseExpected;
    return dictionaryGetAscii(response.dictionary, "__lnako_body") orelse return error.HttpResponseExpected;
}

pub fn responseStatus(response: Value) u16 {
    if (response != .dictionary) return 0;
    const value = dictionaryGetAscii(response.dictionary, "status") orelse return 0;
    return if (value == .number and value.number >= 0 and value.number <= 999) @intFromFloat(value.number) else 0;
}

pub fn httpBodyValue(runtime: *Runtime, body: []const u8, kind: HttpResultKind, status: u16) !Value {
    return switch (kind) {
        .text => runtime.stringUtf8Lossy(body),
        .binary => runtime.createArrayBuffer(body),
        .none => .undefined,
        .json => blk: {
            if (body.len == 0 and (status == 204 or status == 205)) break :blk .null_value;
            const source = try runtime.stringUtf8Lossy(body);
            break :blk (try json.call(runtime, "JSON取得", &.{source})).?;
        },
        .response => error.InvalidHttpResultKind,
    };
}

pub fn httpResponseValue(runtime: *Runtime, result: CommandResult) !Value {
    var response = try runtime.createDictionaryKind(.http_response);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&response);
    const status = result.http_status orelse 0;
    try common.dictionarySetUtf8(runtime, response.dictionary, "status", .{ .number = @floatFromInt(status) });
    try common.dictionarySetUtf8(runtime, response.dictionary, "ok", .{ .boolean = status >= 200 and status < 300 });
    try common.dictionarySetUtf8(runtime, response.dictionary, "__lnako_http_response", .{ .boolean = true });
    try common.dictionarySetUtf8(runtime, response.dictionary, "__lnako_body", try runtime.createBytes(result.stdout));
    return response;
}

pub fn writeAjaxReceiveError(context: Context, result: CommandResult) !void {
    try context.writeStderr("[AJAX受信のエラー] ");
    if (result.http_status) |status| {
        var buffer: [32]u8 = undefined;
        const message = try std.fmt.bufPrint(&buffer, "Error: status={d}\n", .{status});
        try context.writeStderr(message);
    } else if (result.stderr.len > 0) {
        try context.writeStderr(result.stderr);
        if (result.stderr[result.stderr.len - 1] != '\n') try context.writeStderr("\n");
    } else try context.writeStderr("Error: fetch failed\n");
}
