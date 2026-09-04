const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const common = @import("system/common.zig");
const json = @import("system/json.zig");
const constants = @import("system/constants.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    method: []u8,
    target: []u8,
    content_type: []u8,
    body: []u8,
    too_large: bool = false,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.target);
        allocator.free(self.content_type);
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const PathStat = enum { file, directory, missing };

pub const ResolvedPath = struct {
    path: []u8,
    kind: PathStat,
};

pub const Context = struct {
    context: *anyopaque,
    startFn: *const fn (context: *anyopaque, port: u16) anyerror!u16,
    receiveFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!Request,
    respondFn: *const fn (context: *anyopaque, status: u16, headers: []const Header, body: []const u8) anyerror!void,
    holdFn: *const fn (context: *anyopaque) anyerror!void,
    resolveStaticPathFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, root: []const u8, components: []const []const u8) anyerror!?ResolvedPath,
    readStaticFileFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
    saveUploadFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, filename: []const u8, body: []const u8) anyerror![]u8,
    writeFn: ?*const fn (context: *anyopaque, bytes: []const u8) anyerror!void = null,

    fn respond(self: Context, status: u16, headers: []const Header, body: []const u8) !void {
        try self.respondFn(self.context, status, headers, body);
    }

    fn write(self: Context, bytes: []const u8) !void {
        if (self.writeFn) |function| try function(self.context, bytes);
    }
};

pub const Effects = struct {
    context: *anyopaque,
    invokeFn: *const fn (context: *anyopaque, callable: Value, arguments: []const Value) anyerror!Value,
    resolveFn: *const fn (context: *anyopaque, value: Value) anyerror!Value,
    setGlobalFn: *const fn (context: *anyopaque, name: []const u8, value: Value) anyerror!void,

    fn invoke(self: Effects, callable: Value, arguments: []const Value) !Value {
        return self.invokeFn(self.context, callable, arguments);
    }

    fn resolve(self: Effects, value: Value) !Value {
        return self.resolveFn(self.context, value);
    }

    fn setGlobal(self: Effects, name: []const u8, value: Value) !void {
        try self.setGlobalFn(self.context, name, value);
    }
};

const RouteKind = enum { static, callback };
const Route = struct {
    kind: RouteKind,
    prefix: []u8,
    path: []u8 = &.{},
    callback: Value = .undefined,

    fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        if (self.path.len > 0) allocator.free(self.path);
        self.* = undefined;
    }
};

const OwnedHeader = struct {
    name: []u8,
    value: []u8,

    fn deinit(self: *OwnedHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const State = struct {
    routes: std.ArrayList(Route) = .empty,
    response_headers: std.ArrayList(OwnedHeader) = .empty,
    started: bool = false,
    request_active: bool = false,
    response_status: u16 = 200,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.routes.items) |*route| route.deinit(allocator);
        self.routes.deinit(allocator);
        self.clearHeaders(allocator);
        self.response_headers.deinit(allocator);
        self.* = undefined;
    }

    pub fn trace(self: State, runtime: *Runtime) !void {
        for (self.routes.items) |route| try runtime.traceExternal(route.callback);
    }

    fn clearHeaders(self: *State, allocator: std.mem.Allocator) void {
        for (self.response_headers.items) |*header| header.deinit(allocator);
        self.response_headers.clearRetainingCapacity();
    }
};

pub fn install(runtime: *Runtime, installer: constants.Installer) !void {
    try installer.set("HTTPメソッド", try runtime.stringUtf8(""));
    try installer.set("GETデータ", try runtime.stringUtf8(""));
    try installer.set("POSTデータ", try runtime.stringUtf8(""));
    try installer.set("FILESデータ", try runtime.stringUtf8(""));
}

