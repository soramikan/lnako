const std = @import("std");
const builtin = @import("builtin");
const lnako = @import("lnako");
const archive = @import("archive.zig");
const http_client = @import("http_client.zig");
const process = @import("process.zig");
const network = @import("network.zig");
const environment = @import("environment.zig");

pub const CliHost = struct {
    writer: *std.Io.Writer,
    error_writer: *std.Io.Writer,
    io: std.Io,
    random_state: u64 = 0,
    fixed_now_milliseconds: ?i64 = null,
    fixed_monotonic_milliseconds: ?f64 = null,
    program_arguments: []const []const u8 = &.{},
    runtime_path: []const u8 = "lnako",
    source_path: []const u8 = ".",
    environment_names: []const []const u8 = &.{},
    environment_values: []const []const u8 = &.{},
    home_directory: ?[]const u8 = null,
    temporary_directory: []const u8 = "/tmp",
    http_server_enabled: bool = false,
    async_tasks: std.ArrayList(*AsyncOperationTask) = .empty,
    async_task_map: std.AutoHashMap(u64, *AsyncOperationTask),
    next_async_token: u64 = 1,
    async_completion_sequence: std.atomic.Value(u64) = .init(1),
    http_server: ?std.Io.net.Server = null,
    http_connection: ?std.Io.net.Stream = null,
    http_head_request: bool = false,
    held_http_connections: std.ArrayList(std.Io.net.Stream) = .empty,
    upload_sequence: u64 = 1,
    dispatch_trace_file: ?std.Io.File = null,
    compat_js_trace_file: ?std.Io.File = null,
    global_trace_file: ?std.Io.File = null,
    literal_trace_file: ?std.Io.File = null,

    pub fn deinit(self: *CliHost) void {
        if (self.dispatch_trace_file) |file| file.close(self.io);
        if (self.compat_js_trace_file) |file| file.close(self.io);
        if (self.global_trace_file) |file| file.close(self.io);
        if (self.literal_trace_file) |file| file.close(self.io);
        if (self.http_connection) |stream| stream.close(self.io);
        for (self.held_http_connections.items) |stream| stream.close(self.io);
        self.held_http_connections.deinit(std.heap.page_allocator);
        if (self.http_server) |*server| server.deinit(self.io);
        while (self.async_tasks.pop()) |task| destroyAsyncTask(task, true);
        self.async_tasks.deinit(std.heap.page_allocator);
        self.async_task_map.deinit();
    }

    pub fn interpreterHost(self: *CliHost) lnako.runtime.interpreter.Host {
        return .{
            .context = self,
            .writeFn = write,
            .dispatch_trace_path = self.environmentValue("LNAKO_DISPATCH_TRACE"),
            .dispatch_trace_writeFn = writeDispatchTrace,
            .compat_js_trace_path = self.environmentValue("LNAKO_COMPAT_JS_TRACE"),
            .compat_js_trace_writeFn = writeCompatJsTrace,
            .global_trace_path = self.environmentValue("LNAKO_GLOBAL_TRACE"),
            .global_trace_writeFn = writeGlobalTrace,
            .literal_trace_path = self.environmentValue("LNAKO_LITERAL_TRACE"),
            .literal_trace_writeFn = writeLiteralTrace,
            .sleepMillisecondsFn = sleepMilliseconds,
            .nowMillisecondsFn = nowMilliseconds,
            .monotonicMillisecondsFn = monotonicMilliseconds,
            .randomFn = random,
            .node_context = self.nodeContext(),
            .http_server_context = if (self.http_server_enabled) .{
                .context = self,
                .startFn = startHttpServer,
                .receiveFn = receiveHttpServerRequest,
                .respondFn = respondHttpServer,
                .holdFn = holdHttpServerResponse,
                .resolveStaticPathFn = resolveHttpServerStaticPath,
                .readStaticFileFn = readHttpServerStaticFile,
                .saveUploadFn = saveHttpServerUpload,
                .writeFn = write,
            } else null,
        };
    }

    fn nodeContext(self: *CliHost) ?lnako.plugins.node.Context {
        if (self.environmentValue("LNAKO_PLUGIN_ROUTE")) |route| {
            if (std.mem.eql(u8, route, "plugin_system")) return null;
        }
        return .{
            .context = self,
            .cwdFn = currentDirectory,
            .chdirFn = changeDirectory,
            .program_arguments = self.program_arguments,
            .runtime_path = self.runtime_path,
            .source_path = self.source_path,
            .environment_names = self.environment_names,
            .environment_values = self.environment_values,
            .home_directory = self.home_directory,
            .temporary_directory = self.temporary_directory,
            .readFileFn = readFile,
            .writeFileFn = writeFile,
            .statFileFn = statFile,
            .createDirectoryFn = createDirectory,
            .deletePathFn = deletePath,
            .copyPathFn = copyPath,
            .movePathFn = movePath,
            .listDirectoryFn = listDirectory,
            .runCommandFn = runCommand,
            .startCommandFn = startCommand,
            .startFileOperationFn = startFileOperation,
            .startArchiveFn = startArchive,
            .pollOperationFn = pollOperation,
            .readStdinFn = readStdin,
            .createTemporaryDirectoryFn = createTemporaryDirectory,
            .openExternalFn = openExternal,
            .writeStdoutFn = write,
            .writeStderrFn = writeError,
            .archiveFn = runArchive,
            .installInterruptFn = installInterrupt,
            .consumeInterruptFn = consumeInterrupt,
            .randomBytesFn = randomBytes,
            .networkAddressesFn = networkAddresses,
            .httpRequestFn = runHttpRequest,
            .startHttpFn = startHttp,
        };
    }

    fn environmentValue(self: *CliHost, name: []const u8) ?[]const u8 {
        for (self.environment_names, self.environment_values) |candidate, value| {
            if (std.mem.eql(u8, candidate, name)) return value;
        }
        return null;
    }

    fn writeDispatchTrace(context: *anyopaque, path: []const u8, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.dispatch_trace_file == null) {
            self.dispatch_trace_file = if (std.fs.path.isAbsolute(path))
                try std.Io.Dir.createFileAbsolute(self.io, path, .{ .exclusive = true })
            else
                try std.Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true });
        }
        try self.dispatch_trace_file.?.writeStreamingAll(self.io, bytes);
    }

    fn writeGlobalTrace(context: *anyopaque, path: []const u8, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.global_trace_file == null) {
            self.global_trace_file = if (std.fs.path.isAbsolute(path))
                try std.Io.Dir.createFileAbsolute(self.io, path, .{ .exclusive = true })
            else
                try std.Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true });
        }
        try self.global_trace_file.?.writeStreamingAll(self.io, bytes);
    }

    fn writeCompatJsTrace(context: *anyopaque, path: []const u8, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.compat_js_trace_file == null) {
            self.compat_js_trace_file = if (std.fs.path.isAbsolute(path))
                try std.Io.Dir.createFileAbsolute(self.io, path, .{ .exclusive = true })
            else
                try std.Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true });
        }
        try self.compat_js_trace_file.?.writeStreamingAll(self.io, bytes);
    }

    fn writeLiteralTrace(context: *anyopaque, path: []const u8, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.literal_trace_file == null) {
            self.literal_trace_file = if (std.fs.path.isAbsolute(path))
                try std.Io.Dir.createFileAbsolute(self.io, path, .{ .exclusive = true })
            else
                try std.Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true });
        }
        try self.literal_trace_file.?.writeStreamingAll(self.io, bytes);
    }

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try self.writer.writeAll(bytes);
        try self.writer.flush();
    }

    fn writeError(context: *anyopaque, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try self.error_writer.writeAll(bytes);
        try self.error_writer.flush();
    }

    fn sleepMilliseconds(context: *anyopaque, milliseconds: u64) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const duration = std.Io.Duration.fromMilliseconds(std.math.cast(i64, milliseconds) orelse return error.TimerOverflow);
        try std.Io.sleep(self.io, duration, .awake);
    }

    fn nowMilliseconds(context: *anyopaque) !i64 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.fixed_now_milliseconds) |fixed| return fixed;
        const nanoseconds = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        return @intCast(@divTrunc(nanoseconds, 1_000_000));
    }

    fn monotonicMilliseconds(context: *anyopaque) !f64 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.fixed_monotonic_milliseconds) |fixed| return fixed;
        const nanoseconds = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        return @as(f64, @floatFromInt(nanoseconds)) / 1_000_000;
    }

    fn random(context: *anyopaque) !f64 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.random_state == 0) {
            const nanoseconds = std.Io.Timestamp.now(self.io, .real).nanoseconds;
            self.random_state = @truncate(@as(u96, @bitCast(nanoseconds)));
            if (self.random_state == 0) self.random_state = 0x4d595df4d0f33173;
        }
        var value = self.random_state;
        value ^= value >> 12;
        value ^= value << 25;
        value ^= value >> 27;
        self.random_state = value;
        const bits = (value *% 0x2545f4914f6cdd1d) >> 11;
        return @as(f64, @floatFromInt(bits)) / 9007199254740992.0;
    }

    fn randomBytes(context: *anyopaque, output: []u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try self.io.randomSecure(output);
    }

    fn networkAddresses(context: *anyopaque, allocator: std.mem.Allocator, ipv6: bool) !lnako.plugins.node.NetworkAddresses {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.environmentValue("LNAKO_TEST_NETWORK_TOPOLOGY")) |topology| {
            if (std.mem.eql(u8, topology, "synthetic-v1")) return network.syntheticNetworkAddresses(allocator, ipv6);
        }
        return if (builtin.os.tag == .windows)
            network.windowsNetworkAddresses(allocator, ipv6)
        else
            network.posixNetworkAddresses(allocator, ipv6);
    }

    fn currentDirectory(context: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const path = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", allocator);
        return path;
    }

    fn changeDirectory(context: *anyopaque, path: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        var directory = try std.Io.Dir.cwd().openDir(self.io, path, .{});
        defer directory.close(self.io);
        try std.process.setCurrentDir(self.io, directory);
    }

    fn readFile(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(1024 * 1024 * 1024));
    }

    fn writeFile(context: *anyopaque, path: []const u8, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes });
    }

    fn statFile(context: *anyopaque, path: []const u8) !lnako.plugins.node.FileStat {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const stat = try std.Io.Dir.cwd().statFile(self.io, path, .{});
        return .{
            .kind = switch (stat.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            },
            .size = stat.size,
            .inode = @floatFromInt(stat.inode),
            .links = @floatFromInt(stat.nlink),
            .block_size = @floatFromInt(stat.block_size),
            .modified_nanoseconds = stat.mtime.nanoseconds,
            .changed_nanoseconds = stat.ctime.nanoseconds,
            .accessed_nanoseconds = if (stat.atime) |time| time.nanoseconds else null,
        };
    }

    fn createDirectory(context: *anyopaque, path: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try std.Io.Dir.cwd().createDirPath(self.io, path);
    }

    fn deletePath(context: *anyopaque, path: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try std.Io.Dir.cwd().deleteTree(self.io, path);
    }

    fn normalizedPath(self: *CliHost, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", allocator);
        defer allocator.free(cwd);
        const resolved = try std.fs.path.resolve(allocator, &.{ cwd, path });
        errdefer allocator.free(resolved);
        if (builtin.os.tag == .windows) {
            for (resolved) |*byte| {
                if (std.fs.path.isSep(byte.*)) byte.* = std.fs.path.sep;
            }
            for (resolved) |*byte| {
                if (byte.* >= 'A' and byte.* <= 'Z') byte.* += 'a' - 'A';
            }
        }
        return resolved;
    }

    fn isSameOrDescendantPath(self: *CliHost, allocator: std.mem.Allocator, left: []const u8, right: []const u8) !bool {
        const left_normalized = try self.normalizedPath(allocator, left);
        defer allocator.free(left_normalized);
        const right_normalized = try self.normalizedPath(allocator, right);
        defer allocator.free(right_normalized);
        if (std.mem.eql(u8, left_normalized, right_normalized)) return true;
        const sep = std.fs.path.sep_str;
        if (std.mem.startsWith(u8, right_normalized, left_normalized) and std.mem.startsWith(u8, right_normalized[left_normalized.len..], sep)) return true;
        if (std.mem.startsWith(u8, left_normalized, right_normalized) and std.mem.startsWith(u8, left_normalized[right_normalized.len..], sep)) return true;
        return false;
    }

    fn copyPath(context: *anyopaque, allocator: std.mem.Allocator, source: []const u8, destination: []const u8, overwrite: bool) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (try self.isSameOrDescendantPath(allocator, source, destination)) return error.SelfOrDescendantPath;
        const stat = try std.Io.Dir.cwd().statFile(self.io, source, .{});
        if (stat.kind != .directory) return std.Io.Dir.cwd().copyFile(source, std.Io.Dir.cwd(), destination, self.io, .{ .replace = overwrite, .make_path = true });
        try std.Io.Dir.cwd().createDirPath(self.io, destination);
        var directory = try std.Io.Dir.cwd().openDir(self.io, source, .{ .iterate = true });
        defer directory.close(self.io);
        var walker = try directory.walk(allocator);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            const target = try std.fs.path.join(allocator, &.{ destination, entry.path });
            defer allocator.free(target);
            if (try self.isSameOrDescendantPath(allocator, source, target)) return error.SelfOrDescendantPath;
            if (entry.kind == .directory) {
                try std.Io.Dir.cwd().createDirPath(self.io, target);
            } else if (entry.kind == .file) {
                const from = try std.fs.path.join(allocator, &.{ source, entry.path });
                defer allocator.free(from);
                try std.Io.Dir.cwd().copyFile(from, std.Io.Dir.cwd(), target, self.io, .{ .replace = overwrite, .make_path = true });
            }
        }
    }

    fn movePath(context: *anyopaque, allocator: std.mem.Allocator, source: []const u8, destination: []const u8, overwrite: bool) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (try self.isSameOrDescendantPath(allocator, source, destination)) return error.SelfOrDescendantPath;
        try copyPath(context, allocator, source, destination, overwrite);
        try deletePath(context, source);
    }

    fn listDirectory(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8, recursive: bool) ![]lnako.plugins.node.FileEntry {
        const self: *CliHost = @ptrCast(@alignCast(context));
        var directory = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer directory.close(self.io);
        var entries: std.ArrayList(lnako.plugins.node.FileEntry) = .empty;
        errdefer {
            for (entries.items) |entry| allocator.free(entry.name);
            entries.deinit(allocator);
        }
        if (recursive) {
            var walker = try directory.walk(allocator);
            defer walker.deinit();
            while (try walker.next(self.io)) |entry| try entries.append(allocator, .{
                .name = try allocator.dupe(u8, entry.path),
                .kind = switch (entry.kind) {
                    .file => .file,
                    .directory => .directory,
                    else => .other,
                },
            });
        } else {
            var iterator = directory.iterate();
            while (try iterator.next(self.io)) |entry| try entries.append(allocator, .{
                .name = try allocator.dupe(u8, entry.name),
                .kind = switch (entry.kind) {
                    .file => .file,
                    .directory => .directory,
                    else => .other,
                },
            });
        }
        std.mem.sort(lnako.plugins.node.FileEntry, entries.items, {}, lessThanNodeFileEntry);
        return entries.toOwnedSlice(allocator);
    }

    fn runCommand(context: *anyopaque, allocator: std.mem.Allocator, command: []const u8) !lnako.plugins.node.CommandResult {
        const self: *CliHost = @ptrCast(@alignCast(context));
        return process.runShellCommand(allocator, self.io, command, null);
    }

    fn startCommand(context: *anyopaque, command: []const u8) !u64 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const allocator = std.heap.page_allocator;
        const owned_command = try allocator.dupe(u8, command);
        errdefer allocator.free(owned_command);
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", allocator);
        errdefer allocator.free(cwd);
        return self.startAsyncOperation(.{ .command = .{ .command = owned_command, .cwd = cwd } });
    }

    fn startFileOperation(context: *anyopaque, operation: lnako.plugins.node.FileOperation, source: []const u8, destination: ?[]const u8, overwrite: bool) !u64 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const allocator = std.heap.page_allocator;
        const owned_source = try allocator.dupe(u8, source);
        errdefer allocator.free(owned_source);
        const owned_destination = if (destination) |path| try allocator.dupe(u8, path) else null;
        errdefer if (owned_destination) |path| allocator.free(path);
        return self.startAsyncOperation(.{ .file = .{ .operation = operation, .source = owned_source, .destination = owned_destination, .overwrite = overwrite } });
    }

    fn startArchive(context: *anyopaque, operation: lnako.plugins.node.ArchiveOperation, source: []const u8, destination: []const u8, external_tool: ?[]const u8) !u64 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const allocator = std.heap.page_allocator;
        const owned_source = try allocator.dupe(u8, source);
        errdefer allocator.free(owned_source);
        const owned_destination = try allocator.dupe(u8, destination);
        errdefer allocator.free(owned_destination);
        const owned_tool = if (external_tool) |tool| try allocator.dupe(u8, tool) else null;
        errdefer if (owned_tool) |tool| allocator.free(tool);
        return self.startAsyncOperation(.{ .archive = .{ .operation = operation, .source = owned_source, .destination = owned_destination, .external_tool = owned_tool } });
    }

    fn startHttp(context: *anyopaque, request: lnako.plugins.node.HttpRequest) !u64 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const allocator = std.heap.page_allocator;
        const method = try allocator.dupe(u8, request.method);
        errdefer allocator.free(method);
        const url = try allocator.dupe(u8, request.url);
        errdefer allocator.free(url);
        const body = try allocator.dupe(u8, request.body);
        errdefer allocator.free(body);
        const headers = try allocator.alloc(lnako.plugins.node.HttpHeader, request.headers.len);
        var initialized: usize = 0;
        errdefer {
            for (headers[0..initialized]) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }
            allocator.free(headers);
        }
        for (request.headers, 0..) |header, index| {
            const name = try allocator.dupe(u8, header.name);
            errdefer allocator.free(name);
            headers[index] = .{ .name = name, .value = try allocator.dupe(u8, header.value) };
            initialized += 1;
        }
        return self.startAsyncOperation(.{ .http = .{ .method = method, .url = url, .headers = headers, .body = body, .has_body = request.has_body } });
    }

    fn runHttpRequest(context: *anyopaque, allocator: std.mem.Allocator, request: lnako.plugins.node.HttpRequest) !lnako.plugins.node.CommandResult {
        const self: *CliHost = @ptrCast(@alignCast(context));
        return httpRequest(self, allocator, request);
    }

    fn startHttpServer(context: *anyopaque, port: u16) !u16 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.http_server != null) return error.HttpServerAlreadyStarted;
        const address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(port) };
        self.http_server = try address.listen(self.io, .{ .reuse_address = true });
        return self.http_server.?.socket.address.getPort();
    }

    fn receiveHttpServerRequest(context: *anyopaque, allocator: std.mem.Allocator) !lnako.plugins.http_server.Request {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.http_connection != null) return error.PreviousHttpResponseNotFinished;
        const server = if (self.http_server) |*value| value else return error.HttpServerNotStarted;
        const stream = try server.accept(self.io);
        errdefer stream.close(self.io);
        var buffer: [64 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &buffer);
        const request_line_raw = (try reader.interface.takeDelimiter('\n')) orelse return error.InvalidHttpRequest;
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
        var content_type: []u8 = try allocator.alloc(u8, 0);
        errdefer allocator.free(content_type);
        while (true) {
            const line_raw = (try reader.interface.takeDelimiter('\n')) orelse return error.InvalidHttpRequest;
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const header_name = std.mem.trim(u8, line[0..colon], " \t");
            const header_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (header_name.len == 0 or std.mem.indexOfAny(u8, header_name, "\r\n\x00") != null or std.mem.indexOfAny(u8, header_value, "\r\n\x00") != null) return error.InvalidHttpHeader;
            if (std.ascii.eqlIgnoreCase(header_name, "content-length")) {
                content_length = try std.fmt.parseInt(usize, header_value, 10);
            } else if (std.ascii.eqlIgnoreCase(header_name, "transfer-encoding")) {
                transfer_chunked = std.ascii.indexOfIgnoreCase(header_value, "chunked") != null;
            } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
                allocator.free(content_type);
                content_type = try allocator.dupe(u8, header_value);
            }
        }
        if (transfer_chunked and content_length > 0) return error.InvalidHttpRequest;
        self.http_connection = stream;
        self.http_head_request = std.ascii.eqlIgnoreCase(method, "HEAD");
        if (transfer_chunked) {
            const chunked = try http_client.readChunkedHttpBody(allocator, &reader.interface, 10 * 1024 * 1024);
            return .{
                .method = method,
                .target = target,
                .content_type = content_type,
                .body = chunked.body,
                .too_large = chunked.too_large,
            };
        }
        if (content_length > 10 * 1024 * 1024) {
            _ = try reader.interface.discardShort(content_length);
            return .{
                .method = method,
                .target = target,
                .content_type = content_type,
                .body = try allocator.alloc(u8, 0),
                .too_large = true,
            };
        }
        const body = try allocator.alloc(u8, content_length);
        errdefer allocator.free(body);
        try reader.interface.readSliceAll(body);
        return .{ .method = method, .target = target, .content_type = content_type, .body = body };
    }

    fn respondHttpServer(context: *anyopaque, status_code: u16, headers: []const lnako.plugins.http_server.Header, body: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const stream = self.http_connection orelse return error.HttpServerResponseOutsideRequest;
        defer {
            stream.close(self.io);
            self.http_connection = null;
            self.http_head_request = false;
        }
        var send_buffer: [16 * 1024]u8 = undefined;
        var writer = stream.writer(self.io, &send_buffer);
        const status: std.http.Status = @enumFromInt(status_code);
        try writer.interface.print("HTTP/1.1 {d} {s}\r\n", .{ status_code, status.phrase() orelse "" });
        var has_content_length = false;
        for (headers) |header| {
            if (header.name.len == 0 or std.mem.indexOfAny(u8, header.name, "\r\n\x00") != null or std.mem.indexOfAny(u8, header.value, "\r\n\x00") != null) return error.InvalidHttpHeader;
            if (std.ascii.eqlIgnoreCase(header.name, "content-length")) has_content_length = true;
            try writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
        if (!has_content_length) try writer.interface.print("Content-Length: {d}\r\n", .{body.len});
        try writer.interface.writeAll("Connection: close\r\n\r\n");
        if (!self.http_head_request) try writer.interface.writeAll(body);
        try writer.interface.flush();
    }

    fn holdHttpServerResponse(context: *anyopaque) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const stream = self.http_connection orelse return error.HttpServerResponseOutsideRequest;
        try self.held_http_connections.append(std.heap.page_allocator, stream);
        self.http_connection = null;
        self.http_head_request = false;
    }

    fn statHttpServerPath(context: *anyopaque, path: []const u8) !lnako.plugins.http_server.PathStat {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| return switch (err) {
            error.FileNotFound, error.NotDir => .missing,
            else => err,
        };
        return switch (stat.kind) {
            .file => .file,
            .directory => .directory,
            else => .missing,
        };
    }

    fn saveHttpServerUpload(context: *anyopaque, allocator: std.mem.Allocator, filename: []const u8, body: []const u8) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const upload_directory = try std.fs.path.join(allocator, &.{ self.temporary_directory, "nako3-plugin_httpserver_upload" });
        defer allocator.free(upload_directory);
        try std.Io.Dir.cwd().createDirPath(self.io, upload_directory);
        const safe_name = http_client.uploadBasename(filename);
        const unique_name = try std.fmt.allocPrint(allocator, "{d}_{d}_{s}", .{ try nowMilliseconds(self), self.upload_sequence, safe_name });
        defer allocator.free(unique_name);
        self.upload_sequence +%= 1;
        const path = try std.fs.path.join(allocator, &.{ upload_directory, unique_name });
        errdefer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = body });
        return path;
    }

    fn resolveHttpServerStaticPath(context: *anyopaque, allocator: std.mem.Allocator, root: []const u8, components: []const []const u8) !?lnako.plugins.http_server.ResolvedPath {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const root_real = std.Io.Dir.cwd().realPathFileAlloc(self.io, root, allocator) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(root_real);

        var relative: std.ArrayList(u8) = .empty;
        errdefer relative.deinit(allocator);
        for (components) |component| {
            if (relative.items.len > 0) try relative.append(allocator, std.fs.path.sep);
            try relative.appendSlice(allocator, component);
            if (relative.items.len > std.fs.max_path_bytes) return null;
        }

        if (relative.items.len == 0) {
            const index_path = try std.fs.path.join(allocator, &.{ root_real, "index.html" });
            defer allocator.free(index_path);
            const resolved = std.Io.Dir.cwd().realPathFileAlloc(self.io, index_path, allocator) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };
            if (!isUnderRoot(resolved, root_real)) {
                allocator.free(resolved);
                return null;
            }
            return .{ .path = resolved, .kind = .file };
        }

        const full = try std.fs.path.join(allocator, &.{ root, relative.items });
        defer allocator.free(full);
        const resolved = std.Io.Dir.cwd().realPathFileAlloc(self.io, full, allocator) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (!isUnderRoot(resolved, root_real)) {
            allocator.free(resolved);
            return null;
        }
        const stat = std.Io.Dir.cwd().statFile(self.io, resolved, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(resolved);
                return null;
            },
            else => return err,
        };
        if (stat.kind == .directory) {
            const index_path = try std.fs.path.join(allocator, &.{ resolved, "index.html" });
            defer allocator.free(index_path);
            const index_resolved = std.Io.Dir.cwd().realPathFileAlloc(self.io, index_path, allocator) catch |err| switch (err) {
                error.FileNotFound => {
                    allocator.free(resolved);
                    return null;
                },
                else => |e| return e,
            };
            if (!isUnderRoot(index_resolved, root_real)) {
                allocator.free(resolved);
                allocator.free(index_resolved);
                return null;
            }
            allocator.free(resolved);
            return .{ .path = index_resolved, .kind = .file };
        }
        if (stat.kind == .file) return .{ .path = resolved, .kind = .file };
        allocator.free(resolved);
        return null;
    }

    fn readHttpServerStaticFile(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const max_size = 1024 * 1024 * 1024;
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(max_size));
    }

    fn isUnderRoot(resolved: []const u8, root: []const u8) bool {
        if (resolved.len < root.len) return false;
        if (!std.mem.startsWith(u8, resolved, root)) return false;
        if (resolved.len == root.len) return true;
        return std.fs.path.isSep(resolved[root.len]);
    }

    fn startAsyncOperation(self: *CliHost, operation: AsyncOperation) !u64 {
        const allocator = std.heap.page_allocator;
        const task = try allocator.create(AsyncOperationTask);
        errdefer allocator.destroy(task);
        const token = self.next_async_token;
        self.next_async_token +%= 1;
        if (self.next_async_token == 0) self.next_async_token = 1;
        task.* = .{ .token = token, .host = self, .operation = operation };
        try self.async_tasks.append(allocator, task);
        errdefer _ = self.async_tasks.pop();
        try self.async_task_map.put(token, task);
        errdefer _ = self.async_task_map.remove(token);
        task.thread = try std.Thread.spawn(.{}, AsyncOperationTask.run, .{task});
        return token;
    }

    fn pollOperation(context: *anyopaque, allocator: std.mem.Allocator, token: u64) !?lnako.plugins.node.CommandResult {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const task = self.async_task_map.get(token) orelse return error.AsyncCommandNotFound;
        const complete = task.complete.load(.acquire);
        if (!complete) return null;
        const task_order = task.completion_order.load(.acquire);
        for (self.async_tasks.items) |other| {
            if (other == task or !other.complete.load(.acquire)) continue;
            if (other.completion_order.load(.acquire) < task_order) return null;
        }
        const failure = task.failure;
        const source = task.result;
        const owned = if (source) |result| blk: {
            const stdout_bytes = try allocator.dupe(u8, result.stdout);
            errdefer allocator.free(stdout_bytes);
            const stderr_bytes = try allocator.dupe(u8, result.stderr);
            errdefer allocator.free(stderr_bytes);
            break :blk lnako.plugins.node.CommandResult{ .stdout = stdout_bytes, .stderr = stderr_bytes, .exit_code = result.exit_code, .http_status = result.http_status };
        } else null;
        const index = for (self.async_tasks.items, 0..) |candidate, i| {
            if (candidate == task) break i;
        } else return error.AsyncCommandNotFound;
        _ = self.async_tasks.orderedRemove(index);
        _ = self.async_task_map.remove(token);
        destroyAsyncTask(task, true);
        if (failure) |err| return err;
        return owned orelse error.AsyncCommandMissingResult;
    }

    fn readStdin(context: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(self.io, &buffer);
        return reader.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024));
    }

    fn createTemporaryDirectory(context: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        for (0..128) |_| {
            const candidate = try allocator.alloc(u8, prefix.len + 6);
            errdefer allocator.free(candidate);
            @memcpy(candidate[0..prefix.len], prefix);
            for (candidate[prefix.len..]) |*byte| byte.* = alphabet[@as(usize, @intFromFloat(try random(self) * @as(f64, @floatFromInt(alphabet.len)))) % alphabet.len];
            std.Io.Dir.cwd().createDir(self.io, candidate, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(candidate);
                    continue;
                },
                else => return err,
            };
            return candidate;
        }
        return error.TemporaryDirectoryCollision;
    }

    fn openExternal(context: *anyopaque, allocator: std.mem.Allocator, target: []const u8, reveal: bool) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.environmentValue("LNAKO_TEST_OPEN_EXTERNAL") != null) {
            if (reveal and builtin.os.tag != .windows) return error.OpenExternalFailed;
            return;
        }
        switch (builtin.os.tag) {
            .windows => return network.WindowsShell.openExternal(allocator, target, reveal),
            .macos => {
                const argv: []const []const u8 = if (reveal) &[_][]const u8{ "/usr/bin/open", "-R", target } else &[_][]const u8{ "/usr/bin/open", target };
                const result = try std.process.run(allocator, self.io, .{ .argv = argv, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
                defer allocator.free(result.stdout);
                defer allocator.free(result.stderr);
                if (result.term != .exited or result.term.exited != 0) return error.OpenExternalFailed;
            },
            else => {
                const argv: []const []const u8 = if (reveal)
                    &[_][]const u8{ "xdg-open", std.fs.path.dirname(target) orelse "." }
                else
                    &[_][]const u8{ "xdg-open", target };
                const result = try std.process.run(allocator, self.io, .{ .argv = argv, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
                defer allocator.free(result.stdout);
                defer allocator.free(result.stderr);
                if (result.term != .exited or result.term.exited != 0) return error.OpenExternalFailed;
            },
        }
    }

    fn runArchive(context: *anyopaque, allocator: std.mem.Allocator, operation: lnako.plugins.node.ArchiveOperation, source: []const u8, destination: []const u8, external_tool: ?[]const u8) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (external_tool) |tool| {
            // The archive helper is test-only. It keeps the explicit external
            // tool state and archive callback route under test without
            // depending on a host-installed 7-Zip executable. Normal runs
            // still invoke the configured external tool unchanged.
            if (self.environmentValue("LNAKO_TEST_ARCHIVE_HELPER")) |helper| {
                if (std.mem.eql(u8, helper, tool)) return archive.runStoredZipArchive(allocator, self.io, operation, source, destination);
            }
            return archive.runArchiveTool(allocator, self.io, tool, operation, source, destination);
        }
        return archive.runStoredZipArchive(allocator, self.io, operation, source, destination);
    }

    fn installInterrupt(_: *anyopaque) !void {
        if (builtin.os.tag == .windows) {
            if (network.WindowsInterrupt.SetConsoleCtrlHandler(network.WindowsInterrupt.handler, 1) == 0) return error.InterruptHandlingUnavailable;
        } else {
            const action: std.posix.Sigaction = .{
                .handler = .{ .handler = PosixInterrupt.handler },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(.INT, &action, null);
        }
    }

    fn consumeInterrupt(_: *anyopaque) bool {
        return network.interrupt_requested.swap(false, .acquire);
    }
};

const PosixInterrupt = if (builtin.os.tag == .windows) struct {} else struct {
    fn handler(_: std.posix.SIG) callconv(.c) void {
        network.interrupt_requested.store(true, .release);
    }
};

const AsyncOperation = union(enum) {
    command: struct { command: []u8, cwd: []u8 },
    file: struct { operation: lnako.plugins.node.FileOperation, source: []u8, destination: ?[]u8, overwrite: bool },
    archive: struct { operation: lnako.plugins.node.ArchiveOperation, source: []u8, destination: []u8, external_tool: ?[]u8 },
    http: struct { method: []u8, url: []u8, headers: []lnako.plugins.node.HttpHeader, body: []u8, has_body: bool },

    fn deinit(self: *@This()) void {
        const allocator = std.heap.page_allocator;
        switch (self.*) {
            .command => |operation| {
                allocator.free(operation.command);
                allocator.free(operation.cwd);
            },
            .file => |operation| {
                allocator.free(operation.source);
                if (operation.destination) |destination| allocator.free(destination);
            },
            .archive => |operation| {
                allocator.free(operation.source);
                allocator.free(operation.destination);
                if (operation.external_tool) |tool| allocator.free(tool);
            },
            .http => |operation| {
                allocator.free(operation.method);
                allocator.free(operation.url);
                allocator.free(operation.body);
                for (operation.headers) |header| {
                    allocator.free(header.name);
                    allocator.free(header.value);
                }
                allocator.free(operation.headers);
            },
        }
        self.* = undefined;
    }
};

pub const AsyncOperationTask = struct {
    token: u64,
    host: *CliHost,
    operation: AsyncOperation,
    thread: ?std.Thread = null,
    complete: std.atomic.Value(bool) = .init(false),
    completion_order: std.atomic.Value(u64) = .init(0),
    result: ?lnako.plugins.node.CommandResult = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        const result = self.execute() catch |err| {
            self.failure = err;
            self.completion_order.store(self.host.async_completion_sequence.fetchAdd(1, .monotonic), .release);
            self.complete.store(true, .release);
            return;
        };
        self.result = result;
        self.completion_order.store(self.host.async_completion_sequence.fetchAdd(1, .monotonic), .release);
        self.complete.store(true, .release);
    }

    fn execute(self: *@This()) !lnako.plugins.node.CommandResult {
        const allocator = std.heap.page_allocator;
        return switch (self.operation) {
            .command => |operation| process.runShellCommand(allocator, self.host.io, operation.command, operation.cwd),
            .file => |operation| blk: {
                switch (operation.operation) {
                    .copy => try CliHost.copyPath(self.host, allocator, operation.source, operation.destination orelse return error.MissingFileDestination, operation.overwrite),
                    .move => try CliHost.movePath(self.host, allocator, operation.source, operation.destination orelse return error.MissingFileDestination, operation.overwrite),
                    .delete => try CliHost.deletePath(self.host, operation.source),
                }
                break :blk try process.emptyCommandResult(allocator);
            },
            .archive => |operation| blk: {
                const stdout_bytes = try CliHost.runArchive(self.host, allocator, operation.operation, operation.source, operation.destination, operation.external_tool);
                errdefer allocator.free(stdout_bytes);
                break :blk .{ .stdout = stdout_bytes, .stderr = try allocator.alloc(u8, 0), .exit_code = 0 };
            },
            .http => |operation| httpRequest(self.host, allocator, operation) catch |err| blk: {
                const message = try allocator.dupe(u8, @errorName(err));
                errdefer allocator.free(message);
                break :blk .{ .stdout = try allocator.alloc(u8, 0), .stderr = message, .exit_code = 1 };
            },
        };
    }
};

fn httpRequest(cli_host: *CliHost, allocator: std.mem.Allocator, operation: anytype) !lnako.plugins.node.CommandResult {
    const max_http_body_size = 1024 * 1024 * 1024;
    const connect_timeout_ms = 30000;

    var client: std.http.Client = .{ .allocator = allocator, .io = cli_host.io };
    defer client.deinit();

    const headers = try allocator.alloc(std.http.Header, operation.headers.len);
    defer allocator.free(headers);
    for (operation.headers, headers) |source, *target| {
        if (std.mem.indexOfAny(u8, source.name, "\r\n\x00") != null or std.mem.indexOfAny(u8, source.value, "\r\n\x00") != null) return error.InvalidHttpHeader;
        target.* = .{ .name = source.name, .value = source.value };
    }

    const uri = try std.Uri.parse(operation.url);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
    var host_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = try uri.getHost(&host_name_buffer);
    const port = uri.port orelse switch (protocol) {
        .plain => @as(u16, 80),
        .tls => @as(u16, 443),
    };

    const connection = try client.connectTcpOptions(.{
        .host = host_name,
        .port = port,
        .protocol = protocol,
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(connect_timeout_ms),
            .clock = .awake,
        } },
    });

    const method = try http_client.httpMethod(operation.method);
    var req = try client.request(method, uri, .{
        .connection = connection,
        .keep_alive = false,
        .extra_headers = headers,
        .redirect_behavior = @enumFromInt(3),
    });
    defer req.deinit();

    if (operation.has_body) {
        req.transfer_encoding = .{ .content_length = operation.body.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(operation.body);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var total: usize = 0;
    while (true) {
        var chunk: [16 * 1024]u8 = undefined;
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        total = std.math.add(usize, total, n) catch return error.HttpBodyTooLarge;
        if (total > max_http_body_size) return error.HttpBodyTooLarge;
        try output.appendSlice(allocator, chunk[0..n]);
    }

    const stdout_bytes = try output.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_bytes);
    return .{
        .stdout = stdout_bytes,
        .stderr = try allocator.alloc(u8, 0),
        .exit_code = 0,
        .http_status = @intFromEnum(response.head.status),
    };
}

fn destroyAsyncTask(task: *AsyncOperationTask, join: bool) void {
    if (join) if (task.thread) |thread| thread.join();
    if (task.result) |*result| result.deinit(std.heap.page_allocator);
    task.operation.deinit();
    std.heap.page_allocator.destroy(task);
}

fn lessThanNodeFileEntry(_: void, left: lnako.plugins.node.FileEntry, right: lnako.plugins.node.FileEntry) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}
