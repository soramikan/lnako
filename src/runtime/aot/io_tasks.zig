const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");
const runtime_core = @import("runtime_core.zig");

const toml_temporal = shared.toml_temporal;
const runAotShellCommand = aot_state.runAotShellCommand;
const aotRuntimeIo = aot_state.aotRuntimeIo;
const aotFileCopyMoveWithIo = aot_state.aotFileCopyMoveWithIo;

const Value = runtime_core.Value;
const Runtime = runtime_core.Runtime;

pub const AotTomlTemporal = struct {
    kind: toml_temporal.Kind,
    json_text: []u8,
    toml_text: []u8,

    pub fn deinit(self: *AotTomlTemporal, allocator: std.mem.Allocator) void {
        allocator.free(self.json_text);
        allocator.free(self.toml_text);
        self.* = undefined;
    }
};

pub const AotHttpRouteKind = enum { static, callback };

pub const AotHttpRoute = struct {
    kind: AotHttpRouteKind,
    prefix: []u8,
    path: []u8 = &.{},
    callback: Value = .{},

    pub fn deinit(self: *AotHttpRoute, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        if (self.path.len > 0) allocator.free(self.path);
        self.* = undefined;
    }
};

pub const AotHttpHeader = struct {
    name: []u8,
    value: []u8,

    pub fn deinit(self: *AotHttpHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const AotHttpServerState = struct {
    routes: std.ArrayList(AotHttpRoute) = .empty,
    response_headers: std.ArrayList(AotHttpHeader) = .empty,
    started: bool = false,
    request_active: bool = false,
    response_status: u16 = 200,

    pub fn deinit(self: *AotHttpServerState, allocator: std.mem.Allocator) void {
        for (self.routes.items) |*route| route.deinit(allocator);
        self.routes.deinit(allocator);
        self.clearHeaders(allocator);
        self.response_headers.deinit(allocator);
        self.* = undefined;
    }

    pub fn clearHeaders(self: *AotHttpServerState, allocator: std.mem.Allocator) void {
        for (self.response_headers.items) |*header| header.deinit(allocator);
        self.response_headers.clearRetainingCapacity();
    }
};

pub const AotArchiveOperation = enum { create, extract };

pub const AotArchiveTask = struct {
    operation: AotArchiveOperation,
    use_external_tool: bool,
    source: []u8,
    destination: []u8,
    tool_path: []u8,
    callback: Value,

    pub fn deinit(self: *AotArchiveTask, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.destination);
        allocator.free(self.tool_path);
        self.* = undefined;
    }
};

pub const AotProcessMode = enum { command_output, output_callback };

pub const AotCommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *AotCommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const AotProcessTask = struct {
    runtime: *Runtime,
    command: []u8,
    cwd: []u8,
    mode: AotProcessMode,
    callback: Value = .{},
    thread: ?std.Thread = null,
    complete: std.atomic.Value(bool) = .init(false),
    completion_order: u64 = 0,
    result: ?AotCommandResult = null,
    failure: ?anyerror = null,

    pub fn run(self: *@This()) void {
        const result = runAotShellCommand(self.runtime, self.command, self.cwd) catch |failure| {
            self.failure = failure;
            self.completion_order = self.runtime.process_completion_sequence.fetchAdd(1, .monotonic);
            self.complete.store(true, .release);
            return;
        };
        self.result = result;
        self.completion_order = self.runtime.process_completion_sequence.fetchAdd(1, .monotonic);
        self.complete.store(true, .release);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, join: bool) void {
        if (join) if (self.thread) |thread| thread.join();
        if (self.result) |*result| result.deinit(allocator);
        allocator.free(self.command);
        allocator.free(self.cwd);
        allocator.destroy(self);
    }
};

pub const AotFileTaskOperation = enum { copy, move, delete };

pub const AotFileTask = struct {
    runtime: *Runtime,
    operation: AotFileTaskOperation,
    source: []u8,
    destination: []u8,
    overwrite: bool,
    callback: Value = .{},
    thread: ?std.Thread = null,
    complete: std.atomic.Value(bool) = .init(false),
    completion_order: u64 = 0,
    failure: ?anyerror = null,

    pub fn run(self: *@This()) void {
        const io = aotRuntimeIo(self.runtime);
        const result = switch (self.operation) {
            .copy => aotFileCopyMoveWithIo(self.runtime, io, self.source, self.destination, self.overwrite, false),
            .move => aotFileCopyMoveWithIo(self.runtime, io, self.source, self.destination, self.overwrite, true),
            .delete => std.Io.Dir.cwd().deleteTree(io, self.source),
        };
        if (result) |_| {} else |failure| self.failure = failure;
        self.completion_order = self.runtime.process_completion_sequence.fetchAdd(1, .monotonic);
        self.complete.store(true, .release);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, join: bool) void {
        if (join) if (self.thread) |thread| thread.join();
        allocator.free(self.source);
        allocator.free(self.destination);
        allocator.destroy(self);
    }
};

pub const AotClientHttpResult = struct {
    body: []u8,
    status: u16 = 0,
    content_length_zero: bool = false,
    failure: ?anyerror = null,

    pub fn deinit(self: *AotClientHttpResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const AotClientHttpMode = enum { callback, set_target, response_promise };

pub const AotClientHttpBodyKind = enum { text, json, binary };

pub const AotClientHttpTask = struct {
    result: AotClientHttpResult,
    mode: AotClientHttpMode,
    callback: Value = .{},
    promise: Value = .{},
    target: ?*Value = null,
    onerror: ?*Value = null,

    pub fn deinit(self: *AotClientHttpTask, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const AotHttpGlobals = struct {
    method: ?*Value = null,
    get_data: ?*Value = null,
    post_data: ?*Value = null,
    files_data: ?*Value = null,
};