pub fn call(runtime: *Runtime, state: *State, context: Context, effects: Effects, name: []const u8, arguments: []const Value) !?Value {
    if (std.mem.eql(u8, name, "簡易HTTPサーバ起動時")) {
        if (state.started) return error.HttpServerAlreadyStarted;
        const callback = try effects.resolve(common.argument(arguments, 0));
        const port_number = try runtime.valueToNumber(common.argument(arguments, 1));
        if (!std.math.isFinite(port_number) or port_number < 0 or port_number > 65535) return error.InvalidHttpServerPort;
        const port = try context.startFn(context.context, @intFromFloat(@trunc(port_number)));
        state.started = true;
        var message: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&message, "[簡易HTTPサーバ] ポート番号({d})で監視開始\n", .{port});
        try context.write(line);
        _ = try effects.invoke(callback, &.{});
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "簡易HTTPサーバ静的パス指定")) {
        try requireStarted(state);
        const prefix = try normalizedPrefix(runtime, common.argument(arguments, 0));
        errdefer runtime.allocator().free(prefix);
        const path = try valueUtf8(runtime, common.argument(arguments, 1));
        errdefer runtime.allocator().free(path);
        try state.routes.append(runtime.allocator(), .{ .kind = .static, .prefix = prefix, .path = path });
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "簡易HTTPサーバ受信時")) {
        try requireStarted(state);
        const callback = try effects.resolve(common.argument(arguments, 0));
        const prefix = try normalizedPrefix(runtime, common.argument(arguments, 1));
        errdefer runtime.allocator().free(prefix);
        try state.routes.append(runtime.allocator(), .{ .kind = .callback, .prefix = prefix, .callback = callback });
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "簡易HTTPサーバヘッダ出力")) {
        try requireActive(state);
        const status_number = try runtime.valueToNumber(common.argument(arguments, 0));
        if (!std.math.isFinite(status_number) or status_number < 100 or status_number > 999) return error.InvalidHttpStatus;
        state.response_status = @intFromFloat(@trunc(status_number));
        state.clearHeaders(runtime.allocator());
        const headers = common.argument(arguments, 1);
        if (headers == .dictionary) for (headers.dictionary.keys(), headers.dictionary.values()) |key, value| {
            const header_name = try key.toUtf8Lossy(runtime.allocator());
            errdefer runtime.allocator().free(header_name);
            const text = try runtime.valueToString(value);
            const header_value = try text.string.toUtf8Lossy(runtime.allocator());
            errdefer runtime.allocator().free(header_value);
            try state.response_headers.append(runtime.allocator(), .{ .name = header_name, .value = header_value });
        };
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "簡易HTTPサーバ出力")) {
        try requireActive(state);
        const text = try runtime.valueToString(common.argument(arguments, 0));
        const body = try text.string.toUtf8Lossy(runtime.allocator());
        defer runtime.allocator().free(body);
        if (state.response_headers.items.len == 0) try appendHeader(runtime, state, "Content-Type", "text/html; charset=utf-8");
        try sendResponse(state, context, body);
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "簡易HTTPサーバ移動")) {
        try requireActive(state);
        const url = try valueUtf8(runtime, common.argument(arguments, 0));
        defer runtime.allocator().free(url);
        state.response_status = 302;
        state.clearHeaders(runtime.allocator());
        try appendHeader(runtime, state, "Location", url);
        const body = try std.fmt.allocPrint(runtime.allocator(), "<html><body><a href=\"{s}\">JUMP</a></body></html>", .{url});
        defer runtime.allocator().free(body);
        try sendResponse(state, context, body);
        return @as(?Value, .undefined);
    }
    return null;
}

pub fn poll(runtime: *Runtime, state: *State, context: Context, effects: Effects) !bool {
    if (!state.started) return false;
    var request = try context.receiveFn(context.context, runtime.allocator());
    defer request.deinit(runtime.allocator());
    if (request.too_large) {
        try context.respond(413, &.{}, "Request entity too large.");
        return true;
    }
    var log_buffer: std.Io.Writer.Allocating = .init(runtime.allocator());
    defer log_buffer.deinit();
    try log_buffer.writer.print("[簡易HTTPサーバ] 要求あり METHOD={s} URL={s}\n", .{ request.method, request.target });
    try context.write(log_buffer.written());

    var request_roots = runtime.rootFrame();
    defer request_roots.deinit();
    var get_data = try parseQuery(runtime, request.target);
    try request_roots.protect(&get_data);
    var files_data = try runtime.createArray();
    try request_roots.protect(&files_data);
    var post_data: Value = try runtime.createDictionary();
    try request_roots.protect(&post_data);
    if (std.ascii.eqlIgnoreCase(request.method, "POST")) post_data = try parsePost(runtime, context, request.content_type, request.body, files_data.array);
    try effects.setGlobal("HTTPメソッド", try runtime.stringUtf8(request.method));
    try effects.setGlobal("GETデータ", get_data);
    try effects.setGlobal("POSTデータ", post_data);
    try effects.setGlobal("FILESデータ", files_data);

    const path = pathOnly(request.target);
    const route = bestRoute(state.routes.items, path) orelse {
        try context.holdFn(context.context);
        return true;
    };
    if (route.kind == .static) {
        try serveStatic(runtime, context, route, path);
        return true;
    }
    state.request_active = true;
    state.response_status = 200;
    state.clearHeaders(runtime.allocator());
    if (route.callback != .function) return error.HttpServerCallbackNotCallable;
    _ = try effects.invoke(route.callback, &.{});
    if (state.request_active) {
        try context.holdFn(context.context);
        state.request_active = false;
    }
    return true;
}

fn requireStarted(state: *State) !void {
    if (!state.started) return error.HttpServerNotStarted;
}

fn requireActive(state: *State) !void {
    try requireStarted(state);
    if (!state.request_active) return error.HttpServerResponseOutsideRequest;
}

fn sendResponse(state: *State, context: Context, body: []const u8) !void {
    const headers = try std.heap.page_allocator.alloc(Header, state.response_headers.items.len);
    defer std.heap.page_allocator.free(headers);
    for (state.response_headers.items, headers) |source, *target| target.* = .{ .name = source.name, .value = source.value };
    try context.respond(state.response_status, headers, body);
    state.request_active = false;
}

fn appendHeader(runtime: *Runtime, state: *State, name: []const u8, value: []const u8) !void {
    const owned_name = try runtime.allocator().dupe(u8, name);
    errdefer runtime.allocator().free(owned_name);
    try state.response_headers.append(runtime.allocator(), .{ .name = owned_name, .value = try runtime.allocator().dupe(u8, value) });
}

fn normalizedPrefix(runtime: *Runtime, value: Value) ![]u8 {
    const source = try valueUtf8(runtime, value);
    defer runtime.allocator().free(source);
    if (source.len == 0) return runtime.allocator().dupe(u8, "/");
    if (source[0] == '/') return runtime.allocator().dupe(u8, source);
    return std.fmt.allocPrint(runtime.allocator(), "/{s}", .{source});
}

fn valueUtf8(runtime: *Runtime, value: Value) ![]u8 {
    const text = try runtime.valueToString(value);
    return text.string.toUtf8Lossy(runtime.allocator());
}

fn pathOnly(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

fn bestRoute(routes: []const Route, path: []const u8) ?Route {
    var result: ?Route = null;
    for (routes) |route| {
        if (!std.mem.startsWith(u8, path, route.prefix)) continue;
        if (result == null or route.prefix.len > result.?.prefix.len) result = route;
    }
    return result;
}

fn parseQuery(runtime: *Runtime, target: []const u8) !Value {
    var result = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    try common.dictionarySetUtf8(runtime, result.dictionary, "?URL", try runtime.stringUtf8(pathOnly(target)));
    const marker = std.mem.indexOfScalar(u8, target, '?') orelse return result;
    const query_source = target[marker + 1 ..];
    const query_end = std.mem.indexOfScalar(u8, query_source, '?') orelse query_source.len;
    var pairs = std.mem.splitScalar(u8, query_source[0..query_end], '&');
    while (pairs.next()) |pair| {
        const equal = std.mem.indexOfScalar(u8, pair, '=');
        const key = try percentDecode(runtime.allocator(), if (equal) |index| pair[0..index] else pair, false, true);
        defer runtime.allocator().free(key);
        const value_source = if (equal) |index| blk: {
            const rest = pair[index + 1 ..];
            break :blk rest[0 .. std.mem.indexOfScalar(u8, rest, '=') orelse rest.len];
        } else "undefined";
        const value = try percentDecode(runtime.allocator(), value_source, false, true);
        defer runtime.allocator().free(value);
        try common.dictionarySetUtf8(runtime, result.dictionary, key, try runtime.stringUtf8(value));
    }
    return result;
}

fn parsePost(runtime: *Runtime, context: Context, content_type: []const u8, body: []const u8, files: *value_mod.Array) !Value {
    if (std.mem.indexOf(u8, content_type, "multipart/form-data") != null) {
        const boundary = multipartBoundary(content_type) orelse return runtime.createDictionary();
        return parseMultipart(runtime, context, body, boundary, files);
    }
    if (std.ascii.indexOfIgnoreCase(content_type, "application/json") != null) {
        const source = try runtime.stringUtf8Lossy(body);
        return (json.call(runtime, "JSON取得", &.{source}) catch null) orelse source;
    }
    if (std.ascii.indexOfIgnoreCase(content_type, "application/x-www-form-urlencoded") != null) return parseUrlEncoded(runtime, body);
    return runtime.stringUtf8Lossy(body);
}

fn multipartBoundary(content_type: []const u8) ?[]const u8 {
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

fn parseUrlEncoded(runtime: *Runtime, body: []const u8) !Value {
    var result = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const equal = std.mem.indexOfScalar(u8, pair, '=');
        const key = try percentDecode(runtime.allocator(), if (equal) |index| pair[0..index] else pair, true, false);
        defer runtime.allocator().free(key);
        const value = try percentDecode(runtime.allocator(), if (equal) |index| pair[index + 1 ..] else "", true, false);
        defer runtime.allocator().free(value);
        try common.dictionarySetUtf8(runtime, result.dictionary, key, try runtime.stringUtf8Lossy(value));
    }
    return result;
}

fn parseMultipart(runtime: *Runtime, context: Context, body: []const u8, boundary: []const u8, files: *value_mod.Array) !Value {
    var fields = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&fields);
    const delimiter = try std.fmt.allocPrint(runtime.allocator(), "--{s}", .{boundary});
    defer runtime.allocator().free(delimiter);
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
        const disposition = findHeader(head, "content-disposition") orelse continue;
        const field_name = dispositionParameter(disposition, "name") orelse continue;
        if (dispositionParameter(disposition, "filename")) |filename| {
            const content_type = findHeader(head, "content-type") orelse "application/octet-stream";
            const path = try context.saveUploadFn(context.context, runtime.allocator(), filename, part);
            defer runtime.allocator().free(path);
            var file = try runtime.createDictionary();
            try roots.protect(&file);
            try common.dictionarySetUtf8(runtime, file.dictionary, "fieldName", try runtime.stringUtf8(field_name));
            try common.dictionarySetUtf8(runtime, file.dictionary, "name", try runtime.stringUtf8(filename));
            try common.dictionarySetUtf8(runtime, file.dictionary, "path", try runtime.stringUtf8(path));
            try common.dictionarySetUtf8(runtime, file.dictionary, "size", .{ .number = @floatFromInt(part.len) });
            try common.dictionarySetUtf8(runtime, file.dictionary, "type", try runtime.stringUtf8(content_type));
            _ = try files.push(file);
        } else try common.dictionarySetUtf8(runtime, fields.dictionary, field_name, try runtime.stringUtf8Lossy(part));
    }
    return fields;
}

fn findHeader(head: []const u8, expected: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (std.mem.endsWith(u8, line, "\r")) line = line[0 .. line.len - 1];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), expected)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn dispositionParameter(disposition: []const u8, expected: []const u8) ?[]const u8 {
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

fn percentDecode(allocator: std.mem.Allocator, source: []const u8, plus_as_space: bool, strict: bool) ![]u8 {
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

fn serveStatic(runtime: *Runtime, context: Context, route: Route, path: []const u8) !void {
    const relative_raw = path[@min(route.prefix.len, path.len)..];
    var components = try staticPathComponents(runtime.allocator(), relative_raw);
    defer freeStaticPathComponents(runtime.allocator(), &components);
    const resolved = (try context.resolveStaticPathFn(context.context, runtime.allocator(), route.path, components.items)) orelse {
        return context.respond(404, &.{}, "<html><meta charset=\"utf-8\"><body><h1>404 見当たりません。</h1></body></html>");
    };
    defer runtime.allocator().free(resolved.path);
    if (resolved.kind != .file) return context.respond(404, &.{}, "<html><meta charset=\"utf-8\"><body><h1>404 見当たりません。</h1></body></html>");
    const body = context.readStaticFileFn(context.context, runtime.allocator(), resolved.path) catch |err| switch (err) {
        error.StreamTooLong => return context.respond(413, &.{}, "<html><meta charset=\"utf-8\"><body><h1>413 要求が大きすぎます。</h1></body></html>"),
        else => return err,
    };
    defer runtime.allocator().free(body);
    try context.respond(200, &.{.{ .name = "Content-Type", .value = mimeType(resolved.path) }}, body);
}

fn staticPathComponents(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList([]u8) {
    var result: std.ArrayList([]u8) = .empty;
    errdefer freeStaticPathComponents(allocator, &result);
    var it = std.mem.splitScalar(u8, source, '/');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        const decoded = try percentDecode(allocator, raw, false, true);
        if (decoded.len == 0 or std.mem.eql(u8, decoded, ".") or std.mem.eql(u8, decoded, "..")) {
            allocator.free(decoded);
            return error.InvalidHttpStaticPath;
        }
        if (std.mem.indexOfAny(u8, decoded, "\\\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f") != null) {
            allocator.free(decoded);
            return error.InvalidHttpStaticPath;
        }
        if (decoded.len > 255) {
            allocator.free(decoded);
            return error.InvalidHttpStaticPath;
        }
        try result.append(allocator, decoded);
    }
    return result;
}

fn freeStaticPathComponents(allocator: std.mem.Allocator, components: *std.ArrayList([]u8)) void {
    for (components.items) |item| allocator.free(item);
    components.deinit(allocator);
}

fn mimeType(path: []const u8) []const u8 {
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

test "URLのクエリを公式互換で復号する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var result = try parseQuery(&runtime, "/a?x=A%20B&plus=A+B");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    const url = try dictionaryUtf8(&runtime, result.dictionary, "?URL");
    defer runtime.allocator().free(url);
    const x = try dictionaryUtf8(&runtime, result.dictionary, "x");
    defer runtime.allocator().free(x);
    const plus = try dictionaryUtf8(&runtime, result.dictionary, "plus");
    defer runtime.allocator().free(plus);
    try std.testing.expectEqualStrings("/a", url);
    try std.testing.expectEqualStrings("A B", x);
    try std.testing.expectEqualStrings("A+B", plus);
}

test "URLのクエリは重複キーと余分な区切りを公式splitどおり扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var result = try parseQuery(&runtime, "/a?duplicate=first&duplicate=last&flag&raw=a=b&empty=");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    const duplicate = try dictionaryUtf8(&runtime, result.dictionary, "duplicate");
    defer runtime.allocator().free(duplicate);
    const flag = try dictionaryUtf8(&runtime, result.dictionary, "flag");
    defer runtime.allocator().free(flag);
    const raw = try dictionaryUtf8(&runtime, result.dictionary, "raw");
    defer runtime.allocator().free(raw);
    const empty = try dictionaryUtf8(&runtime, result.dictionary, "empty");
    defer runtime.allocator().free(empty);
    try std.testing.expectEqualStrings("last", duplicate);
    try std.testing.expectEqualStrings("undefined", flag);
    try std.testing.expectEqualStrings("a", raw);
    try std.testing.expectEqualStrings("", empty);
}

test "URLのクエリは2個目以降の疑問符を公式splitどおり無視する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var result = try parseQuery(&runtime, "/a?x=1?ignored=2");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    const x = try dictionaryUtf8(&runtime, result.dictionary, "x");
    defer runtime.allocator().free(x);
    try std.testing.expectEqualStrings("1", x);
    try std.testing.expectError(error.MissingDictionaryKey, dictionaryUtf8(&runtime, result.dictionary, "ignored"));
}

test "URLのクエリの不正percent encodingはURI malformedへ変換する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    for ([_][]const u8{ "/a?x=%", "/a?x=%2", "/a?x=%GG", "/a?x=%FF", "/a?x=%C3%28" }) |target| {
        try std.testing.expectError(error.InvalidHttpQueryEncoding, parseQuery(&runtime, target));
        runtime.clearFailureMessage();
    }
}

test "HTTP multipartは公式のboundary抽出とLFヘッダ区切りを保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try std.testing.expectEqualStrings("X", multipartBoundary("multipart/form-data; boundary=X; charset=utf-8").?);
    try std.testing.expectEqualStrings("X;Y", multipartBoundary("multipart/form-data; boundary=\"X;Y\"; charset=utf-8").?);
    try std.testing.expect(multipartBoundary("multipart/form-data") == null);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    var files = try runtime.createArray();
    try roots.protect(&files);
    const context: Context = undefined;
    var parsed = try parsePost(&runtime, context, "multipart/form-data; boundary=\"X\"; charset=utf-8", "--X\nContent-Disposition: form-data; name=\"title\"\n\nhello\n--X--\n", files.array);
    try roots.protect(&parsed);
    const title = try dictionaryUtf8(&runtime, parsed.dictionary, "title");
    defer runtime.allocator().free(title);
    try std.testing.expectEqualStrings("hello", title);

    var uppercase = try parsePost(&runtime, context, "Multipart/form-data; boundary=X", "raw", files.array);
    try roots.protect(&uppercase);
    const raw = try uppercase.string.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(raw);
    try std.testing.expectEqualStrings("raw", raw);
}

test "HTTP multipartのContent-Dispositionは公式の引用正規表現境界を保つ" {
    try std.testing.expectEqualStrings("hello;v1.txt", dispositionParameter("form-data; filename=\"hello;v1.txt\"", "name").?);
    try std.testing.expectEqualStrings("hello;v1.txt", dispositionParameter("form-data; filename=\"hello;v1.txt\"", "filename").?);
    try std.testing.expect(dispositionParameter("form-data; Name=\"title\"", "name") == null);
    try std.testing.expect(dispositionParameter("form-data; name=title", "name") == null);
    try std.testing.expect(dispositionParameter("form-data; name=\"\"", "name") == null);
}

test "静的ファイル配信のパス成分は..や制御文字、空を拒否する" {
    var components = try staticPathComponents(std.testing.allocator, "/foo/bar/baz");
    defer freeStaticPathComponents(std.testing.allocator, &components);
    try std.testing.expectEqual(3, components.items.len);
    try std.testing.expectError(error.InvalidHttpStaticPath, staticPathComponents(std.testing.allocator, "/foo/%2E%2E/bar"));
    try std.testing.expectError(error.InvalidHttpStaticPath, staticPathComponents(std.testing.allocator, "/foo/.."));
    try std.testing.expectError(error.InvalidHttpStaticPath, staticPathComponents(std.testing.allocator, "/foo/%00"));
    try std.testing.expectError(error.InvalidHttpStaticPath, staticPathComponents(std.testing.allocator, "/foo/bar%0a"));
}

fn dictionaryUtf8(runtime: *Runtime, dictionary: *value_mod.Dictionary, expected: []const u8) ![]const u8 {
    for (dictionary.keys(), dictionary.values()) |key, value| {
        const utf8 = try key.toUtf8Lossy(runtime.allocator());
        defer runtime.allocator().free(utf8);
        if (std.mem.eql(u8, utf8, expected)) return value.string.toUtf8Lossy(runtime.allocator());
    }
    return error.MissingDictionaryKey;
}
