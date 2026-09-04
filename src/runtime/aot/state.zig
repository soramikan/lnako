const shared = @import("shared.zig");
const builtins = @import("builtins.zig");

const std = shared.std;
const builtin = shared.builtin;
const aot_abi = shared.aot_abi;
pub const aot_builtin = shared.aot_builtin;
pub const BigInt = shared.BigInt;
const error_message = shared.error_message;
const unicode_case = shared.unicode_case;
const number_mod = shared.number_mod;
const string_mod = shared.string_mod;
const system_constant = shared.system_constant;
pub const crypto = shared.crypto;
const encoding = shared.encoding;
const zip_archive = shared.zip_archive;
const regexp = shared.regexp;
const markup = shared.markup;
const lexer = shared.lexer;
const josi = shared.josi;
const builtin_catalog = shared.builtin_catalog;
const dynamic_ir = shared.dynamic_ir;
const dynamic_interpreter = shared.dynamic_interpreter;
const dynamic_value = shared.dynamic_value;
pub const toml_temporal = shared.toml_temporal;

pub const lnako_aot_builtin_call = builtins.lnako_aot_builtin_call;
pub const lnako_aot_builtin_call_site = builtins.lnako_aot_builtin_call_site;
pub const lnako_aot_debug_breakpoint_wait_call = builtins.lnako_aot_debug_breakpoint_wait_call;
pub extern "c" fn fflush(stream: ?*std.c.FILE) c_int;
pub extern "c" fn time(timer: ?*i64) i64;

const AotWindowsStdout = shared.AotWindowsStdout;
pub const Tag = shared.Tag;
const AotPrimitiveHint = shared.AotPrimitiveHint;
const no_dispatch_call_id = shared.no_dispatch_call_id;
pub const safe_array_element_limit = shared.safe_array_element_limit;
const aot_timer_event_limit = shared.aot_timer_event_limit;

const DispatchTrace = struct {
    file: ?*std.c.FILE = null,
    initialized: bool = false,
    disabled: bool = false,
    sequence: u64 = 0,
    next_call_id: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *DispatchTrace) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *DispatchTrace) void {
        self.locked.store(false, .release);
    }

    pub fn deinit(self: *DispatchTrace) void {
        self.finish();
        self.lock();
        defer self.unlock();
        if (self.file) |file| _ = std.c.fclose(file);
        self.file = null;
    }

    pub fn ensureFile(self: *DispatchTrace) ?*std.c.FILE {
        if (self.disabled) return null;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_DISPATCH_TRACE") orelse return null;
            if (path[0] == 0) return null;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return null;
            };
        }
        return self.file;
    }

    pub fn writeLine(self: *DispatchTrace, file: *std.c.FILE, rendered: []const u8) bool {
        if (std.c.fwrite(rendered.ptr, 1, rendered.len, file) != rendered.len or fflush(file) != 0) {
            _ = std.c.fclose(file);
            self.file = null;
            self.disabled = true;
            return false;
        }
        self.sequence += 1;
        return true;
    }

    pub fn begin(self: *DispatchTrace, command: []const u8, opcode: u16, route: []const u8, site_id: u64) u64 {
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return no_dispatch_call_id;
        if (self.next_call_id == no_dispatch_call_id) {
            self.disabled = true;
            return no_dispatch_call_id;
        }
        const call_id = self.next_call_id;
        self.next_call_id += 1;
        var line: [768]u8 = undefined;
        const rendered = if (site_id == 0)
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-attempt\",\"seq\":{d},\"callId\":{d},\"siteId\":null,\"opcode\":{d},\"command\":\"{s}\",\"name_source\":\"canonical-opcode\",\"route\":\"{s}\"}}\n", .{ self.sequence, call_id, opcode, command, route }) catch {
                self.disabled = true;
                return no_dispatch_call_id;
            }
        else
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-attempt\",\"seq\":{d},\"callId\":{d},\"siteId\":\"0x{x:0>16}\",\"opcode\":{d},\"command\":\"{s}\",\"name_source\":\"canonical-opcode\",\"route\":\"{s}\"}}\n", .{ self.sequence, call_id, site_id, opcode, command, route }) catch {
                self.disabled = true;
                return no_dispatch_call_id;
            };
        if (!self.writeLine(file, rendered)) return no_dispatch_call_id;
        return call_id;
    }

    pub fn result(self: *DispatchTrace, call_id: u64, command: []const u8, opcode: u16, route: []const u8, site_id: u64, success: bool) void {
        if (call_id == no_dispatch_call_id) return;
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return;
        var line: [768]u8 = undefined;
        const rendered = if (site_id == 0)
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-result\",\"seq\":{d},\"callId\":{d},\"siteId\":null,\"opcode\":{d},\"command\":\"{s}\",\"route\":\"{s}\",\"success\":{}}}\n", .{ self.sequence, call_id, opcode, command, route, success }) catch {
                self.disabled = true;
                return;
            }
        else
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-result\",\"seq\":{d},\"callId\":{d},\"siteId\":\"0x{x:0>16}\",\"opcode\":{d},\"command\":\"{s}\",\"route\":\"{s}\",\"success\":{}}}\n", .{ self.sequence, call_id, site_id, opcode, command, route, success }) catch {
                self.disabled = true;
                return;
            };
        _ = self.writeLine(file, rendered);
    }

    pub fn finish(self: *DispatchTrace) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_DISPATCH_TRACE") orelse return;
            if (path[0] == 0) return;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return;
            };
        }
        const file = self.ensureFile() orelse return;
        var line: [160]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0}}\n",
            .{self.sequence},
        ) catch return;
        if (self.writeLine(file, rendered)) self.disabled = true;
    }

    pub fn finishTerminal(self: *DispatchTrace, reason: []const u8, exit_code: u8) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_DISPATCH_TRACE") orelse return;
            if (path[0] == 0) return;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return;
            };
        }
        const file = self.ensureFile() orelse return;
        var line: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0,\"terminalReason\":\"{s}\",\"exitCode\":{d},\"signal\":null}}\n",
            .{ self.sequence, reason, exit_code },
        ) catch return;
        if (self.writeLine(file, rendered)) self.disabled = true;
    }
};

/// Global-read tracing is a separate opt-in channel from builtin dispatch
/// tracing. It records only that a statically identified global load executed;
/// names and values remain in the compile manifest and never cross the ABI.
const GlobalTrace = struct {
    file: ?*std.c.FILE = null,
    initialized: bool = false,
    disabled: bool = false,
    sequence: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *GlobalTrace) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *GlobalTrace) void {
        self.locked.store(false, .release);
    }

    pub fn deinit(self: *GlobalTrace) void {
        self.finish();
        self.lock();
        defer self.unlock();
        if (self.file) |file| _ = std.c.fclose(file);
        self.file = null;
    }

    pub fn ensureFile(self: *GlobalTrace) ?*std.c.FILE {
        if (self.disabled) return null;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_GLOBAL_TRACE") orelse return null;
            if (path[0] == 0) return null;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return null;
            };
        }
        return self.file;
    }

    pub fn writeLine(self: *GlobalTrace, file: *std.c.FILE, rendered: []const u8) bool {
        if (std.c.fwrite(rendered.ptr, 1, rendered.len, file) != rendered.len or fflush(file) != 0) {
            _ = std.c.fclose(file);
            self.file = null;
            self.disabled = true;
            return false;
        }
        self.sequence += 1;
        return true;
    }

    pub fn record(self: *GlobalTrace, site_id: u64) void {
        self.recordPhase(site_id, "global-read");
    }

    pub fn recordWrite(self: *GlobalTrace, site_id: u64) void {
        self.recordPhase(site_id, "global-write");
    }

    pub fn recordPhase(self: *GlobalTrace, site_id: u64, phase: []const u8) void {
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return;
        var line: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"aot\",\"phase\":\"{s}\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"success\":true}}\n",
            .{ phase, self.sequence, site_id },
        ) catch {
            self.disabled = true;
            return;
        };
        _ = self.writeLine(file, rendered);
    }

    pub fn finish(self: *GlobalTrace) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const file = if (self.initialized) self.file orelse return else blk: {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_GLOBAL_TRACE") orelse return;
            if (path[0] == 0) return;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return;
            };
            break :blk self.file;
        } orelse return;
        var line: [160]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"aot\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0}}\n",
            .{self.sequence},
        ) catch return;
        if (self.writeLine(file, rendered)) self.disabled = true;
    }
};

/// Typed literal tracing is separate from global-read tracing because the
/// catalog lists both as `定数`, while only a global reference performs a
/// runtime lookup. The trace records execution of the fixed literal site and
/// never exposes the literal value through the ABI.
const LiteralTrace = struct {
    file: ?*std.c.FILE = null,
    initialized: bool = false,
    disabled: bool = false,
    sequence: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *LiteralTrace) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *LiteralTrace) void {
        self.locked.store(false, .release);
    }

    pub fn deinit(self: *LiteralTrace) void {
        self.finish();
        self.lock();
        defer self.unlock();
        if (self.file) |file| _ = std.c.fclose(file);
        self.file = null;
    }

    pub fn ensureFile(self: *LiteralTrace) ?*std.c.FILE {
        if (self.disabled) return null;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_LITERAL_TRACE") orelse return null;
            if (path[0] == 0) return null;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return null;
            };
        }
        return self.file;
    }

    pub fn writeLine(self: *LiteralTrace, file: *std.c.FILE, rendered: []const u8) bool {
        if (std.c.fwrite(rendered.ptr, 1, rendered.len, file) != rendered.len or fflush(file) != 0) {
            _ = std.c.fclose(file);
            self.file = null;
            self.disabled = true;
            return false;
        }
        self.sequence += 1;
        return true;
    }

    pub fn record(self: *LiteralTrace, site_id: u64) void {
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return;
        var line: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"aot\",\"phase\":\"literal\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"success\":true}}\n",
            .{ self.sequence, site_id },
        ) catch {
            self.disabled = true;
            return;
        };
        _ = self.writeLine(file, rendered);
    }

    pub fn finish(self: *LiteralTrace) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const file = if (self.initialized) self.file orelse return else blk: {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_LITERAL_TRACE") orelse return;
            if (path[0] == 0) return;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return;
            };
            break :blk self.file;
        } orelse return;
        var line: [160]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"aot\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0}}\n",
            .{self.sequence},
        ) catch return;
        if (self.writeLine(file, rendered)) self.disabled = true;
    }
};

pub const Value = extern struct {
    tag: u8 = @intFromEnum(Tag.undefined),
    payload: u64 = 0,

    pub fn object(self: Value) ?*Object {
        if (self.payload == 0) return null;
        return switch (@as(Tag, @enumFromInt(self.tag))) {
            .utf16_string, .array, .dictionary, .iterator, .bigint, .function, .binding_cell, .byte_buffer, .promise => @ptrFromInt(self.payload),
            else => null,
        };
    }
};

pub const RootFrame = extern struct {
    previous: ?*RootFrame = null,
    values: ?[*]Value = null,
    len: usize = 0,
};

const DictionaryEntry = struct { key: Value, value: Value };
const AotTomlTemporal = struct {
    kind: toml_temporal.Kind,
    json_text: []u8,
    toml_text: []u8,

    pub fn deinit(self: *AotTomlTemporal, allocator: std.mem.Allocator) void {
        allocator.free(self.json_text);
        allocator.free(self.toml_text);
        self.* = undefined;
    }
};
pub const ByteKind = enum { buffer, uint8_array, array_buffer };
const ByteStorage = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    ref_count: usize = 1,
    /// Keep one stable ArrayBuffer wrapper for all views sharing this storage.
    /// The Value is traced from each live byte-buffer object below.
    backing: Value = .{},

    pub fn retain(self: *ByteStorage) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count += 1;
    }

    pub fn release(self: *ByteStorage) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
        if (self.ref_count != 0) return;
        self.allocator.free(self.bytes);
        self.allocator.destroy(self);
    }
};

const ByteBuffer = struct {
    bytes: []u8,
    kind: ByteKind,
    storage: *ByteStorage,
    /// Offset of this view from the beginning of the shared backing storage.
    /// This remains meaningful for zero-length views, where pointer arithmetic
    /// alone cannot recover the original subarray position.
    byte_offset: usize = 0,
};
const AotTimer = struct {
    id: u64,
    due_milliseconds: u64,
    interval_milliseconds: u64,
    repeating: bool,
    callback: Value,
};
const IteratorKind = enum { repeat, range, bytes, string, array, dictionary };
const Iterator = struct {
    kind: IteratorKind,
    source: Value = .{},
    index: usize = 0,
    count: usize = 0,
    current: f64 = 0,
    end: f64 = 0,
    step: f64 = 1,
};

pub const AotPromiseState = enum { pending, fulfilled, rejected };
const AotPromiseReactionMode = enum { standard, settled_pair, finally };

const AotPromiseReaction = struct {
    on_fulfilled: Value = .{},
    on_rejected: Value = .{},
    next: *Object,
    mode: AotPromiseReactionMode = .standard,
    target_global: ?*Value = null,
};

const AotPromise = struct {
    state: AotPromiseState = .pending,
    result: Value = .{},
    reactions: std.ArrayList(AotPromiseReaction) = .empty,
};

const AotPromiseTask = struct {
    callback: Value,
    settled_value: Value,
    rejected: bool,
    next: *Object,
    mode: AotPromiseReactionMode,
    target_global: ?*Value,
};

const AotPromiseAllState = struct {
    promise: *Object,
    results: Value,
    remaining: usize = 0,
};

const AotPromiseResolver = struct {
    promise: *Object,
    rejected: bool,
};

const AotPromiseAllHandler = struct {
    state: *AotPromiseAllState,
    index: usize,
    rejected: bool,
};

const PromiseFunctionKind = union(enum) {
    none,
    resolver: AotPromiseResolver,
    all_handler: AotPromiseAllHandler,
};

const AotPromiseChainKind = enum { success, failure, settled, finally };

/// Generated callbacks cross the Zig/LLVM boundary. Returning the 16-byte
/// Value aggregate directly is not portable to the Windows x64 C ABI, so the
/// result is always written through an explicit pointer.
pub const FunctionCallback = *const fn (*Value, *anyopaque, ?[*]const Value, usize) callconv(.c) void;
const FunctionObject = struct {
    callback: FunctionCallback,
    arity: usize,
    /// The generated wrapper name is retained as UTF-8 bytes so converting a
    /// function value to a string can preserve the same observable name that
    /// the interpreter exposes. The slice is owned by the function object.
    name: []u8,
    captures: []Value,
    promise_kind: PromiseFunctionKind = .none,
    /// Ordinary generated functions expose one stable prototype object.  It
    /// is created lazily by the table property resolver and points back to
    /// the function through its own `constructor` property.
    prototype: Value = .{},
};

const AotHttpRouteKind = enum { static, callback };

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

const AotHttpHeader = struct {
    name: []u8,
    value: []u8,

    pub fn deinit(self: *AotHttpHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        self.* = undefined;
    }
};

const AotHttpServerState = struct {
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

const AotArchiveTask = struct {
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

const AotProcessMode = enum { command_output, output_callback };

const AotCommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *AotCommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

const AotProcessTask = struct {
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

const AotFileTaskOperation = enum { copy, move, delete };

const AotFileTask = struct {
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

const AotClientHttpMode = enum { callback, set_target, response_promise };

pub const AotClientHttpBodyKind = enum { text, json, binary };

const AotClientHttpTask = struct {
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

const AotHttpGlobals = struct {
    method: ?*Value = null,
    get_data: ?*Value = null,
    post_data: ?*Value = null,
    files_data: ?*Value = null,
};

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

const AotCsvDelimiterDefault = enum { comma, tab };

const aot_csv_comma = [_]u16{','};
const aot_csv_tab = [_]u16{'\t'};
const aot_csv_crlf = [_]u16{ '\r', '\n' };

pub const default_plugin_names = [_][]const u8{
    "plugin_system",
    "plugin_math",
    "plugin_promise",
    "plugin_test",
    "plugin_csv",
    "plugin_toml",
    "plugin_node",
};

/// CSV options are process-local in the official plugin. Keep the same
/// lifetime as the AOT runtime so separate builtin calls observe updates from
/// CSVオプション設定 without introducing a JavaScript runtime.
const AotCsvState = struct {
    custom_delimiter: ?[]u16 = null,
    custom_eol: ?[]u16 = null,
    delimiter_default: AotCsvDelimiterDefault = .comma,
    auto_convert_number: bool = true,

    pub fn deinit(self: *AotCsvState, allocator: std.mem.Allocator) void {
        if (self.custom_delimiter) |value| allocator.free(value);
        if (self.custom_eol) |value| allocator.free(value);
        self.* = undefined;
    }

    pub fn delimiter(self: *const AotCsvState) []const u16 {
        return self.custom_delimiter orelse switch (self.delimiter_default) {
            .comma => &aot_csv_comma,
            .tab => &aot_csv_tab,
        };
    }

    pub fn eol(self: *const AotCsvState) []const u16 {
        return self.custom_eol orelse &aot_csv_crlf;
    }

    pub fn useDelimiter(self: *AotCsvState, allocator: std.mem.Allocator, value: AotCsvDelimiterDefault) void {
        if (self.custom_delimiter) |owned| allocator.free(owned);
        self.custom_delimiter = null;
        self.delimiter_default = value;
    }

    pub fn setDelimiter(self: *AotCsvState, allocator: std.mem.Allocator, value: []const u16) !void {
        const owned = try allocator.dupe(u16, value);
        if (self.custom_delimiter) |old| allocator.free(old);
        self.custom_delimiter = owned;
    }

    pub fn setEol(self: *AotCsvState, allocator: std.mem.Allocator, value: []const u16) !void {
        const owned = try allocator.dupe(u16, value);
        if (self.custom_eol) |old| allocator.free(old);
        self.custom_eol = owned;
    }
};

pub const Arithmetic = enum(u8) {
    add,
    subtract,
    multiply,
    divide,
    remainder,
    power,
    integer_divide,
    bit_and,
    bit_or,
    bit_xor,
};

pub const Comparison = enum(u8) {
    abstract_equal,
    strict_equal,
    abstract_not_equal,
    strict_not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    deep_equal,
    deep_not_equal,
};

pub const ShiftOperator = enum(u8) {
    left,
    right,
    right_unsigned,
};

const Payload = union(enum) {
    utf16_string: []u16,
    byte_buffer: ByteBuffer,
    bigint: BigInt,
    array: std.ArrayList(Value),
    dictionary: std.ArrayList(DictionaryEntry),
    iterator: Iterator,
    function: FunctionObject,
    binding_cell: Value,
    promise: AotPromise,
};

pub const Object = struct {
    next: ?*Object = null,
    grey_next: ?*Object = null,
    marked: bool = false,
    /// Object-literal `__proto__`; the undefined value means the ordinary
    /// Object prototype and explicit null preserves a null-prototype object.
    prototype: Value = .{},
    /// Own properties for arrays and for the other extensible object kinds.
    /// The legacy field name is retained because array operations and their
    /// serialized fixtures already use it.
    array_properties: std.ArrayList(DictionaryEntry) = .empty,
    array_presence: std.ArrayList(bool) = .empty,
    toml_temporal: ?AotTomlTemporal = null,
    payload: Payload,
};

const RegisteredFunction = struct {
    name: []u8,
    object: *Object,
};

const DynamicGlobal = struct {
    name: []u8,
    value: Value = .{},
    slot: ?*Value = null,
};

const DynamicPromiseBridge = struct {
    state: *DynamicInterpreterState,
    promise: *dynamic_value.Promise,
    aot_promise: Value,
};

const AotFunctionBridge = struct {
    owner: *Runtime,
    state: *DynamicInterpreterState,
    value: Value,
};

const NamespaceFrame = struct {
    namespace: Value,
    plugin_name: Value,
};

/// Standard prototype values are singletons within one generated runtime.
/// Keep lazily synthesized property values alive and reuse them on subsequent
/// reads so AOT identity comparisons match the JavaScript prototype chain.
const StandardPropertyCacheEntry = struct {
    kind: u8,
    name: []u8,
    value: Value,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    objects: ?*Object = null,
    roots: ?*RootFrame = null,
    grey: ?*Object = null,
    object_count: usize = 0,
    next_collection: usize = 64,
    stringifying_arrays: std.ArrayList(*Object) = .empty,
    pending_exception: Value = .{},
    has_pending_exception: bool = false,
    /// Monotonic-with-wrap generation of the pending failure slot. Dispatch
    /// tracing compares this value at call boundaries so an exception left by
    /// an earlier call does not make a later successful call look failed.
    failure_epoch: u64 = 0,
    system_context: Value = .{},
    courtesy_level: f64 = std.math.nan(f64),
    print_pool: std.ArrayList(u8) = .empty,
    dispatch_trace: DispatchTrace = .{},
    global_trace: GlobalTrace = .{},
    literal_trace: LiteralTrace = .{},
    random_state: u64 = 0,
    clock_milliseconds: ?i64 = null,
    monotonic_milliseconds: ?f64 = null,
    debug_enabled: bool = false,
    aot_source_directory: ?[]u8 = null,
    caniuse_browsers: Value = .{},
    caniuse_agents: Value = .{},
    era_data: Value = .{},
    csv_state: AotCsvState = .{},
    namespace_stack: std.ArrayList(NamespaceFrame) = .empty,
    named_functions: std.ArrayList(RegisteredFunction) = .empty,
    hatena_callbacks: std.ArrayList(Value) = .empty,
    interrupt_callback: Value = .{},
    timers: std.ArrayList(AotTimer) = .empty,
    promise_tasks: std.ArrayList(AotPromiseTask) = .empty,
    promise_all_states: std.ArrayList(*AotPromiseAllState) = .empty,
    elapsed_milliseconds: u64 = 0,
    next_timer_id: u64 = 1,
    timer_event_count: usize = 0,
    stdin_bytes: ?[]u8 = null,
    stdin_offset: usize = 0,
    http_server_state: AotHttpServerState = .{},
    http_server: ?std.Io.net.Server = null,
    http_connection: ?std.Io.net.Stream = null,
    http_head_request: bool = false,
    held_http_connections: std.ArrayList(std.Io.net.Stream) = .empty,
    upload_sequence: u64 = 1,
    http_globals: ?AotHttpGlobals = null,
    archive_tool_path_custom: bool = false,
    archive_tasks: std.ArrayList(AotArchiveTask) = .empty,
    client_http_tasks: std.ArrayList(AotClientHttpTask) = .empty,
    file_process_callback: Value = .{},
    file_process_target: ?*Value = null,
    file_process_stop: bool = false,
    file_tasks: std.ArrayList(*AotFileTask) = .empty,
    process_tasks: std.ArrayList(*AotProcessTask) = .empty,
    process_completion_sequence: std.atomic.Value(u64) = .init(1),
    process_io: std.Io.Threaded = .init_single_threaded,
    process_io_initialized: bool = false,
    native_plugin_paths: std.ArrayList([]u8) = .empty,
    dynamic_globals: std.ArrayList(DynamicGlobal) = .empty,
    dynamic_state: ?*DynamicInterpreterState = null,
    dynamic_promise_bridges: std.ArrayList(*DynamicPromiseBridge) = .empty,
    dynamic_function_bridges: std.ArrayList(*AotFunctionBridge) = .empty,
    standard_property_cache: std.ArrayList(StandardPropertyCacheEntry) = .empty,

    pub fn deinit(self: *Runtime) void {
        self.dispatch_trace.deinit();
        self.global_trace.deinit();
        self.literal_trace.deinit();
        const io = std.Io.Threaded.global_single_threaded.io();
        if (self.http_connection) |*stream| stream.close(io);
        for (self.held_http_connections.items) |*stream| stream.close(io);
        self.held_http_connections.deinit(self.allocator);
        if (self.http_server) |*server| server.deinit(io);
        self.http_server_state.deinit(self.allocator);
        for (self.archive_tasks.items) |*task| task.deinit(self.allocator);
        self.archive_tasks.deinit(self.allocator);
        while (self.client_http_tasks.pop()) |task| {
            var owned = task;
            owned.deinit(self.allocator);
        }
        self.client_http_tasks.deinit(self.allocator);
        while (self.file_tasks.pop()) |task| task.deinit(self.allocator, true);
        self.file_tasks.deinit(self.allocator);
        while (self.process_tasks.pop()) |task| task.deinit(self.allocator, true);
        self.process_tasks.deinit(self.allocator);
        if (self.process_io_initialized) self.process_io.deinit();
        if (self.dynamic_state) |state| {
            state.deinit();
            self.allocator.destroy(state);
        }
        for (self.dynamic_promise_bridges.items) |bridge| self.allocator.destroy(bridge);
        self.dynamic_promise_bridges.deinit(self.allocator);
        for (self.dynamic_function_bridges.items) |bridge| self.allocator.destroy(bridge);
        self.dynamic_function_bridges.deinit(self.allocator);
        for (self.standard_property_cache.items) |entry| self.allocator.free(entry.name);
        self.standard_property_cache.deinit(self.allocator);
        for (self.native_plugin_paths.items) |path| self.allocator.free(path);
        self.native_plugin_paths.deinit(self.allocator);
        for (self.dynamic_globals.items) |entry| self.allocator.free(entry.name);
        self.dynamic_globals.deinit(self.allocator);
        self.csv_state.deinit(self.allocator);
        self.print_pool.deinit(self.allocator);
        self.namespace_stack.deinit(self.allocator);
        self.hatena_callbacks.deinit(self.allocator);
        self.timers.deinit(self.allocator);
        self.promise_tasks.deinit(self.allocator);
        for (self.promise_all_states.items) |state| self.allocator.destroy(state);
        self.promise_all_states.deinit(self.allocator);
        if (self.stdin_bytes) |bytes| self.allocator.free(bytes);
        if (self.aot_source_directory) |path| self.allocator.free(path);
        var current = self.objects;
        while (current) |object| {
            const next = object.next;
            self.destroyObject(object);
            current = next;
        }
        self.named_functions.deinit(self.allocator);
        self.stringifying_arrays.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn cachedStandardProperty(self: *Runtime, kind: u8, name: []const u8) ?Value {
        for (self.standard_property_cache.items) |entry| {
            if (entry.kind == kind and std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn cacheStandardProperty(self: *Runtime, kind: u8, name: []const u8, value: Value) !void {
        if (self.cachedStandardProperty(kind, name) != null) return;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.standard_property_cache.append(self.allocator, .{ .kind = kind, .name = owned_name, .value = value });
    }

    pub fn createString(self: *Runtime, units: []const u16) !Value {
        try self.beforeAllocation();
        const owned = try self.allocator.dupe(u16, units);
        errdefer self.allocator.free(owned);
        return self.createObject(.{ .utf16_string = owned }, .utf16_string);
    }

    pub fn createBytes(self: *Runtime, bytes: []const u8) !Value {
        return self.createByteBuffer(bytes, .buffer);
    }

    pub fn createUint8Array(self: *Runtime, bytes: []const u8) !Value {
        return self.createByteBuffer(bytes, .uint8_array);
    }

    pub fn createArrayBuffer(self: *Runtime, bytes: []const u8) !Value {
        return self.createByteBuffer(bytes, .array_buffer);
    }

    pub fn createByteStorage(self: *Runtime, bytes: []const u8) !*ByteStorage {
        const storage = try self.allocator.create(ByteStorage);
        errdefer self.allocator.destroy(storage);
        storage.* = .{ .allocator = self.allocator, .bytes = try self.allocator.dupe(u8, bytes) };
        return storage;
    }

    pub fn createByteBuffer(self: *Runtime, bytes: []const u8, kind: ByteKind) !Value {
        try self.beforeAllocation();
        const storage = try self.createByteStorage(bytes);
        errdefer storage.release();
        return self.createObject(.{ .byte_buffer = .{ .bytes = storage.bytes, .kind = kind, .storage = storage } }, .byte_buffer);
    }

    pub fn createByteBufferView(self: *Runtime, buffer: ByteBuffer, start: usize, end: usize) !Value {
        if (start > end or end > buffer.bytes.len) return error.InvalidByteBufferSlice;
        const storage = buffer.storage;
        const bytes = buffer.bytes[start..end];
        const kind = buffer.kind;
        const byte_offset = std.math.add(usize, buffer.byte_offset, start) catch return error.InvalidByteBufferSlice;
        // Retain before a possible collection so the source object may be
        // reclaimed without invalidating the view's backing allocation.
        storage.retain();
        errdefer storage.release();
        try self.beforeAllocation();
        return self.createObject(.{ .byte_buffer = .{ .bytes = bytes, .kind = kind, .storage = storage, .byte_offset = byte_offset } }, .byte_buffer);
    }

    /// Return the complete backing allocation as an ArrayBuffer view.  Keep
    /// the storage shared so a Buffer/Uint8Array and its `.buffer` observe the
    /// same bytes; the caller's GC roots keep the source live while allocating.
    pub fn createByteBufferBackingBuffer(self: *Runtime, buffer: ByteBuffer) !Value {
        const storage = buffer.storage;
        if (storage.backing.tag != @intFromEnum(Tag.undefined)) return storage.backing;
        storage.retain();
        errdefer storage.release();
        try self.beforeAllocation();
        const result = try self.createObject(.{ .byte_buffer = .{ .bytes = storage.bytes, .kind = .array_buffer, .storage = storage } }, .byte_buffer);
        storage.backing = result;
        return result;
    }

    pub fn setAotSourceDirectory(self: *Runtime, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        if (self.aot_source_directory) |previous| self.allocator.free(previous);
        self.aot_source_directory = owned;
    }

    pub fn ownString(self: *Runtime, source: []u16) !Value {
        errdefer self.allocator.free(source);
        try self.beforeAllocation();
        return self.createObject(.{ .utf16_string = source }, .utf16_string);
    }

    pub fn createBigInt(self: *Runtime, source: []const u8) !Value {
        try self.beforeAllocation();
        var value = try BigInt.parseLiteral(self.allocator, source);
        errdefer value.deinit();
        return self.createObject(.{ .bigint = value }, .bigint);
    }

    pub fn ownBigInt(self: *Runtime, source: BigInt) !Value {
        var value = source;
        errdefer value.deinit();
        try self.beforeAllocation();
        return self.createObject(.{ .bigint = value }, .bigint);
    }

    pub fn createArray(self: *Runtime, values: []const Value) !Value {
        try self.beforeAllocation();
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(self.allocator);
        try items.appendSlice(self.allocator, values);
        return self.createObject(.{ .array = items }, .array);
    }

    pub fn createDictionary(self: *Runtime, values: []const Value) !Value {
        var source_frame = RootFrame{};
        self.pushRoots(&source_frame, if (values.len == 0) null else @constCast(values.ptr), values.len);
        defer self.popRoots(&source_frame);
        try self.beforeAllocation();
        var roots = [_]Value{ try self.createObject(.{ .dictionary = .empty }, .dictionary), .{}, .{} };
        var result_frame = RootFrame{};
        self.pushRoots(&result_frame, &roots, roots.len);
        defer self.popRoots(&result_frame);
        var index: usize = 0;
        while (index + 1 < values.len) : (index += 2) {
            roots[1] = values[index];
            roots[2] = values[index + 1];
            roots[1] = try self.propertyKey(roots[1]);
            try self.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
        }
        return roots[0];
    }

    pub fn createTomlTemporal(self: *Runtime, kind: toml_temporal.Kind, json_text: []const u8, toml_text: []const u8) !Value {
        try self.beforeAllocation();
        const owned_json = try self.allocator.dupe(u8, json_text);
        errdefer self.allocator.free(owned_json);
        const owned_toml = try self.allocator.dupe(u8, toml_text);
        errdefer self.allocator.free(owned_toml);
        const result = try self.createObject(.{ .dictionary = .empty }, .dictionary);
        result.object().?.toml_temporal = .{ .kind = kind, .json_text = owned_json, .toml_text = owned_toml };
        return result;
    }

    pub fn createObjectLiteral(self: *Runtime, values: []const Value) !Value {
        var source_frame = RootFrame{};
        self.pushRoots(&source_frame, if (values.len == 0) null else @constCast(values.ptr), values.len);
        defer self.popRoots(&source_frame);

        var roots = [_]Value{ try self.createDictionary(&.{}), .{}, .{} };
        var result_frame = RootFrame{};
        self.pushRoots(&result_frame, &roots, roots.len);
        defer self.popRoots(&result_frame);
        var index: usize = 0;
        while (index + 1 < values.len) : (index += 2) {
            roots[1] = try self.propertyKey(values[index]);
            roots[2] = values[index + 1];
            if (sameKey(roots[1], staticStringValue("__proto__"))) {
                if (roots[2].tag == @intFromEnum(Tag.null_value) or roots[2].object() != null) {
                    roots[0].object().?.prototype = roots[2];
                }
            } else try self.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
        }
        return roots[0];
    }

    pub fn createIterator(self: *Runtime, values: []const Value, is_range: bool, direction: u8) !Value {
        if (values.len == 0) return error.InvalidIterator;
        try self.beforeAllocation();
        const iterator: Iterator = if (is_range) blk: {
            if (values.len < 2) return error.InvalidIterator;
            const start = valueToNumber(values[0]);
            const end = valueToNumber(values[1]);
            var step: f64 = if (values.len >= 3 and values[2].tag != @intFromEnum(Tag.undefined))
                valueToNumber(values[2])
            else if (direction == 2 or (direction == 0 and start > end)) -1 else 1;
            if (direction == 2 and step > 0) step = -step;
            if (direction == 1 and step < 0) step = -step;
            if (!std.math.isFinite(start) or !std.math.isFinite(end)) return error.InvalidIteratorRange;
            if (!std.math.isFinite(step) or step == 0) return error.InvalidIteratorStep;
            break :blk .{ .kind = .range, .current = start, .end = end, .step = step };
        } else switch (@as(Tag, @enumFromInt(values[0].tag))) {
            .number => .{ .kind = .repeat, .count = try repeatCount(valueToNumber(values[0])) },
            .utf16_string => .{ .kind = .string, .source = values[0], .count = values[0].object().?.payload.utf16_string.len },
            .byte_buffer => .{ .kind = .bytes, .source = values[0], .count = values[0].object().?.payload.byte_buffer.bytes.len },
            .array => .{ .kind = .array, .source = values[0], .count = values[0].object().?.payload.array.items.len },
            .dictionary => .{ .kind = .dictionary, .source = values[0], .count = values[0].object().?.payload.dictionary.items.len },
            else => .{ .kind = .repeat, .count = 0 },
        };
        return self.createObject(.{ .iterator = iterator }, .iterator);
    }

    pub fn createFunction(self: *Runtime, callback: FunctionCallback, arity: usize, captures: []const Value) !Value {
        return self.createNamedFunction(callback, arity, &.{}, captures);
    }

    pub fn createNamedFunction(self: *Runtime, callback: FunctionCallback, arity: usize, name: []const u8, captures: []const Value) !Value {
        return self.createFunctionObject(callback, arity, name, captures, true, .none);
    }

    pub fn createMethodFunction(self: *Runtime, callback: FunctionCallback, arity: usize, name: []const u8, captures: []const Value) !Value {
        return self.createFunctionObject(callback, arity, name, captures, false, .none);
    }

    pub fn createFunctionObject(
        self: *Runtime,
        callback: FunctionCallback,
        arity: usize,
        name: []const u8,
        captures: []const Value,
        register_global: bool,
        promise_kind: PromiseFunctionKind,
    ) !Value {
        var frame: RootFrame = .{};
        self.pushRoots(&frame, if (captures.len > 0) @constCast(captures.ptr) else null, captures.len);
        defer self.popRoots(&frame);
        try self.beforeAllocation();
        const result = blk: {
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const owned_captures = try self.allocator.dupe(Value, captures);
            errdefer self.allocator.free(owned_captures);
            break :blk try self.createObject(.{ .function = .{ .callback = callback, .arity = arity, .name = owned_name, .captures = owned_captures, .promise_kind = promise_kind } }, .function);
        };
        if (register_global and shouldRegisterNamedFunction(name)) {
            const registered_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(registered_name);
            try self.named_functions.append(self.allocator, .{ .name = registered_name, .object = result.object().? });
        }
        return result;
    }

    pub fn createPromiseSpecialFunction(self: *Runtime, name: []const u8, promise_kind: PromiseFunctionKind) !Value {
        return self.createFunctionObject(promiseSentinel, 1, name, &.{}, false, promise_kind);
    }

    pub fn createBindingCell(self: *Runtime, initial: Value) !Value {
        var rooted = initial;
        var frame: RootFrame = .{};
        self.pushRoots(&frame, @ptrCast(&rooted), 1);
        defer self.popRoots(&frame);
        try self.beforeAllocation();
        return self.createObject(.{ .binding_cell = rooted }, .binding_cell);
    }

    pub fn createObject(self: *Runtime, payload: Payload, tag: Tag) !Value {
        const object = try self.allocator.create(Object);
        errdefer {
            object.array_presence.deinit(self.allocator);
            self.allocator.destroy(object);
        }
        object.* = .{
            .next = self.objects,
            .payload = payload,
        };
        if (tag == .array) {
            try object.array_presence.resize(self.allocator, object.payload.array.items.len);
            @memset(object.array_presence.items, true);
        }
        self.objects = object;
        self.object_count += 1;
        return .{ .tag = @intFromEnum(tag), .payload = @intFromPtr(object) };
    }

    pub fn beforeAllocation(self: *Runtime) !void {
        if (self.object_count < self.next_collection) return;
        _ = self.collect();
        self.next_collection = @max(@as(usize, 64), self.object_count * 2);
    }

    pub fn pushRoots(self: *Runtime, frame: *RootFrame, values: ?[*]Value, len: usize) void {
        frame.* = .{ .previous = self.roots, .values = values, .len = len };
        self.roots = frame;
    }

    pub fn popRoots(self: *Runtime, frame: *RootFrame) void {
        if (self.roots != frame) return;
        self.roots = frame.previous;
        frame.* = .{};
    }

    pub fn collect(self: *Runtime) usize {
        var frame = self.roots;
        while (frame) |current| : (frame = current.previous) {
            if (current.values) |values| for (values[0..current.len]) |value| self.markValue(value);
        }
        if (self.has_pending_exception) self.markValue(self.pending_exception);
        self.markValue(self.system_context);
        for (self.dynamic_globals.items) |entry| self.markValue(entry.value);
        for (self.dynamic_promise_bridges.items) |bridge| self.markValue(bridge.aot_promise);
        for (self.dynamic_function_bridges.items) |bridge| self.markValue(bridge.value);
        self.markValue(self.caniuse_browsers);
        self.markValue(self.caniuse_agents);
        self.markValue(self.era_data);
        for (self.namespace_stack.items) |entry| {
            self.markValue(entry.namespace);
            self.markValue(entry.plugin_name);
        }
        for (self.hatena_callbacks.items) |callback| self.markValue(callback);
        self.markValue(self.interrupt_callback);
        for (self.timers.items) |timer| self.markValue(timer.callback);
        for (self.promise_tasks.items) |task| {
            self.markValue(task.callback);
            self.markValue(task.settled_value);
            self.markValue(.{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(task.next) });
        }
        for (self.promise_all_states.items) |state| {
            self.markValue(.{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(state.promise) });
            self.markValue(state.results);
        }
        for (self.http_server_state.routes.items) |route| {
            if (route.kind == .callback) self.markValue(route.callback);
        }
        for (self.archive_tasks.items) |task| self.markValue(task.callback);
        for (self.client_http_tasks.items) |task| {
            self.markValue(task.callback);
            self.markValue(task.promise);
            if (task.target) |target| self.markValue(target.*);
            if (task.onerror) |onerror| self.markValue(onerror.*);
        }
        self.markValue(self.file_process_callback);
        for (self.file_tasks.items) |task| self.markValue(task.callback);
        for (self.process_tasks.items) |task| self.markValue(task.callback);
        for (self.standard_property_cache.items) |entry| self.markValue(entry.value);
        while (self.grey) |object| {
            self.grey = object.grey_next;
            object.grey_next = null;
            switch (object.payload) {
                .utf16_string, .bigint => {},
                .byte_buffer => {
                    self.markValue(object.prototype);
                    self.markValue(object.payload.byte_buffer.storage.backing);
                    for (object.array_properties.items) |property| {
                        self.markValue(property.key);
                        self.markValue(property.value);
                    }
                },
                .function => |function| {
                    self.markValue(function.prototype);
                    for (object.array_properties.items) |property| {
                        self.markValue(property.key);
                        self.markValue(property.value);
                    }
                    for (function.captures) |capture| self.markValue(capture);
                    switch (function.promise_kind) {
                        .none => {},
                        .resolver => |resolver| self.markValue(.{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(resolver.promise) }),
                        .all_handler => |handler| {
                            self.markValue(.{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(handler.state.promise) });
                            self.markValue(handler.state.results);
                        },
                    }
                },
                .binding_cell => |value| self.markValue(value),
                .array => |items| {
                    self.markValue(object.prototype);
                    for (items.items) |value| self.markValue(value);
                    for (object.array_properties.items) |property| {
                        self.markValue(property.key);
                        self.markValue(property.value);
                    }
                },
                .dictionary => |entries| {
                    self.markValue(object.prototype);
                    for (entries.items) |entry| {
                        self.markValue(entry.key);
                        self.markValue(entry.value);
                    }
                },
                .iterator => |iterator| self.markValue(iterator.source),
                .promise => |promise| {
                    self.markValue(promise.result);
                    for (object.array_properties.items) |property| {
                        self.markValue(property.key);
                        self.markValue(property.value);
                    }
                    for (promise.reactions.items) |reaction| {
                        self.markValue(reaction.on_fulfilled);
                        self.markValue(reaction.on_rejected);
                        self.markValue(.{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(reaction.next) });
                    }
                },
            }
        }
        var reclaimed: usize = 0;
        var link = &self.objects;
        while (link.*) |object| {
            if (object.marked) {
                object.marked = false;
                link = &object.next;
                continue;
            }
            link.* = object.next;
            self.destroyObject(object);
            self.object_count -= 1;
            reclaimed += 1;
        }
        return reclaimed;
    }

    pub fn markValue(self: *Runtime, value: Value) void {
        const object = value.object() orelse return;
        if (object.marked) return;
        object.marked = true;
        object.grey_next = self.grey;
        self.grey = object;
    }

    pub fn setException(self: *Runtime, value: Value) void {
        self.pending_exception = value;
        self.has_pending_exception = true;
        self.failure_epoch +%= 1;
    }

    pub fn setFailure(self: *Runtime, failure: anyerror) void {
        self.setFailureText(error_message.forFailure(failure));
    }

    pub fn setFailureText(self: *Runtime, text: []const u8) void {
        const units = std.unicode.utf8ToUtf16LeAlloc(self.allocator, text) catch |allocation_failure| runtimeFailure(allocation_failure);
        defer self.allocator.free(units);
        self.setException(self.createString(units) catch |allocation_failure| runtimeFailure(allocation_failure));
    }

    pub fn setFailureUnits(self: *Runtime, units: []const u16) void {
        self.setException(self.createString(units) catch |allocation_failure| runtimeFailure(allocation_failure));
    }

    pub fn setErrorMessage(self: *Runtime, value: Value) void {
        // JavaScript's Error(undefined).message is the empty string.  The
        // other cases use the same String(value) conversion as ordinary AOT
        // text operations, including arrays and dictionaries.
        if (value.tag == @intFromEnum(Tag.undefined)) {
            self.setFailureUnits(&.{});
            return;
        }
        const units = valueUtf16Alloc(self, value) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(units);
        self.setFailureUnits(units);
    }

    pub fn setIndexAssignmentFailure(self: *Runtime, container: Value, key: Value) void {
        const key_units = valueUtf16Alloc(self, key) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(key_units);
        const key_utf8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, key_units) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(key_utf8);
        const container_name: []const u8 = if (container.tag == @intFromEnum(Tag.null_value)) "null" else "undefined";
        const message = std.fmt.allocPrint(self.allocator, "Cannot set properties of {s} (setting '{s}')", .{ container_name, key_utf8 }) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(message);
        self.setFailureText(message);
    }

    pub fn systemContext(self: *Runtime) !Value {
        if (self.system_context.tag == @intFromEnum(Tag.undefined)) self.system_context = try self.createDictionary(&.{});
        return self.system_context;
    }

    pub fn takeException(self: *Runtime) Value {
        if (!self.has_pending_exception) return .{};
        const result = self.pending_exception;
        self.pending_exception = .{};
        self.has_pending_exception = false;
        return result;
    }

    pub fn destroyObject(self: *Runtime, object: *Object) void {
        if (object.toml_temporal) |*temporal| temporal.deinit(self.allocator);
        switch (object.payload) {
            .utf16_string => |units| self.allocator.free(units),
            .byte_buffer => |buffer| {
                buffer.storage.release();
                object.array_properties.deinit(self.allocator);
            },
            .bigint => |*value| value.deinit(),
            .array => |*items| {
                items.deinit(self.allocator);
                object.array_properties.deinit(self.allocator);
                object.array_presence.deinit(self.allocator);
            },
            .dictionary => |*entries| entries.deinit(self.allocator),
            .function => |function| {
                var index: usize = 0;
                while (index < self.named_functions.items.len) {
                    if (self.named_functions.items[index].object == object) {
                        self.allocator.free(self.named_functions.items[index].name);
                        _ = self.named_functions.swapRemove(index);
                    } else {
                        index += 1;
                    }
                }
                self.allocator.free(function.name);
                self.allocator.free(function.captures);
                object.array_properties.deinit(self.allocator);
            },
            .iterator, .binding_cell => {},
            .promise => |*promise| {
                promise.reactions.deinit(self.allocator);
                object.array_properties.deinit(self.allocator);
            },
        }
        self.allocator.destroy(object);
    }

    pub fn indexGet(self: *Runtime, container: Value, key: Value) Value {
        if (container.tag == @intFromEnum(Tag.utf16_string)) {
            const index = valueIndex(key) orelse return .{};
            return self.stringAt(container, index);
        }
        const object = container.object() orelse return .{};
        return switch (object.payload) {
            .byte_buffer => {
                var rooted = [_]Value{ container, key };
                var frame = RootFrame{};
                self.pushRoots(&frame, &rooted, rooted.len);
                defer self.popRoots(&frame);
                const source = rooted[0];
                const rooted_buffer = source.object().?.payload.byte_buffer;
                const key_units = valueUtf16Alloc(self, rooted[1]) catch |failure| {
                    self.setFailure(failure);
                    return .{};
                };
                defer self.allocator.free(key_units);
                if (self.aotObjectOwnPropertyGetUnits(source.object().?, key_units)) |value| return value;
                if (tablePropertyIndex(key_units) == null) {
                    const inherited = tableInheritedProperty(self, source, .byte_buffer, key_units) catch |failure| {
                        self.setFailure(failure);
                        return .{};
                    };
                    if (inherited) |value| return value;
                }
                if (!aotByteBufferAllowsStandardPrototype(source)) {
                    const index = tablePropertyIndex(key_units) orelse return .{};
                    return if (rooted_buffer.kind == .array_buffer or index >= rooted_buffer.bytes.len)
                        .{}
                    else
                        numberValue(@floatFromInt(rooted_buffer.bytes[index]));
                }
                if (sameKey(rooted[1], staticStringValue("length"))) {
                    return if (rooted_buffer.kind == .array_buffer) .{} else numberValue(@floatFromInt(rooted_buffer.bytes.len));
                }
                if (sameKey(rooted[1], staticStringValue("buffer")) and rooted_buffer.kind != .array_buffer) {
                    return self.createByteBufferBackingBuffer(rooted_buffer) catch |failure| {
                        self.setFailure(failure);
                        return .{};
                    };
                }
                if (aotByteBufferScalarProperty(rooted_buffer, rooted[1])) |value| return value;
                const index = tablePropertyIndex(key_units) orelse return .{};
                return if (rooted_buffer.kind == .array_buffer or index >= rooted_buffer.bytes.len) .{} else numberValue(@floatFromInt(rooted_buffer.bytes[index]));
            },
            .array => aotArrayPropertyGet(self, object, key),
            .dictionary => blk: {
                var rooted = [_]Value{ container, key, .{} };
                var dictionary_frame = RootFrame{};
                self.pushRoots(&dictionary_frame, &rooted, rooted.len);
                defer self.popRoots(&dictionary_frame);
                const key_units = valueUtf16Alloc(self, rooted[1]) catch |failure| {
                    self.setFailure(failure);
                    break :blk .{};
                };
                defer self.allocator.free(key_units);
                if (dictionaryOwnProperty(rooted[0], key_units)) |value| break :blk value;
                rooted[2] = (tableInheritedProperty(self, rooted[0], .dictionary, key_units) catch |failure| {
                    self.setFailure(failure);
                    break :blk .{};
                }) orelse .{};
                break :blk rooted[2];
            },
            .function => tableRowProperty(self, container, key) catch |failure| {
                self.setFailure(failure);
                return .{};
            },
            .promise => blk: {
                var rooted = [_]Value{ container, key };
                var promise_frame = RootFrame{};
                self.pushRoots(&promise_frame, &rooted, rooted.len);
                defer self.popRoots(&promise_frame);
                const key_units = valueUtf16Alloc(self, rooted[1]) catch |failure| {
                    self.setFailure(failure);
                    break :blk .{};
                };
                defer self.allocator.free(key_units);
                break :blk self.aotObjectOwnPropertyGetUnits(rooted[0].object().?, key_units) orelse .{};
            },
            else => .{},
        };
    }

    pub fn destructureGet(_: *Runtime, source: Value, index: usize) Value {
        if (source.tag == @intFromEnum(Tag.array)) {
            const items = source.object().?.payload.array.items;
            return if (index < items.len) items[index] else .{};
        }
        return if (index == 0) source else .{};
    }

    pub fn indexSet(self: *Runtime, container: Value, key: Value, value: Value) !void {
        const object = container.object() orelse return switch (@as(Tag, @enumFromInt(container.tag))) {
            .undefined, .null_value => error.InvalidContainer,
            else => {},
        };
        switch (object.payload) {
            .array => {
                try aotArrayPropertySet(self, object, key, value);
            },
            .dictionary => |*entries| {
                var rooted = [_]Value{ container, key, value };
                var frame = RootFrame{};
                self.pushRoots(&frame, &rooted, rooted.len);
                defer self.popRoots(&frame);
                rooted[1] = try self.propertyKey(rooted[1]);
                var has_own_prototype_key = false;
                if (sameKey(rooted[1], staticStringValue("__proto__"))) for (entries.items) |entry| {
                    if (sameKey(entry.key, rooted[1])) {
                        has_own_prototype_key = true;
                        break;
                    }
                };
                if (!has_own_prototype_key and sameKey(rooted[1], staticStringValue("__proto__"))) {
                    if (rooted[2].tag == @intFromEnum(Tag.null_value) or rooted[2].object() != null) {
                        object.prototype = rooted[2];
                    }
                    return;
                }
                try self.setDictionary(entries, rooted[1], rooted[2]);
            },
            .byte_buffer => |*buffer| {
                if (buffer.kind != .array_buffer) if (valueIndex(key)) |index| {
                    const number = try valueToNumberRuntime(self, value);
                    const byte: u8 = if (!std.math.isFinite(number) or number == 0)
                        0
                    else
                        @intFromFloat(@mod(@trunc(number), 256));
                    if (index < buffer.bytes.len) buffer.bytes[index] = byte;
                    return;
                };
                const key_units = valueUtf16Alloc(self, key) catch |failure| {
                    self.setFailure(failure);
                    return failure;
                };
                defer self.allocator.free(key_units);
                if (std.mem.eql(u16, key_units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }) and
                    self.aotObjectOwnPropertyGetUnits(object, key_units) == null)
                {
                    if (value.tag == @intFromEnum(Tag.null_value) or value.object() != null) object.prototype = value;
                    return;
                }
                if (aotByteBufferReadOnlyProperty(buffer.kind, key_units)) return;
                try self.setAotOwnProperty(container, object, key, value);
            },
            .function => try self.setAotFunctionProperty(container, object, key, value),
            .promise => try self.setAotOwnProperty(container, object, key, value),
            .utf16_string, .bigint, .iterator, .binding_cell => {},
        }
    }

    pub fn setAotOwnProperty(self: *Runtime, container: Value, object: *Object, key: Value, value: Value) !void {
        var rooted = [_]Value{ container, key, value, .{} };
        var frame = RootFrame{};
        self.pushRoots(&frame, &rooted, rooted.len);
        defer self.popRoots(&frame);
        rooted[3] = try self.propertyKey(rooted[1]);
        try self.setDictionary(&object.array_properties, rooted[3], rooted[2]);
    }

    pub fn setAotFunctionProperty(self: *Runtime, container: Value, object: *Object, key: Value, value: Value) !void {
        var rooted = [_]Value{ container, key, value, .{} };
        var frame = RootFrame{};
        self.pushRoots(&frame, &rooted, rooted.len);
        defer self.popRoots(&frame);
        rooted[3] = try self.propertyKey(rooted[1]);
        // Function.prototype's length and name are non-writable own properties.
        // Keep writes ignored in AOT just as the interpreter does, rather than
        // allowing an own-property shadow to change the built-in value.
        if (sameKey(rooted[3], staticStringValue("length")) or sameKey(rooted[3], staticStringValue("name"))) return;
        try self.setDictionary(&object.array_properties, rooted[3], rooted[2]);
    }

    pub fn aotArrayPropertyGet(self: *Runtime, object: *const Object, key: Value) Value {
        var rooted = [_]Value{
            .{ .tag = @intFromEnum(Tag.array), .payload = @intFromPtr(object) },
            key,
        };
        var frame = RootFrame{};
        self.pushRoots(&frame, &rooted, rooted.len);
        defer self.popRoots(&frame);
        const key_units = valueUtf16Alloc(self, rooted[1]) catch return .{};
        defer self.allocator.free(key_units);
        return self.aotArrayPropertyGetUnits(rooted[0].object().?, key_units);
    }

    pub fn aotArrayIsPresent(_: *Runtime, object: *const Object, index: usize) bool {
        if (object.payload.array.items.len <= index) return false;
        return if (index < object.array_presence.items.len) object.array_presence.items[index] else true;
    }

    pub fn normalizeAotArrayPresence(self: *Runtime, object: *Object) !void {
        if (object.array_presence.items.len >= object.payload.array.items.len) return;
        const previous_len = object.array_presence.items.len;
        try object.array_presence.resize(self.allocator, object.payload.array.items.len);
        // Low-level append sites predate presence tracking; existing slots are
        // dense values when the metadata is first synchronized.
        @memset(object.array_presence.items[previous_len..], true);
    }

    pub fn aotArraySetIndex(self: *Runtime, object: *Object, index: usize, value: Value) !void {
        try self.normalizeAotArrayPresence(object);
        if (index >= object.payload.array.items.len) {
            const previous_len = object.payload.array.items.len;
            try object.payload.array.resize(self.allocator, index + 1);
            @memset(object.payload.array.items[previous_len..], .{});
            try object.array_presence.resize(self.allocator, index + 1);
            @memset(object.array_presence.items[previous_len..], false);
        }
        object.payload.array.items[index] = value;
        object.array_presence.items[index] = true;
    }

    pub fn aotArrayDeleteIndex(self: *Runtime, object: *Object, index: usize) !bool {
        if (index >= object.payload.array.items.len) return false;
        try self.normalizeAotArrayPresence(object);
        object.payload.array.items[index] = .{};
        object.array_presence.items[index] = false;
        return true;
    }

    pub fn aotArrayAppend(self: *Runtime, object: *Object, value: Value) !void {
        try self.normalizeAotArrayPresence(object);
        try object.payload.array.append(self.allocator, value);
        errdefer _ = object.payload.array.pop();
        try object.array_presence.append(self.allocator, true);
    }

    pub fn aotArrayPropertySet(self: *Runtime, object: *Object, key: Value, value: Value) !void {
        var rooted = [_]Value{
            .{ .tag = @intFromEnum(Tag.array), .payload = @intFromPtr(object) },
            key,
            value,
        };
        var frame = RootFrame{};
        self.pushRoots(&frame, &rooted, rooted.len);
        defer self.popRoots(&frame);
        const key_units = try valueUtf16Alloc(self, rooted[1]);
        defer self.allocator.free(key_units);
        if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthAssignment;
        if (self.aotCanonicalArrayIndexUnits(key_units)) |index| {
            try self.aotArraySetIndex(rooted[0].object().?, index, rooted[2]);
            return;
        }
        const normalized = try self.propertyKey(rooted[1]);
        if (std.mem.eql(u16, key_units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }) and
            self.aotArrayOwnPropertyGetUnits(rooted[0].object().?, key_units) == null)
        {
            if (rooted[2].tag == @intFromEnum(Tag.null_value) or rooted[2].object() != null) rooted[0].object().?.prototype = rooted[2];
            return;
        }
        try self.setDictionary(&rooted[0].object().?.array_properties, normalized, rooted[2]);
    }

    pub fn aotArrayPropertyGetUnits(self: *Runtime, object: *const Object, key_units: []const u16) Value {
        if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return numberValue(@floatFromInt(object.payload.array.items.len));
        if (self.aotArrayOwnPropertyGetUnits(object, key_units)) |value| return value;
        const source = Value{ .tag = @intFromEnum(Tag.array), .payload = @intFromPtr(object) };
        return (tableInheritedProperty(self, source, .array, key_units) catch |failure| {
            self.setFailure(failure);
            return .{};
        }) orelse .{};
    }

    pub fn aotArrayOwnPropertyGetUnits(self: *Runtime, object: *const Object, key_units: []const u16) ?Value {
        if (self.aotCanonicalArrayIndexUnits(key_units)) |index| return if (index < object.payload.array.items.len) object.payload.array.items[index] else null;
        return self.aotObjectOwnPropertyGetUnits(object, key_units);
    }

    /// Resolve an own named property shared by all extensible AOT objects.
    /// Array indices remain handled by `aotArrayOwnPropertyGetUnits` before
    /// reaching this helper.
    pub fn aotObjectOwnPropertyGetUnits(self: *Runtime, object: *const Object, key_units: []const u16) ?Value {
        for (object.array_properties.items) |property| {
            if (self.aotPropertyKeyMatchesUnits(property.key, key_units)) return property.value;
        }
        return null;
    }

    pub fn aotPropertyKeyMatchesUnits(_: *Runtime, key: Value, units: []const u16) bool {
        return switch (@as(Tag, @enumFromInt(key.tag))) {
            .static_utf8_string => staticUtf8EqualsUtf16(staticUtf8(key), units),
            .utf16_string => std.mem.eql(u16, key.object().?.payload.utf16_string, units),
            else => false,
        };
    }

    pub fn aotCanonicalArrayIndexUnits(_: *Runtime, units: []const u16) ?usize {
        if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
        var result: usize = 0;
        for (units) |unit| {
            if (unit < '0' or unit > '9') return null;
            result = std.math.mul(usize, result, 10) catch return null;
            result = std.math.add(usize, result, unit - '0') catch return null;
        }
        return if (result <= 4_294_967_294) result else null;
    }

    pub fn iteratorHasNext(_: *Runtime, value: Value) bool {
        const object = value.object() orelse return false;
        if (object.payload != .iterator) return false;
        const iterator = object.payload.iterator;
        return switch (iterator.kind) {
            .range => if (iterator.step > 0) iterator.current <= iterator.end else iterator.current >= iterator.end,
            else => iterator.index < iterator.count,
        };
    }

    pub fn iteratorNext(self: *Runtime, value: Value, repeat_target: ?*Value, value_target: ?*Value, key_target: ?*Value, range_target: ?*Value) Value {
        const object = value.object() orelse return .{};
        if (object.payload != .iterator) return .{};
        const iterator = &object.payload.iterator;
        if (!self.iteratorHasNext(value)) return .{};
        return switch (iterator.kind) {
            .repeat => blk: {
                iterator.index += 1;
                const result = numberValue(@floatFromInt(iterator.index));
                if (repeat_target) |target| target.* = result;
                break :blk result;
            },
            .range => blk: {
                const result = numberValue(iterator.current);
                iterator.current += iterator.step;
                if (range_target) |target| target.* = result;
                break :blk result;
            },
            .bytes => blk: {
                const result = numberValue(@floatFromInt(iterator.source.object().?.payload.byte_buffer.bytes[iterator.index]));
                if (key_target) |target| target.* = numberValue(@floatFromInt(iterator.index));
                iterator.index += 1;
                if (value_target) |target| target.* = result;
                break :blk result;
            },
            .string => blk: {
                const result = self.stringAt(iterator.source, iterator.index);
                if (key_target) |target| target.* = numberValue(@floatFromInt(iterator.index));
                iterator.index += 1;
                if (value_target) |target| target.* = result;
                break :blk result;
            },
            .array => blk: {
                const result = iterator.source.object().?.payload.array.items[iterator.index];
                if (key_target) |target| target.* = numberValue(@floatFromInt(iterator.index));
                iterator.index += 1;
                if (value_target) |target| target.* = result;
                break :blk result;
            },
            .dictionary => blk: {
                const entry = iterator.source.object().?.payload.dictionary.items[iterator.index];
                if (key_target) |target| target.* = entry.key;
                iterator.index += 1;
                if (value_target) |target| target.* = entry.value;
                break :blk entry.value;
            },
        };
    }

    pub fn stringAt(self: *Runtime, source: Value, index: usize) Value {
        const object = source.object() orelse return .{};
        if (object.payload != .utf16_string) return .{};
        const units = object.payload.utf16_string;
        if (index >= units.len) return .{};
        return self.createString(units[index .. index + 1]) catch .{};
    }

    pub fn setDictionary(self: *Runtime, entries: *std.ArrayList(DictionaryEntry), key: Value, value: Value) !void {
        for (entries.items) |*entry| if (sameKey(entry.key, key)) {
            entry.value = value;
            return;
        };
        try entries.append(self.allocator, .{ .key = key, .value = value });
    }

    pub fn propertyKey(self: *Runtime, key: Value) !Value {
        return switch (@as(Tag, @enumFromInt(key.tag))) {
            .static_utf8_string, .utf16_string => key,
            else => blk: {
                const units = try valueUtf16Alloc(self, key);
                defer self.allocator.free(units);
                break :blk try self.createString(units);
            },
        };
    }
};

const DynamicHostContext = struct {
    owner: *Runtime,

    pub fn host(self: *DynamicHostContext) dynamic_interpreter.Host {
        return .{
            .context = self,
            .writeFn = write,
            .sleepMillisecondsFn = sleepMilliseconds,
            .nowMillisecondsFn = nowMilliseconds,
            .monotonicMillisecondsFn = monotonicMilliseconds,
            .randomFn = random,
        };
    }

    pub fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *DynamicHostContext = @ptrCast(@alignCast(context));
        _ = self;
        writeBytes(bytes, false);
    }

    pub fn sleepMilliseconds(context: *anyopaque, milliseconds: u64) !void {
        const self: *DynamicHostContext = @ptrCast(@alignCast(context));
        self.owner.elapsed_milliseconds = std.math.add(u64, self.owner.elapsed_milliseconds, milliseconds) catch return error.TimerOverflow;
    }

    pub fn nowMilliseconds(context: *anyopaque) !i64 {
        const self: *DynamicHostContext = @ptrCast(@alignCast(context));
        return currentTimeMilliseconds(self.owner);
    }

    pub fn monotonicMilliseconds(context: *anyopaque) !f64 {
        const self: *DynamicHostContext = @ptrCast(@alignCast(context));
        return monotonicTimeMilliseconds(self.owner);
    }

    pub fn random(context: *anyopaque) !f64 {
        const self: *DynamicHostContext = @ptrCast(@alignCast(context));
        return nextRandom(self.owner);
    }
};

pub const DynamicInterpreterState = struct {
    allocator: std.mem.Allocator,
    owner: *Runtime,
    value_runtime: dynamic_value.Runtime,
    program: dynamic_ir.Program,
    interpreter: dynamic_interpreter.Interpreter,
    host_context: DynamicHostContext,
    reset_display_log: bool = false,

    pub fn init(allocator: std.mem.Allocator, owner: *Runtime) !*@This() {
        const state = try allocator.create(@This());
        errdefer allocator.destroy(state);
        state.* = undefined;
        state.allocator = allocator;
        state.owner = owner;
        state.value_runtime = dynamic_value.Runtime.init(allocator);
        var value_runtime_initialized = true;
        errdefer if (value_runtime_initialized) state.value_runtime.deinit();
        try state.value_runtime.registerRootProvider(.{ .context = state, .traceFn = traceDynamicBridges });
        var dynamic_bridge_provider_initialized = true;
        errdefer if (dynamic_bridge_provider_initialized) state.value_runtime.unregisterRootProvider(state);
        state.program = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .functions = &.{},
            .module_entries = &.{},
        };
        var program_initialized = true;
        errdefer if (program_initialized) state.program.deinit();
        const path_allocator = state.program.arena.allocator();
        const paths = try path_allocator.alloc([]const u8, owner.native_plugin_paths.items.len);
        for (owner.native_plugin_paths.items, paths) |path, *copy| copy.* = try path_allocator.dupe(u8, path);
        state.program.native_plugin_paths = paths;
        state.host_context = .{ .owner = owner };
        state.interpreter = dynamic_interpreter.Interpreter.init(
            allocator,
            &state.value_runtime,
            state.program,
            state.host_context.host(),
        );
        var interpreter_initialized = true;
        errdefer if (interpreter_initialized) state.interpreter.deinit();
        try state.interpreter.activateExternalRuntime();
        interpreter_initialized = false;
        dynamic_bridge_provider_initialized = false;
        program_initialized = false;
        value_runtime_initialized = false;
        return state;
    }

    pub fn deinit(self: *@This()) void {
        self.interpreter.deactivateExternalRuntime();
        self.interpreter.deinit();
        self.value_runtime.unregisterRootProvider(self);
        self.program.deinit();
        self.value_runtime.deinit();
        self.* = undefined;
    }
};

pub fn traceDynamicBridges(context: *anyopaque, runtime: *dynamic_value.Runtime) !void {
    const state: *DynamicInterpreterState = @ptrCast(@alignCast(context));
    for (state.owner.dynamic_promise_bridges.items) |bridge| {
        if (bridge.state == state) try runtime.traceExternal(.{ .promise = bridge.promise });
    }
}

pub fn dynamicGlobal(runtime: *Runtime, name: []const u8) ?*DynamicGlobal {
    for (runtime.dynamic_globals.items) |*entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}

pub fn upsertDynamicGlobal(runtime: *Runtime, name: []const u8, value: Value) !void {
    if (dynamicGlobal(runtime, name)) |entry| {
        entry.value = value;
        if (entry.slot) |slot| slot.* = value;
        return;
    }
    const owned_name = try runtime.allocator.dupe(u8, name);
    errdefer runtime.allocator.free(owned_name);
    try runtime.dynamic_globals.append(runtime.allocator, .{ .name = owned_name, .value = value });
}

pub fn removeAotFunctionBridge(owner: *Runtime, bridge: *AotFunctionBridge) void {
    for (owner.dynamic_function_bridges.items, 0..) |candidate, index| {
        if (candidate != bridge) continue;
        _ = owner.dynamic_function_bridges.swapRemove(index);
        owner.allocator.destroy(bridge);
        return;
    }
}

pub fn releaseAotFunctionBridge(context: *anyopaque, handle: *anyopaque) void {
    const owner: *Runtime = @ptrCast(@alignCast(context));
    const bridge: *AotFunctionBridge = @ptrCast(@alignCast(handle));
    removeAotFunctionBridge(owner, bridge);
}

pub fn callAotFunctionBridge(
    context: *anyopaque,
    handle: *anyopaque,
    _: *dynamic_value.Runtime,
    arguments: []const dynamic_value.Value,
) anyerror!dynamic_value.Value {
    const owner: *Runtime = @ptrCast(@alignCast(context));
    const bridge: *AotFunctionBridge = @ptrCast(@alignCast(handle));
    const aot_arguments = try owner.allocator.alloc(Value, arguments.len);
    defer owner.allocator.free(aot_arguments);
    @memset(aot_arguments, .{});
    var aot_roots = RootFrame{};
    owner.pushRoots(&aot_roots, aot_arguments.ptr, aot_arguments.len);
    defer owner.popRoots(&aot_roots);
    for (arguments, aot_arguments) |argument, *converted| converted.* = try dynamicToAotValue(bridge.state, argument);
    const result = try invokeAotCallback(owner, bridge.value, if (aot_arguments.len > 0) aot_arguments.ptr else null, aot_arguments.len);
    return aotToDynamicValue(bridge.state, result);
}

pub fn aotFunctionToDynamicValue(state: *DynamicInterpreterState, value: Value) anyerror!dynamic_value.Value {
    const object = value.object() orelse return error.DynamicValueUnsupported;
    if (object.payload != .function) return error.DynamicValueUnsupported;
    const function = object.payload.function;
    var dynamic_name = try state.value_runtime.stringUtf8(function.name);
    var name_roots = state.value_runtime.rootFrame();
    defer name_roots.deinit();
    try name_roots.protect(&dynamic_name);
    const bridge = try state.owner.allocator.create(AotFunctionBridge);
    bridge.* = .{ .owner = state.owner, .state = state, .value = value };
    errdefer state.owner.allocator.destroy(bridge);
    try state.owner.dynamic_function_bridges.append(state.owner.allocator, bridge);
    errdefer removeAotFunctionBridge(state.owner, bridge);
    return state.value_runtime.createExternalFunction(
        dynamic_name.string,
        function.arity,
        .{
            .binding = .{
                .context = @ptrCast(state.owner),
                .handle = @ptrCast(bridge),
                .releaseFn = releaseAotFunctionBridge,
            },
            .callFn = callAotFunctionBridge,
        },
    );
}

pub fn dynamicPromiseToAotValue(state: *DynamicInterpreterState, promise: *dynamic_value.Promise) !Value {
    for (state.owner.dynamic_promise_bridges.items) |bridge| {
        if (bridge.state == state and bridge.promise == promise) return bridge.aot_promise;
    }

    var aot_promise = try createAotPromise(state.owner);
    var roots = RootFrame{};
    state.owner.pushRoots(&roots, @ptrCast(&aot_promise), 1);
    defer state.owner.popRoots(&roots);

    const bridge = try state.owner.allocator.create(DynamicPromiseBridge);
    bridge.* = .{ .state = state, .promise = promise, .aot_promise = aot_promise };
    errdefer state.owner.allocator.destroy(bridge);
    try state.owner.dynamic_promise_bridges.append(state.owner.allocator, bridge);
    return aot_promise;
}

pub fn aotToDynamicValue(state: *DynamicInterpreterState, value: Value) anyerror!dynamic_value.Value {
    const owner = state.owner;
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => return .undefined,
        .null_value => return .null_value,
        .boolean => return .{ .boolean = value.payload != 0 },
        .number => return .{ .number = @bitCast(value.payload) },
        .static_utf8_string => return state.value_runtime.stringUtf8(staticUtf8(value)),
        .utf16_string => return state.value_runtime.stringCodeUnits(value.object().?.payload.utf16_string),
        .bigint => {
            const text = try value.object().?.payload.bigint.toString(owner.allocator, 10);
            defer owner.allocator.free(text);
            return state.value_runtime.bigIntLiteral(text);
        },
        .byte_buffer => {
            const buffer = value.object().?.payload.byte_buffer;
            return switch (buffer.kind) {
                .buffer => state.value_runtime.createBytes(buffer.bytes),
                .uint8_array => state.value_runtime.createUint8Array(buffer.bytes),
                .array_buffer => state.value_runtime.createArrayBuffer(buffer.bytes),
            };
        },
        .array => {
            var result = try state.value_runtime.createArray();
            var roots = state.value_runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&result);
            var prototype = try aotToDynamicValue(state, value.object().?.prototype);
            try roots.protect(&prototype);
            result.array.prototype = prototype;
            for (value.object().?.payload.array.items) |item| _ = try result.array.push(try aotToDynamicValue(state, item));
            for (value.object().?.array_properties.items) |property| {
                var key = try aotToDynamicValue(state, property.key);
                var item = try aotToDynamicValue(state, property.value);
                try roots.protect(&key);
                try roots.protect(&item);
                if (key != .string) return error.DynamicValueUnsupported;
                try result.array.setProperty(key.string, item);
            }
            return result;
        },
        .dictionary => {
            if (value.object().?.toml_temporal) |temporal| {
                return state.value_runtime.createTomlTemporal(temporal.kind, temporal.json_text, temporal.toml_text);
            }
            var result = try state.value_runtime.createDictionary();
            var roots = state.value_runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&result);
            for (value.object().?.payload.dictionary.items) |entry| {
                var key = try aotToDynamicValue(state, entry.key);
                var item = try aotToDynamicValue(state, entry.value);
                try roots.protect(&key);
                try roots.protect(&item);
                if (key != .string) return error.DynamicValueUnsupported;
                try result.dictionary.set(key.string, item);
            }
            return result;
        },
        .function => return aotFunctionToDynamicValue(state, value),
        .promise, .iterator, .binding_cell => return error.DynamicValueUnsupported,
    }
}

pub fn dynamicToAotValue(state: *DynamicInterpreterState, value: dynamic_value.Value) anyerror!Value {
    const owner = state.owner;
    return switch (value) {
        .undefined => .{},
        .null_value => .{ .tag = @intFromEnum(Tag.null_value) },
        .boolean => |boolean| .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(boolean) },
        .number => |number| numberValue(number),
        .string => |string| owner.createString(string.units),
        .bigint => |bigint| blk: {
            const text = try bigint.toString(owner.allocator, 10);
            defer owner.allocator.free(text);
            break :blk owner.createBigInt(text);
        },
        .bytes => |bytes| switch (bytes.kind) {
            .buffer => owner.createBytes(bytes.bytes),
            .uint8_array => owner.createUint8Array(bytes.bytes),
            .array_buffer => owner.createArrayBuffer(bytes.bytes),
        },
        .array => |array| blk: {
            var result = try owner.createArray(&.{});
            var roots = RootFrame{};
            owner.pushRoots(&roots, @ptrCast(&result), 1);
            defer owner.popRoots(&roots);
            result.object().?.prototype = try dynamicToAotValue(state, array.prototype);
            for (array.items.items) |item| try result.object().?.payload.array.append(owner.allocator, try dynamicToAotValue(state, item));
            for (array.properties.items) |property| {
                var converted_key = try owner.createString(property.key.units);
                var key_roots = RootFrame{};
                owner.pushRoots(&key_roots, @ptrCast(&converted_key), 1);
                var converted_item = try dynamicToAotValue(state, property.value);
                var item_roots = RootFrame{};
                owner.pushRoots(&item_roots, @ptrCast(&converted_item), 1);
                try owner.setDictionary(&result.object().?.array_properties, converted_key, converted_item);
                owner.popRoots(&item_roots);
                owner.popRoots(&key_roots);
            }
            break :blk result;
        },
        .dictionary => |dictionary| blk: {
            if (dictionary.kind == .toml_temporal) {
                const temporal = dictionary.toml_temporal orelse return error.DynamicValueUnsupported;
                break :blk owner.createTomlTemporal(temporal.kind, temporal.json_text, temporal.toml_text);
            }
            var result = try owner.createDictionary(&.{});
            var result_roots = RootFrame{};
            owner.pushRoots(&result_roots, @ptrCast(&result), 1);
            defer owner.popRoots(&result_roots);
            for (dictionary.keys(), dictionary.values()) |key, item| {
                var converted_key = try owner.createString(key.units);
                var key_roots = RootFrame{};
                owner.pushRoots(&key_roots, @ptrCast(&converted_key), 1);
                var converted_item = try dynamicToAotValue(state, item);
                var item_roots = RootFrame{};
                owner.pushRoots(&item_roots, @ptrCast(&converted_item), 1);
                try owner.setDictionary(&result.object().?.payload.dictionary, converted_key, converted_item);
                owner.popRoots(&item_roots);
                owner.popRoots(&key_roots);
            }
            break :blk result;
        },
        .function => error.DynamicValueUnsupported,
        .promise => |promise| dynamicPromiseToAotValue(state, promise),
    };
}

pub fn prepareDynamic(context: *anyopaque, interpreter: *dynamic_interpreter.Interpreter) anyerror!void {
    const state: *DynamicInterpreterState = @ptrCast(@alignCast(context));
    const owner = state.owner;
    for (owner.dynamic_globals.items) |*entry| {
        if (entry.slot) |slot| entry.value = slot.*;
    }
    for (owner.dynamic_globals.items) |entry| {
        var value = aotToDynamicValue(state, entry.value) catch |failure| switch (failure) {
            error.DynamicValueUnsupported => continue,
            else => return failure,
        };
        var roots = state.value_runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&value);
        try interpreter.setGlobalValue(entry.name, value);
    }
    if (state.reset_display_log) {
        var empty = try state.value_runtime.stringUtf8("");
        var roots = state.value_runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&empty);
        try interpreter.setGlobalValue("表示ログ", empty);
    }
}

pub fn syncDynamicGlobals(state: *DynamicInterpreterState) anyerror!void {
    var iterator = state.interpreter.globals.iterator();
    while (iterator.next()) |entry| {
        const value = dynamicToAotValue(state, entry.value_ptr.*) catch |failure| switch (failure) {
            error.DynamicValueUnsupported => continue,
            else => return failure,
        };
        try upsertDynamicGlobal(state.owner, entry.key_ptr.*, value);
    }
}

pub fn dynamicInterpreterState(runtime: *Runtime) !*DynamicInterpreterState {
    return if (runtime.dynamic_state) |existing| existing else blk: {
        const created = try DynamicInterpreterState.init(runtime.allocator, runtime);
        runtime.dynamic_state = created;
        break :blk created;
    };
}

pub fn nativePluginBuiltin(runtime: *Runtime, name: []const u8, arguments: []const Value) !Value {
    const state = try dynamicInterpreterState(runtime);
    const dynamic_arguments = try runtime.allocator.alloc(dynamic_value.Value, arguments.len);
    defer runtime.allocator.free(dynamic_arguments);
    @memset(dynamic_arguments, .undefined);
    var roots = state.value_runtime.rootFrame();
    defer roots.deinit();
    for (arguments, dynamic_arguments) |argument, *converted| {
        converted.* = try aotToDynamicValue(state, argument);
        try roots.protect(converted);
    }
    var result = try state.interpreter.callExternalCommand(name, dynamic_arguments);
    try roots.protect(&result);
    return dynamicToAotValue(state, result);
}

pub fn dynamicBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len == 0) return .{};
    const state = try dynamicInterpreterState(runtime);
    const source = try valueUtf8LossyAlloc(runtime, arguments[arguments.len - 1]);
    defer runtime.allocator.free(source);
    state.reset_display_log = true;
    defer state.reset_display_log = false;

    var previous_log: Value = .{};
    if (dynamicGlobal(runtime, "表示ログ")) |entry| {
        if (entry.slot) |slot| entry.value = slot.*;
        previous_log = entry.value;
    }
    var previous_roots = RootFrame{};
    runtime.pushRoots(&previous_roots, @ptrCast(&previous_log), 1);
    defer runtime.popRoots(&previous_roots);
    _ = try state.interpreter.runDynamicSource(source, prepareDynamic, state);
    const nested_log = state.interpreter.getGlobal("表示ログ") orelse dynamic_value.Value.undefined;
    try syncDynamicGlobals(state);

    var returned = try dynamicToAotValue(state, nested_log);
    var returned_roots = RootFrame{};
    runtime.pushRoots(&returned_roots, @ptrCast(&returned), 1);
    defer runtime.popRoots(&returned_roots);
    const combined = concatAotValues(runtime, previous_log, returned) catch |failure| {
        if (failure == error.DynamicValueUnsupported) return returned;
        return failure;
    };
    var rooted_combined = combined;
    var combined_roots = RootFrame{};
    runtime.pushRoots(&combined_roots, @ptrCast(&rooted_combined), 1);
    defer runtime.popRoots(&combined_roots);
    try upsertDynamicGlobal(runtime, "表示ログ", rooted_combined);
    _ = command;
    return returned;
}

pub fn concatAotValues(runtime: *Runtime, left: Value, right: Value) !Value {
    const left_units = if (left.tag == @intFromEnum(Tag.undefined)) &.{} else try valueUtf16Alloc(runtime, left);
    defer if (left.tag != @intFromEnum(Tag.undefined)) runtime.allocator.free(left_units);
    const right_units = if (right.tag == @intFromEnum(Tag.undefined)) &.{} else try valueUtf16Alloc(runtime, right);
    defer if (right.tag != @intFromEnum(Tag.undefined)) runtime.allocator.free(right_units);
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(runtime.allocator);
    try units.appendSlice(runtime.allocator, left_units);
    try units.appendSlice(runtime.allocator, right_units);
    return runtime.createString(units.items);
}

const AotPosixIfAddrs = if (builtin.os.tag == .windows) opaque {} else extern struct {
    next: ?*AotPosixIfAddrs,
    name: [*:0]const u8,
    flags: c_uint,
    address: ?*std.posix.sockaddr,
    netmask: ?*std.posix.sockaddr,
    destination: ?*std.posix.sockaddr,
    data: ?*anyopaque,
};

const AotPosixInterfaces = if (builtin.os.tag == .windows) struct {} else struct {
    pub extern "c" fn getifaddrs(result: *?*AotPosixIfAddrs) c_int;
    pub extern "c" fn freeifaddrs(result: ?*AotPosixIfAddrs) void;
};

const AotWindowsSocketAddress = extern struct {
    address: ?*std.os.windows.ws2_32.sockaddr,
    length: c_int,
};

const AotWindowsUnicastAddress = extern struct {
    alignment: u64,
    next: ?*AotWindowsUnicastAddress,
    address: AotWindowsSocketAddress,
};

const AotWindowsAdapterAddresses = extern struct {
    alignment: u64,
    next: ?*AotWindowsAdapterAddresses,
    adapter_name: ?[*:0]u8,
    first_unicast_address: ?*AotWindowsUnicastAddress,
};

const AotWindowsInterfaces = if (builtin.os.tag == .windows) struct {
    pub extern "iphlpapi" fn GetAdaptersAddresses(
        family: u32,
        flags: u32,
        reserved: ?*anyopaque,
        addresses: ?*AotWindowsAdapterAddresses,
        size: *u32,
    ) callconv(.winapi) u32;
} else struct {};

pub fn valueIndex(value: Value) ?usize {
    if (value.tag != @intFromEnum(Tag.number)) return null;
    const number: f64 = @bitCast(value.payload);
    if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number or number > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(number);
}

pub fn aotByteBufferAllowsStandardPrototype(value: Value) bool {
    const object = value.object() orelse return true;
    if (object.payload != .byte_buffer) return true;
    return switch (@as(Tag, @enumFromInt(object.prototype.tag))) {
        .null_value => false,
        .dictionary => !dictionaryPrototypeBlocksStandard(object.prototype),
        else => true,
    };
}

pub fn aotByteBufferScalarProperty(buffer: ByteBuffer, key: Value) ?Value {
    if (sameKey(key, staticStringValue("byteLength"))) return numberValue(@floatFromInt(buffer.bytes.len));
    if (sameKey(key, staticStringValue("byteOffset"))) {
        if (buffer.kind == .array_buffer) return null;
        return numberValue(@floatFromInt(buffer.byte_offset));
    }
    if (sameKey(key, staticStringValue("BYTES_PER_ELEMENT"))) {
        if (buffer.kind == .array_buffer) return null;
        return numberValue(1);
    }
    if (buffer.kind == .array_buffer) {
        if (sameKey(key, staticStringValue("maxByteLength"))) return numberValue(@floatFromInt(buffer.bytes.len));
        if (sameKey(key, staticStringValue("resizable")) or sameKey(key, staticStringValue("detached"))) {
            return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
        }
    }
    return null;
}

pub fn aotByteBufferReadOnlyProperty(kind: ByteKind, units: []const u16) bool {
    return (kind != .array_buffer and std.mem.eql(u16, units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) or
        std.mem.eql(u16, units, &.{ 'b', 'y', 't', 'e', 'L', 'e', 'n', 'g', 't', 'h' }) or
        std.mem.eql(u16, units, &.{ 'b', 'y', 't', 'e', 'O', 'f', 'f', 's', 'e', 't' }) or
        std.mem.eql(u16, units, &.{ 'B', 'Y', 'T', 'E', 'S', '_', 'P', 'E', 'R', '_', 'E', 'L', 'E', 'M', 'E', 'N', 'T' }) or
        std.mem.eql(u16, units, &.{ 'b', 'u', 'f', 'f', 'e', 'r' }) or
        std.mem.eql(u16, units, &.{ 'm', 'a', 'x', 'B', 'y', 't', 'e', 'L', 'e', 'n', 'g', 't', 'h' }) or
        std.mem.eql(u16, units, &.{ 'r', 'e', 's', 'i', 'z', 'a', 'b', 'l', 'e' }) or
        std.mem.eql(u16, units, &.{ 'd', 'e', 't', 'a', 'c', 'h', 'e', 'd' }) or
        std.mem.eql(u16, units, &.{ 'p', 'a', 'r', 'e', 'n', 't' }) or
        std.mem.eql(u16, units, &.{ 'o', 'f', 'f', 's', 'e', 't' });
}

pub fn valueToNumber(value: Value) f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .null_value => 0,
        .boolean => if (value.payload == 0) 0 else 1,
        .number => @bitCast(value.payload),
        else => std.math.nan(f64),
    };
}

pub fn valueToNumberRuntime(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => std.math.nan(f64),
        .null_value => 0,
        .boolean => if (value.payload == 0) 0 else 1,
        .number => @bitCast(value.payload),
        .static_utf8_string, .utf16_string => parseStringNumber(runtime, value),
        .bigint => error.CannotConvertBigIntToNumber,
        .byte_buffer, .array, .dictionary, .iterator, .function, .promise => valueToNumberRuntime(runtime, try valueToPrimitive(runtime, value, .number)),
        .binding_cell => unreachable,
    };
}

/// `Number(i['末尾'])` 相当。暗黙のBigInt数値変換は他の演算で拒否し、
/// 明示的な範囲終端の変換だけBigInt.toF64を許可する。
pub fn explicitRangeNumber(runtime: *Runtime, value: Value) !f64 {
    if (value.tag == @intFromEnum(Tag.bigint)) return value.object().?.payload.bigint.toF64();
    return valueToNumberRuntime(runtime, value);
}

pub fn valueToParseFloatRuntime(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => @bitCast(value.payload),
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk string_mod.parseFloatNumber(runtime.allocator, units);
        },
        .bigint => error.CannotConvertBigIntToNumber,
        .byte_buffer, .array, .dictionary, .iterator, .function, .promise => valueToParseFloatRuntime(runtime, try valueToPrimitive(runtime, value, .string)),
        .binding_cell => unreachable,
        .undefined, .null_value, .boolean => std.math.nan(f64),
    };
}

pub fn parseStringNumber(runtime: *Runtime, value: Value) !f64 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const trimmed = string_mod.trimWhitespace(units);
    if (trimmed.len == 0) return 0;
    for (trimmed) |unit| if (unit > 0x7f) return std.math.nan(f64);
    const ascii = try runtime.allocator.alloc(u8, trimmed.len);
    defer runtime.allocator.free(ascii);
    for (trimmed, 0..) |unit, index| ascii[index] = @intCast(unit);
    if (std.mem.eql(u8, ascii, "Infinity") or std.mem.eql(u8, ascii, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, ascii, "-Infinity")) return -std.math.inf(f64);
    if (std.mem.eql(u8, ascii, "NaN")) return std.math.nan(f64);
    if (ascii.len >= 2 and ascii[0] == '0') {
        const prefix = std.ascii.toLower(ascii[1]);
        if (prefix == 'x' or prefix == 'o' or prefix == 'b') {
            const base: u8 = if (prefix == 'x') 16 else if (prefix == 'o') 8 else 2;
            if (ascii.len == 2) return std.math.nan(f64);
            var result: f64 = 0;
            for (ascii[2..]) |character| {
                const digit = std.fmt.charToDigit(character, base) catch return std.math.nan(f64);
                result = result * @as(f64, @floatFromInt(base)) + @as(f64, @floatFromInt(digit));
            }
            return result;
        }
    }
    if (!validDecimalNumber(ascii)) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, ascii) catch std.math.nan(f64);
}

pub fn validDecimalNumber(text: []const u8) bool {
    var index: usize = 0;
    if (index < text.len and (text[index] == '+' or text[index] == '-')) index += 1;
    var digits: usize = 0;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) digits += 1;
    if (index < text.len and text[index] == '.') {
        index += 1;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (index < text.len and (text[index] == 'e' or text[index] == 'E')) {
        index += 1;
        if (index < text.len and (text[index] == '+' or text[index] == '-')) index += 1;
        const exponent_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        if (index == exponent_start) return false;
    }
    return index == text.len;
}

pub fn incrementNumber(runtime: *Runtime, value: Value) f64 {
    if (value.tag == @intFromEnum(Tag.bigint)) return value.object().?.payload.bigint.toF64();
    if (isString(value)) {
        const utf8 = stringUtf8Alloc(runtime, value) catch return std.math.nan(f64);
        defer runtime.allocator.free(utf8);
        const trimmed = std.mem.trim(u8, utf8, " \t\r\n\x0b\x0c");
        if (trimmed.len == 0) return 0;
        return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
    }
    return valueToNumber(value);
}

pub fn incrementValue(runtime: *Runtime, old: Value, amount: Value) Value {
    const old_number: f64 = if (old.tag == @intFromEnum(Tag.undefined)) 0 else incrementNumber(runtime, old);
    return numberValue(old_number + incrementNumber(runtime, amount));
}

pub fn isString(value: Value) bool {
    return value.tag == @intFromEnum(Tag.static_utf8_string) or value.tag == @intFromEnum(Tag.utf16_string);
}

pub fn isObject(value: Value) bool {
    return value.tag == @intFromEnum(Tag.byte_buffer) or value.tag == @intFromEnum(Tag.array) or value.tag == @intFromEnum(Tag.dictionary) or
        value.tag == @intFromEnum(Tag.iterator) or value.tag == @intFromEnum(Tag.function) or value.tag == @intFromEnum(Tag.promise);
}

pub fn stringUtf8Alloc(runtime: *Runtime, value: Value) ![]u8 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .static_utf8_string => runtime.allocator.dupe(u8, staticUtf8(value)),
        .utf16_string => (string_mod.String{
            .allocator = runtime.allocator,
            .units = value.object().?.payload.utf16_string,
        }).toUtf8Lossy(runtime.allocator),
        else => error.ExpectedString,
    };
}

const RegexpCallResult = struct { value: Value, captures: ?Value = null };

pub fn regexpCommandName(command: aot_builtin.Command) ?[]const u8 {
    return switch (command) {
        .regexp_match => "正規表現マッチ",
        .regexp_extract => "正規表現抽出",
        .regexp_replace => "正規表現置換",
        .regexp_split => "正規表現区切",
        else => null,
    };
}

pub fn setRegexpCompileFailureMessage(runtime: *Runtime, specification: []const u16, default_global: bool, failure: anyerror) !void {
    const message = try regexp.compileFailureMessageAlloc(runtime.allocator, specification, default_global, failure) orelse return;
    defer runtime.allocator.free(message);
    runtime.setFailureText(message);
}

pub fn regexpBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !RegexpCallResult {
    _ = regexpCommandName(command) orelse return error.UnknownCommand;
    const required: usize = if (command == .regexp_replace) 3 else 2;
    if (arguments.len < required) return error.InvalidArgumentCount;

    var rooted = [_]Value{ arguments[0], arguments[1], if (arguments.len > 2) arguments[2] else .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);

    const source_units = try valueUtf16Alloc(runtime, rooted[0]);
    defer runtime.allocator.free(source_units);
    const pattern_units = try valueUtf16Alloc(runtime, rooted[1]);
    defer runtime.allocator.free(pattern_units);
    var compiled = regexp.compilePattern(runtime.allocator, pattern_units, true) catch |failure| {
        try setRegexpCompileFailureMessage(runtime, pattern_units, true, failure);
        return failure;
    };
    defer compiled.deinit();

    if (command == .regexp_replace) {
        const replacement_units = try valueUtf16Alloc(runtime, rooted[2]);
        defer runtime.allocator.free(replacement_units);
        const output_units = try regexp.replaceUnits(runtime.allocator, source_units, replacement_units, &compiled);
        defer runtime.allocator.free(output_units);
        rooted[3] = try runtime.createString(output_units);
        return .{ .value = rooted[3] };
    }

    if (command == .regexp_extract or command == .regexp_split) compiled.flags.global = true;
    const matches = try regexp.findMatches(runtime.allocator, source_units, &compiled);
    defer runtime.allocator.free(matches);
    rooted[3] = try runtime.createArray(&.{});

    if (command == .regexp_match) {
        if (matches.len == 0) return .{ .value = .{ .tag = @intFromEnum(Tag.null_value) }, .captures = rooted[3] };
        if (!compiled.flags.global) {
            for (matches[0].captures[0..compiled.capture_count]) |span| {
                const item: Value = if (span.matched) try runtime.createString(source_units[span.start..span.end]) else .{};
                try rooted[3].object().?.payload.array.append(runtime.allocator, item);
            }
            rooted[4] = try runtime.createString(source_units[matches[0].span.start..matches[0].span.end]);
            return .{ .value = rooted[4], .captures = rooted[3] };
        }
        rooted[4] = try runtime.createArray(&.{});
        for (matches) |match| {
            const item = try runtime.createString(source_units[match.span.start..match.span.end]);
            try rooted[4].object().?.payload.array.append(runtime.allocator, item);
        }
        return .{ .value = rooted[4], .captures = rooted[3] };
    }

    if (command == .regexp_extract) {
        rooted[4] = try runtime.createArray(&.{});
        for (matches) |match| {
            var has_named = false;
            for (compiled.capture_names[0..compiled.capture_count]) |capture_name| if (capture_name != null) {
                has_named = true;
                break;
            };
            if (has_named) {
                rooted[5] = try runtime.createDictionary(&.{});
                for (compiled.capture_names[0..compiled.capture_count], 0..) |capture_name, index| if (capture_name) |key_units| {
                    rooted[6] = if (match.captures[index].matched) try runtime.createString(source_units[match.captures[index].start..match.captures[index].end]) else .{};
                    rooted[7] = try runtime.createString(key_units);
                    try rooted[5].object().?.payload.dictionary.append(runtime.allocator, .{ .key = rooted[7], .value = rooted[6] });
                    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[6]);
                };
                try rooted[3].object().?.payload.array.append(runtime.allocator, rooted[5]);
            } else {
                rooted[5] = try runtime.createArray(&.{});
                if (compiled.capture_count == 0) {
                    rooted[6] = try runtime.createString(source_units[match.span.start..match.span.end]);
                    try rooted[5].object().?.payload.array.append(runtime.allocator, rooted[6]);
                    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[6]);
                } else for (match.captures[0..compiled.capture_count]) |span| {
                    rooted[6] = if (span.matched) try runtime.createString(source_units[span.start..span.end]) else .{};
                    try rooted[5].object().?.payload.array.append(runtime.allocator, rooted[6]);
                    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[6]);
                }
                try rooted[3].object().?.payload.array.append(runtime.allocator, rooted[5]);
            }
        }
        return .{ .value = rooted[4], .captures = rooted[3] };
    }

    // String.split(RegExp) always uses global matching and includes captures.
    rooted[4] = rooted[3];
    var cursor: usize = 0;
    for (matches) |match| {
        if (match.span.start == match.span.end and (match.span.start == 0 or match.span.start == source_units.len or match.span.start == cursor)) continue;
        rooted[5] = try runtime.createString(source_units[cursor..match.span.start]);
        try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[5]);
        for (match.captures[0..compiled.capture_count]) |span| {
            rooted[5] = if (span.matched) try runtime.createString(source_units[span.start..span.end]) else .{};
            try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[5]);
        }
        cursor = match.span.end;
    }
    rooted[5] = try runtime.createString(source_units[cursor..]);
    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[5]);
    if (source_units.len == 0 and matches.len > 0) rooted[4].object().?.payload.array.clearRetainingCapacity();
    return .{ .value = rooted[4] };
}

/// Dedicated ABI because regexp match/extract update the system global
/// `抽出文字列` in addition to returning their normal value.
const JsonAotPath = union(enum) {
    array_index: usize,
    property: Value,
};

const JsonAotActive = struct {
    object: *Object,
    constructor: []const u8,
    path: ?JsonAotPath,
};

const JsonAotEntry = struct {
    key: Value,
    value: Value,
    insertion_index: usize,
    array_index: ?u32,
};

/// Pure AOT implementation of the JSON.stringify-backed command family.
/// Keep this serializer independent from QuickJS: the generated executable
/// must retain the same ECMAScript JSON boundary without a JavaScript engine.
pub fn jsonEncodeBuiltin(runtime: *Runtime, value: Value, pretty: bool) !Value {
    if (value.tag == @intFromEnum(Tag.undefined) or value.tag == @intFromEnum(Tag.function)) return .{};
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    var active_objects: std.ArrayList(JsonAotActive) = .empty;
    defer active_objects.deinit(runtime.allocator);
    try jsonWriteValue(runtime, &output.writer, value, pretty, 0, &active_objects, false, null);
    return runtime.ownString(try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, output.written()));
}

pub fn jsonWriteValue(
    runtime: *Runtime,
    writer: *std.Io.Writer,
    value: Value,
    pretty: bool,
    depth: usize,
    active_objects: *std.ArrayList(JsonAotActive),
    in_array: bool,
    path: ?JsonAotPath,
) !void {
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined, .function => if (in_array) try writer.writeAll("null") else return,
        .null_value => try writer.writeAll("null"),
        .boolean => try writer.writeAll(if (value.payload != 0) "true" else "false"),
        .number => {
            const number: f64 = @bitCast(value.payload);
            if (!std.math.isFinite(number)) return writer.writeAll("null");
            const text = try numberString(runtime.allocator, number);
            defer runtime.allocator.free(text);
            try writer.writeAll(text);
        },
        .bigint => return error.CannotSerializeBigInt,
        .static_utf8_string => {
            const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, staticUtf8(value));
            defer runtime.allocator.free(units);
            try jsonWriteQuotedString(writer, units);
        },
        .utf16_string => try jsonWriteQuotedString(writer, value.object().?.payload.utf16_string),
        .byte_buffer => try jsonWriteByteBuffer(writer, value.object().?.payload.byte_buffer, pretty, depth),
        .iterator, .promise => try writer.writeAll("{}"),
        .binding_cell => unreachable,
        .array => {
            const object = value.object().?;
            if (jsonActiveIndex(active_objects.items, object)) |cycle_start| {
                try jsonSetCircularFailureMessage(runtime, active_objects.items, cycle_start, path);
                return error.CircularCloneValue;
            }
            try active_objects.append(runtime.allocator, .{ .object = object, .constructor = "Array", .path = path });
            defer _ = active_objects.pop();
            const items = object.payload.array.items;
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                if (pretty) {
                    try writer.writeByte('\n');
                    try jsonWriteIndent(writer, depth + 1);
                }
                try jsonWriteValue(runtime, writer, item, pretty, depth + 1, active_objects, true, .{ .array_index = index });
            }
            if (pretty and items.len > 0) {
                try writer.writeByte('\n');
                try jsonWriteIndent(writer, depth);
            }
            try writer.writeByte(']');
        },
        .dictionary => {
            if (isAotHttpResponse(value)) return writer.writeAll("{}");
            const object = value.object().?;
            if (object.toml_temporal) |temporal| {
                try writer.writeByte('"');
                try writer.writeAll(temporal.json_text);
                return writer.writeByte('"');
            }
            if (jsonActiveIndex(active_objects.items, object)) |cycle_start| {
                try jsonSetCircularFailureMessage(runtime, active_objects.items, cycle_start, path);
                return error.CircularCloneValue;
            }
            try active_objects.append(runtime.allocator, .{ .object = object, .constructor = "Object", .path = path });
            defer _ = active_objects.pop();
            const dictionary_length = object.payload.dictionary.items.len;
            const key_roots = try runtime.allocator.alloc(Value, dictionary_length);
            defer runtime.allocator.free(key_roots);
            @memset(key_roots, .{});
            var key_frame = RootFrame{};
            runtime.pushRoots(&key_frame, if (dictionary_length > 0) key_roots.ptr else null, dictionary_length);
            defer runtime.popRoots(&key_frame);
            var entries: std.ArrayList(JsonAotEntry) = .empty;
            defer entries.deinit(runtime.allocator);
            for (object.payload.dictionary.items, 0..) |entry, insertion_index| {
                const normalized_key = try jsonAotPropertyKey(runtime, entry.key);
                key_roots[insertion_index] = normalized_key;
                var replaced = false;
                for (entries.items) |*existing| if (sameKey(existing.key, normalized_key)) {
                    // JavaScript property assignment keeps the first insertion
                    // position while a later numeric/string spelling wins.
                    existing.value = entry.value;
                    replaced = true;
                    break;
                };
                if (!replaced) try entries.append(runtime.allocator, .{
                    .key = normalized_key,
                    .value = entry.value,
                    .insertion_index = insertion_index,
                    .array_index = jsonAotArrayIndex(runtime, normalized_key),
                });
            }
            std.sort.pdq(JsonAotEntry, entries.items, {}, lessJsonAotEntry);
            try writer.writeByte('{');
            var emitted: usize = 0;
            for (entries.items) |entry| {
                if (entry.value.tag == @intFromEnum(Tag.undefined) or entry.value.tag == @intFromEnum(Tag.function)) continue;
                if (emitted > 0) try writer.writeByte(',');
                if (pretty) {
                    try writer.writeByte('\n');
                    try jsonWriteIndent(writer, depth + 1);
                }
                try jsonWriteKey(runtime, writer, entry.key);
                try writer.writeAll(if (pretty) ": " else ":");
                try jsonWriteValue(runtime, writer, entry.value, pretty, depth + 1, active_objects, false, .{ .property = entry.key });
                emitted += 1;
            }
            if (pretty and emitted > 0) {
                try writer.writeByte('\n');
                try jsonWriteIndent(writer, depth);
            }
            try writer.writeByte('}');
        },
    }
}

pub fn jsonWriteByteBuffer(writer: *std.Io.Writer, buffer: ByteBuffer, pretty: bool, depth: usize) !void {
    if (buffer.kind == .array_buffer) return writer.writeAll("{}");
    try writer.writeByte('{');
    if (buffer.kind == .uint8_array) {
        for (buffer.bytes, 0..) |byte, index| {
            if (index > 0) try writer.writeByte(',');
            if (pretty) {
                try writer.writeByte('\n');
                try jsonWriteIndent(writer, depth + 1);
            }
            try writer.print("\"{d}\":", .{index});
            if (pretty) try writer.writeByte(' ');
            try writer.print("{d}", .{byte});
        }
    } else {
        if (pretty) {
            try writer.writeByte('\n');
            try jsonWriteIndent(writer, depth + 1);
        }
        try writer.writeAll("\"type\":");
        if (pretty) try writer.writeByte(' ');
        try writer.writeAll("\"Buffer\",");
        if (pretty) {
            try writer.writeByte('\n');
            try jsonWriteIndent(writer, depth + 1);
        }
        try writer.writeAll("\"data\":");
        if (pretty) try writer.writeByte(' ');
        try writer.writeByte('[');
        for (buffer.bytes, 0..) |byte, index| {
            if (index > 0) try writer.writeByte(',');
            if (pretty and buffer.bytes.len > 0) {
                try writer.writeByte('\n');
                try jsonWriteIndent(writer, depth + 2);
            }
            try writer.print("{d}", .{byte});
        }
        if (pretty and buffer.bytes.len > 0) {
            try writer.writeByte('\n');
            try jsonWriteIndent(writer, depth + 1);
        }
        try writer.writeByte(']');
    }
    if (pretty and buffer.bytes.len > 0) {
        try writer.writeByte('\n');
        try jsonWriteIndent(writer, depth);
    }
    try writer.writeByte('}');
}

pub fn jsonActiveIndex(objects: []JsonAotActive, object: *Object) ?usize {
    for (objects, 0..) |active, index| if (active.object == object) return index;
    return null;
}

pub fn jsonAotArrayIndex(runtime: *Runtime, key: Value) ?u32 {
    const units = jsonAotKeyUnits(runtime, key) catch return null;
    defer runtime.allocator.free(units);
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var number: u64 = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        const digit: u64 = unit - '0';
        if (number > (0xffff_ffff - digit) / 10) return null;
        number = number * 10 + digit;
        if (number >= 0xffff_ffff) return null;
    }
    if (units.len == 1 and units[0] == '0') return 0;
    return @intCast(number);
}

pub fn jsonAotKeyUnits(runtime: *Runtime, key: Value) ![]u16 {
    return switch (@as(Tag, @enumFromInt(key.tag))) {
        .static_utf8_string => std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, staticUtf8(key)),
        .utf16_string => runtime.allocator.dupe(u16, key.object().?.payload.utf16_string),
        else => std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "undefined"),
    };
}

pub fn jsonAotPropertyKey(runtime: *Runtime, key: Value) !Value {
    return runtime.ownString(try valueUtf16Alloc(runtime, key));
}

pub fn lessJsonAotEntry(_: void, left: JsonAotEntry, right: JsonAotEntry) bool {
    if (left.array_index) |left_index| {
        if (right.array_index) |right_index| return left_index < right_index;
        return true;
    }
    if (right.array_index != null) return false;
    return left.insertion_index < right.insertion_index;
}

pub fn jsonWriteKey(runtime: *Runtime, writer: *std.Io.Writer, key: Value) !void {
    const units = try jsonAotKeyUnits(runtime, key);
    defer runtime.allocator.free(units);
    try jsonWriteQuotedString(writer, units);
}

pub fn jsonWriteQuotedString(writer: *std.Io.Writer, units: []const u16) !void {
    try writer.writeByte('"');
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        switch (unit) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x09 => try writer.writeAll("\\t"),
            0x0a => try writer.writeAll("\\n"),
            0x0c => try writer.writeAll("\\f"),
            0x0d => try writer.writeAll("\\r"),
            0x0000...0x0007, 0x000b, 0x000e...0x001f => try jsonWriteUnicodeEscape(writer, unit),
            0xd800...0xdbff => {
                if (index + 1 < units.len and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) {
                    const codepoint: u21 = @intCast(0x10000 + ((@as(u32, unit) - 0xd800) << 10) + (@as(u32, units[index + 1]) - 0xdc00));
                    var encoded: [4]u8 = undefined;
                    const length = try std.unicode.utf8Encode(codepoint, &encoded);
                    try writer.writeAll(encoded[0..length]);
                    index += 1;
                } else try jsonWriteUnicodeEscape(writer, unit);
            },
            0xdc00...0xdfff => try jsonWriteUnicodeEscape(writer, unit),
            else => {
                var encoded: [3]u8 = undefined;
                const length = try std.unicode.utf8Encode(@intCast(unit), &encoded);
                try writer.writeAll(encoded[0..length]);
            },
        }
        index += 1;
    }
    try writer.writeByte('"');
}

pub fn jsonWriteUnicodeEscape(writer: *std.Io.Writer, unit: u16) !void {
    const digits = "0123456789abcdef";
    try writer.writeAll("\\u");
    try writer.writeByte(digits[(unit >> 12) & 0xf]);
    try writer.writeByte(digits[(unit >> 8) & 0xf]);
    try writer.writeByte(digits[(unit >> 4) & 0xf]);
    try writer.writeByte(digits[unit & 0xf]);
}

pub fn jsonWriteIndent(writer: *std.Io.Writer, depth: usize) !void {
    var index: usize = 0;
    while (index < depth) : (index += 1) try writer.writeAll("  ");
}

pub fn jsonSetCircularFailureMessage(runtime: *Runtime, active: []JsonAotActive, cycle_start: usize, closing_path: ?JsonAotPath) !void {
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    const start_constructor = if (cycle_start < active.len) active[cycle_start].constructor else "Object";
    try output.writer.print("Converting circular structure to JSON\n    --> starting at object with constructor '{s}'\n", .{start_constructor});
    // Every active entry after the root is an edge on the current path. V8
    // prints those edges before the final edge that closes the cycle.
    var index: usize = cycle_start + 1;
    while (index < active.len) : (index += 1) {
        try output.writer.writeAll("    |     ");
        try jsonWritePath(&output.writer, runtime, active[index].path, false);
        try output.writer.print(" -> object with constructor '{s}'\n", .{active[index].constructor});
    }
    try output.writer.writeAll("    --- ");
    try jsonWritePath(&output.writer, runtime, closing_path, true);
    runtime.setFailureText(output.written());
}

pub fn jsonWritePath(writer: *std.Io.Writer, runtime: *Runtime, path: ?JsonAotPath, closing: bool) !void {
    if (path) |cycle_path| switch (cycle_path) {
        .array_index => |index| try writer.print("index {d}{s}", .{ index, if (closing) " closes the circle" else "" }),
        .property => |key| {
            const units = try jsonAotKeyUnits(runtime, key);
            defer runtime.allocator.free(units);
            const utf8 = try (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
            defer runtime.allocator.free(utf8);
            try writer.print("property '{s}'{s}", .{ utf8, if (closing) " closes the circle" else "" });
        },
    } else if (closing) try writer.writeAll("cycle closes the circle") else try writer.writeAll("cycle");
}

pub fn expectJsonAotString(runtime: *Runtime, value: Value, pretty: bool, expected: []const u8) !void {
    const encoded = try jsonEncodeBuiltin(runtime, value, pretty);
    const actual_units = try valueUtf16Alloc(runtime, encoded);
    defer runtime.allocator.free(actual_units);
    const expected_units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, expected);
    defer runtime.allocator.free(expected_units);
    try std.testing.expectEqualSlices(u16, expected_units, actual_units);
}

/// JSON.parse-compatible decoder for the native runtime.  The input and
/// output strings are UTF-16 code-unit sequences, so escaped and literal
/// lone surrogates are retained exactly as ECMAScript does.  Using
/// `std.json` here would reject those values before the Nako value layer saw
/// them; this explicit-stack parser deliberately works on u16.
const JsonAotFrameKind = enum { array, dictionary };

const JsonAotFrameState = enum {
    array_open,
    array_need_value,
    array_after_value,
    dictionary_open,
    dictionary_need_key,
    dictionary_need_value,
    dictionary_after_value,
};

const JsonAotFrame = struct {
    kind: JsonAotFrameKind,
    state: JsonAotFrameState,
    result_index: usize,
    root_base: usize,
};

const JsonAotParser = struct {
    runtime: *Runtime,
    units: []const u16,
    index: usize = 0,

    pub fn parse(self: *JsonAotParser) anyerror!Value {
        if (jsonAsciiEquals(self.units, "undefined") or jsonAsciiEquals(self.units, "Infinity") or jsonAsciiEquals(self.units, "NaN") or jsonAsciiEquals(self.units, "[object Object]")) {
            return self.failWholeSourceInvalid();
        }
        self.skipWhitespace();
        if (self.index >= self.units.len) return self.failEnd();
        // JSON nesting is not bounded by the host call stack.  Allocate all
        // parser frames and roots up front so reallocating either collection
        // can never invalidate the root slice registered with the GC.
        const max_frames = jsonAotContainerCount(self.units);
        const frame_root_count = std.math.mul(usize, max_frames, 3) catch return error.OutOfMemory;
        const root_count = std.math.add(usize, frame_root_count, 1) catch return error.OutOfMemory;
        var roots = try self.runtime.allocator.alloc(Value, root_count);
        defer self.runtime.allocator.free(roots);
        @memset(roots, .{});
        var frames = try self.runtime.allocator.alloc(JsonAotFrame, max_frames);
        defer self.runtime.allocator.free(frames);
        var root_frame = RootFrame{};
        self.runtime.pushRoots(&root_frame, roots.ptr, roots.len);
        defer self.runtime.popRoots(&root_frame);

        var frame_count: usize = 0;
        var root_done = false;
        while (true) {
            if (frame_count == 0) {
                if (root_done) {
                    self.skipWhitespace();
                    if (self.index != self.units.len) return self.failTrailing();
                    return roots[0];
                }
                if (try self.beginValue(roots, frames, &frame_count, 0)) continue;
                roots[0] = try self.parseScalar();
                root_done = true;
                continue;
            }

            const frame_index = frame_count - 1;
            const frame = frames[frame_index];
            const base = frame.root_base;
            switch (frame.state) {
                .array_open, .array_need_value => {
                    self.skipWhitespace();
                    if (frame.state == .array_open and self.consume(']')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                        continue;
                    }
                    if (try self.beginValue(roots, frames, &frame_count, base + 2)) continue;
                    roots[base + 2] = try self.parseScalar();
                    try self.attachValue(roots, frames, frame_count, base + 2);
                },
                .array_after_value => {
                    self.skipWhitespace();
                    if (self.consume(']')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                    } else if (self.consume(',')) {
                        frames[frame_index].state = .array_need_value;
                    } else if (self.index >= self.units.len) {
                        return self.failJsonMessage("Expected ',' or ']' after array element");
                    } else return self.failToken(self.index);
                },
                .dictionary_open, .dictionary_need_key => {
                    self.skipWhitespace();
                    if (frame.state == .dictionary_open and self.consume('}')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                        continue;
                    }
                    if (frame.state == .dictionary_need_key and self.index >= self.units.len) return self.failJsonMessage("Expected double-quoted property name");
                    if (frame.state == .dictionary_need_key and self.units[self.index] != '"') return self.failJsonMessage("Expected double-quoted property name");
                    if (self.index >= self.units.len or self.units[self.index] != '"') return self.failJsonMessage("Expected property name or '}'");
                    roots[base + 1] = try self.parseStringValue();
                    self.skipWhitespace();
                    if (!self.consume(':')) return self.failJsonMessage("Expected ':' after property name");
                    frames[frame_index].state = .dictionary_need_value;
                },
                .dictionary_need_value => {
                    self.skipWhitespace();
                    if (try self.beginValue(roots, frames, &frame_count, base + 2)) continue;
                    roots[base + 2] = try self.parseScalar();
                    try self.attachValue(roots, frames, frame_count, base + 2);
                },
                .dictionary_after_value => {
                    self.skipWhitespace();
                    if (self.consume('}')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                    } else if (self.consume(',')) {
                        frames[frame_index].state = .dictionary_need_key;
                    } else if (self.index >= self.units.len) {
                        return self.failJsonMessage("Expected ',' or '}' after property value");
                    } else return self.failToken(self.index);
                },
            }
        }
    }

    /// Start a scalar or container at `result_index`.  A container gets an
    /// explicit frame; a scalar is left for parseScalar so the caller can
    /// store it in a GC root before any append/set operation.
    pub fn beginValue(self: *JsonAotParser, roots: []Value, frames: []JsonAotFrame, frame_count: *usize, result_index: usize) !bool {
        if (self.index >= self.units.len) return self.failEnd();
        switch (self.units[self.index]) {
            '[' => {
                self.index += 1;
                roots[result_index] = try self.runtime.createArray(&.{});
                frames[frame_count.*] = .{ .kind = .array, .state = .array_open, .result_index = result_index, .root_base = 1 + frame_count.* * 3 };
                frame_count.* += 1;
                return true;
            },
            '{' => {
                self.index += 1;
                roots[result_index] = try self.runtime.createDictionary(&.{});
                frames[frame_count.*] = .{ .kind = .dictionary, .state = .dictionary_open, .result_index = result_index, .root_base = 1 + frame_count.* * 3 };
                frame_count.* += 1;
                return true;
            },
            else => return false,
        }
    }

    pub fn parseScalar(self: *JsonAotParser) anyerror!Value {
        if (self.index >= self.units.len) return self.failEnd();
        return switch (self.units[self.index]) {
            'n' => try self.parseLiteral("null", .{ .tag = @intFromEnum(Tag.null_value) }),
            't' => try self.parseLiteral("true", .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 }),
            'f' => try self.parseLiteral("false", .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 }),
            '"' => try self.parseStringValue(),
            '-', '0'...'9' => try self.parseNumber(),
            else => self.failToken(self.index),
        };
    }

    pub fn attachValue(self: *JsonAotParser, roots: []Value, frames: []JsonAotFrame, frame_count: usize, value_index: usize) !void {
        const parent_index = frame_count - 1;
        const parent = frames[parent_index];
        const parent_base = parent.root_base;
        switch (frames[parent_index].kind) {
            .array => {
                try roots[parent.result_index].object().?.payload.array.append(self.runtime.allocator, roots[value_index]);
                frames[parent_index].state = .array_after_value;
            },
            .dictionary => {
                try self.runtime.setDictionary(&roots[parent.result_index].object().?.payload.dictionary, roots[parent_base + 1], roots[value_index]);
                frames[parent_index].state = .dictionary_after_value;
            },
        }
    }

    pub fn closeFrame(self: *JsonAotParser, roots: []Value, frames: []JsonAotFrame, frame_count: *usize) !void {
        const child_index = frame_count.* - 1;
        const child_base = frames[child_index].result_index;
        frame_count.* -= 1;
        if (frame_count.* == 0) {
            roots[0] = roots[child_base];
            return;
        }
        try self.attachValue(roots, frames, frame_count.*, child_base);
    }

    pub fn parseLiteral(self: *JsonAotParser, comptime literal: []const u8, value: Value) anyerror!Value {
        if (self.index + literal.len > self.units.len) return self.failEnd();
        for (literal, 0..) |byte, offset| if (self.units[self.index + offset] != byte) return self.failToken(self.index + offset);
        self.index += literal.len;
        return value;
    }

    pub fn parseStringValue(self: *JsonAotParser) anyerror!Value {
        const units = try self.parseStringUnits();
        defer self.runtime.allocator.free(units);
        return self.runtime.createString(units);
    }

    pub fn parseStringUnits(self: *JsonAotParser) anyerror![]u16 {
        if (self.index >= self.units.len or self.units[self.index] != '"') return self.failToken(self.index);
        self.index += 1;
        var result: std.ArrayList(u16) = .empty;
        errdefer result.deinit(self.runtime.allocator);
        while (self.index < self.units.len) {
            const unit = self.units[self.index];
            self.index += 1;
            switch (unit) {
                '"' => return result.toOwnedSlice(self.runtime.allocator),
                '\\' => {
                    if (self.index >= self.units.len) return self.failEnd();
                    const escaped = self.units[self.index];
                    self.index += 1;
                    switch (escaped) {
                        '"', '\\', '/' => try result.append(self.runtime.allocator, escaped),
                        'b' => try result.append(self.runtime.allocator, 0x08),
                        'f' => try result.append(self.runtime.allocator, 0x0c),
                        'n' => try result.append(self.runtime.allocator, 0x0a),
                        'r' => try result.append(self.runtime.allocator, 0x0d),
                        't' => try result.append(self.runtime.allocator, 0x09),
                        'u' => {
                            if (self.index + 4 > self.units.len) return self.failJsonMessageAt("Bad Unicode escape", if (self.units.len > 0 and self.units[self.units.len - 1] == '"') self.units.len - 1 else self.units.len);
                            var code_unit: u16 = 0;
                            for (self.units[self.index .. self.index + 4], 0..) |digit, offset| {
                                const value = jsonHexDigit(digit) orelse return self.failJsonMessageAt("Bad Unicode escape", self.index + offset);
                                code_unit = (code_unit << 4) | value;
                            }
                            self.index += 4;
                            // ECMAScript JSON.parse preserves lone surrogates.
                            // A valid pair is also kept as two UTF-16 units.
                            try result.append(self.runtime.allocator, code_unit);
                        },
                        else => return self.failJsonMessageAt("Bad escaped character", self.index - 1),
                    }
                },
                0...0x1f => return self.failJsonMessageAt("Bad control character in string literal", self.index - 1),
                else => try result.append(self.runtime.allocator, unit),
            }
        }
        return self.failJsonMessage("Unterminated string");
    }

    pub fn parseNumber(self: *JsonAotParser) anyerror!Value {
        const start = self.index;
        if (self.consume('-') and (self.index >= self.units.len or !isJsonDigit(self.units[self.index]))) return self.failJsonMessage("No number after minus sign");
        if (self.consume('0')) {
            if (self.index < self.units.len and isJsonDigit(self.units[self.index])) return self.failJsonMessage("Unexpected number");
        } else {
            if (self.index >= self.units.len or self.units[self.index] < '1' or self.units[self.index] > '9') return self.failToken(self.index);
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        if (self.consume('.')) {
            if (self.index >= self.units.len or !isJsonDigit(self.units[self.index])) return self.failJsonMessage("Unterminated fractional number");
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        if (self.index < self.units.len and (self.units[self.index] == 'e' or self.units[self.index] == 'E')) {
            self.index += 1;
            _ = self.consume('+') or self.consume('-');
            if (self.index >= self.units.len or !isJsonDigit(self.units[self.index])) return self.failJsonMessage("Exponent part is missing a number");
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        const number_units = self.units[start..self.index];
        var ascii = try self.runtime.allocator.alloc(u8, number_units.len);
        defer self.runtime.allocator.free(ascii);
        for (number_units, 0..) |unit, offset| ascii[offset] = @intCast(unit);
        const number = std.fmt.parseFloat(f64, ascii) catch jsonParseDecimal(number_units);
        return .{ .tag = @intFromEnum(Tag.number), .payload = @bitCast(number) };
    }

    pub fn consume(self: *JsonAotParser, expected: u16) bool {
        if (self.index < self.units.len and self.units[self.index] == expected) {
            self.index += 1;
            return true;
        }
        return false;
    }

    pub fn skipWhitespace(self: *JsonAotParser) void {
        while (self.index < self.units.len) switch (self.units[self.index]) {
            ' ', '\n', '\r', '\t' => self.index += 1,
            else => return,
        };
    }

    pub fn failEnd(self: *JsonAotParser) anyerror {
        self.runtime.setFailureText("Unexpected end of JSON input");
        return error.InvalidJsonCloneValue;
    }

    pub fn failJsonMessage(self: *JsonAotParser, prefix: []const u8) anyerror {
        return self.failJsonMessageAt(prefix, self.index);
    }

    pub fn failJsonMessageAt(self: *JsonAotParser, prefix: []const u8, position: usize) anyerror {
        var line: usize = 1;
        var column: usize = 1;
        const bounded = @min(position, self.units.len);
        var offset: usize = 0;
        while (offset < bounded) : (offset += 1) {
            const unit = self.units[offset];
            if (unit == '\r') {
                if (offset + 1 < bounded and self.units[offset + 1] == '\n') offset += 1;
                line += 1;
                column = 1;
                continue;
            }
            if (unit == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        const message = std.fmt.allocPrint(self.runtime.allocator, "{s} in JSON at position {d} (line {d} column {d})", .{ prefix, bounded, line, column }) catch return error.InvalidJsonCloneValue;
        defer self.runtime.allocator.free(message);
        self.runtime.setFailureText(message);
        return error.InvalidJsonCloneValue;
    }

    pub fn failToken(self: *JsonAotParser, position: usize) anyerror {
        if (position >= self.units.len) return self.failEnd();
        var message: std.ArrayList(u16) = .empty;
        errdefer message.deinit(self.runtime.allocator);
        try appendAsciiUnits(&message, self.runtime.allocator, "Unexpected token '");
        try message.append(self.runtime.allocator, self.units[position]);
        try appendAsciiUnits(&message, self.runtime.allocator, "', ");
        try self.appendJsonErrorSourceUnits(&message, true, position);
        try appendAsciiUnits(&message, self.runtime.allocator, " is not valid JSON");
        self.runtime.setFailureUnits(message.items);
        return error.InvalidJsonCloneValue;
    }

    pub fn failWholeSourceInvalid(self: *JsonAotParser) anyerror {
        var message: std.ArrayList(u16) = .empty;
        errdefer message.deinit(self.runtime.allocator);
        try self.appendJsonErrorSourceUnits(&message, false, 0);
        try appendAsciiUnits(&message, self.runtime.allocator, " is not valid JSON");
        self.runtime.setFailureUnits(message.items);
        return error.InvalidJsonCloneValue;
    }

    /// V8 shows a UTF-16 window of at most ten code units on either side of
    /// the invalid token.  Diagnostic source text is not JSON-escaped: raw
    /// quotes, backslashes, and control units are retained by Node 24.
    pub fn appendJsonErrorSourceUnits(self: *JsonAotParser, output: *std.ArrayList(u16), truncate: bool, position: usize) !void {
        const bounded = @min(position, self.units.len);
        const should_truncate = truncate and self.units.len > 20;
        const start = if (should_truncate and bounded > 10) bounded - 10 else 0;
        const end = if (should_truncate) @min(self.units.len, bounded + 10) else self.units.len;
        const leading_ellipsis = should_truncate and (start > 0 or bounded >= 10);
        if (leading_ellipsis) try appendAsciiUnits(output, self.runtime.allocator, "...");
        try output.append(self.runtime.allocator, '"');
        try output.appendSlice(self.runtime.allocator, self.units[start..end]);
        try output.append(self.runtime.allocator, '"');
        if (should_truncate and end < self.units.len) try appendAsciiUnits(output, self.runtime.allocator, "...");
    }

    pub fn failTrailing(self: *JsonAotParser) anyerror {
        const position = self.index;
        var line: usize = 1;
        var column: usize = 1;
        var offset: usize = 0;
        while (offset < position) : (offset += 1) {
            const unit = self.units[offset];
            if (unit == '\r') {
                if (offset + 1 < position and self.units[offset + 1] == '\n') offset += 1;
                line += 1;
                column = 1;
            } else if (unit == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        const message = std.fmt.allocPrint(self.runtime.allocator, "Unexpected non-whitespace character after JSON at position {d} (line {d} column {d})", .{ position, line, column }) catch return error.InvalidJsonCloneValue;
        defer self.runtime.allocator.free(message);
        self.runtime.setFailureText(message);
        return error.InvalidJsonCloneValue;
    }
};

pub fn appendAsciiUnits(output: *std.ArrayList(u16), allocator: std.mem.Allocator, ascii: []const u8) !void {
    for (ascii) |byte| try output.append(allocator, byte);
}

pub fn appendUtf8Units(output: *std.ArrayList(u16), allocator: std.mem.Allocator, text: []const u8) !void {
    const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(units);
    try output.appendSlice(allocator, units);
}

pub fn jsonHexDigit(unit: u16) ?u16 {
    return if (unit >= '0' and unit <= '9') unit - '0' else if (unit >= 'a' and unit <= 'f') unit - 'a' + 10 else if (unit >= 'A' and unit <= 'F') unit - 'A' + 10 else null;
}

pub fn isJsonDigit(unit: u16) bool {
    return unit >= '0' and unit <= '9';
}

pub fn jsonAsciiEquals(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |unit, byte| if (unit != byte) return false;
    return true;
}

/// Count only container starts outside JSON strings.  This is a sizing scan,
/// not validation: malformed input may still be rejected by the parser, but
/// every opening token the parser could process is counted unless it is inside
/// the same string/escape state that parseStringUnits uses.
pub fn jsonAotContainerCount(units: []const u16) usize {
    var count: usize = 0;
    var in_string = false;
    var escaped = false;
    for (units) |unit| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (unit == '\\') {
                escaped = true;
            } else if (unit == '"') {
                in_string = false;
            }
            continue;
        }
        if (unit == '"') {
            in_string = true;
        } else if (unit == '[' or unit == '{') {
            count = std.math.add(usize, count, 1) catch return std.math.maxInt(usize);
        }
    }
    return @max(count, 1);
}

pub fn jsonParseDecimal(units: []const u16) f64 {
    var index: usize = 0;
    const negative = units.len > 0 and units[0] == '-';
    if (negative) index += 1;
    var value: f64 = 0;
    while (index < units.len and isJsonDigit(units[index])) : (index += 1) value = value * 10 + @as(f64, @floatFromInt(units[index] - '0'));
    if (index < units.len and units[index] == '.') {
        index += 1;
        var scale: f64 = 0.1;
        while (index < units.len and isJsonDigit(units[index])) : (index += 1) {
            value += @as(f64, @floatFromInt(units[index] - '0')) * scale;
            scale *= 0.1;
        }
    }
    var exponent: i32 = 0;
    if (index < units.len and (units[index] == 'e' or units[index] == 'E')) {
        index += 1;
        var exponent_negative = false;
        if (index < units.len and (units[index] == '+' or units[index] == '-')) {
            exponent_negative = units[index] == '-';
            index += 1;
        }
        while (index < units.len and isJsonDigit(units[index])) : (index += 1) exponent = @min(@as(i32, 10000), exponent * 10 + @as(i32, @intCast(units[index] - '0')));
        if (exponent_negative) exponent = -exponent;
    }
    const result = value * std.math.pow(f64, 10, @floatFromInt(exponent));
    return if (negative) -result else result;
}

pub fn jsonDecodeBuiltin(runtime: *Runtime, source: Value) !Value {
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    var parser = JsonAotParser{ .runtime = runtime, .units = units };
    return parser.parse();
}

pub fn expectUtf16String(runtime: *Runtime, value: Value, expected: []const u8) !void {
    const actual = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(actual);
    const expected_units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, expected);
    defer runtime.allocator.free(expected_units);
    try std.testing.expectEqualSlices(u16, expected_units, actual);
}

pub fn createJsonTestString(runtime: *Runtime, text: []const u8) !Value {
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

pub fn jsonTestDictionaryGet(value: Value, key: []const u16) Value {
    return dictionaryProperty(value, key);
}

pub fn valueUtf16Alloc(runtime: *Runtime, value: Value) anyerror![]u16 {
    if (value.tag == @intFromEnum(Tag.utf16_string)) return runtime.allocator.dupe(u16, value.object().?.payload.utf16_string);
    const utf8 = switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => try runtime.allocator.dupe(u8, "undefined"),
        .null_value => try runtime.allocator.dupe(u8, "null"),
        .boolean => try runtime.allocator.dupe(u8, if (value.payload == 0) "false" else "true"),
        .number => try numberString(runtime.allocator, @bitCast(value.payload)),
        .static_utf8_string => try runtime.allocator.dupe(u8, staticUtf8(value)),
        .utf16_string => unreachable,
        .byte_buffer, .function, .promise => {
            // All object text conversion, including host objects with an own
            // custom `toString`/`valueOf`, goes through the same
            // ToPrimitive path used by arithmetic and comparisons.
            const primitive = try valueToPrimitive(runtime, value, .string);
            return valueUtf16Alloc(runtime, primitive);
        },
        .bigint => try value.object().?.payload.bigint.toString(runtime.allocator, 10),
        .array => {
            // `valueUtf16Alloc` is the AOT String(value) boundary. Resolve an
            // array's own custom ToPrimitive method before the ordinary join.
            const primitive = try valueToPrimitive(runtime, value, .string);
            return valueUtf16Alloc(runtime, primitive);
        },
        .dictionary => {
            // `valueUtf16Alloc` is the AOT String(value) boundary. Resolve a
            // dictionary's custom ToPrimitive result before falling back to
            // the ordinary object tag text.
            const primitive = try valueToPrimitive(runtime, value, .string);
            return valueUtf16Alloc(runtime, primitive);
        },
        .iterator => try runtime.allocator.dupe(u8, "[object Object]"),
        .binding_cell => unreachable,
    };
    defer runtime.allocator.free(utf8);
    return std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, utf8);
}

pub fn byteBufferUtf16Alloc(runtime: *Runtime, buffer: ByteBuffer) ![]u16 {
    return switch (buffer.kind) {
        .buffer => blk: {
            var string = try string_mod.String.fromUtf8Lossy(runtime.allocator, buffer.bytes);
            defer string.deinit();
            break :blk runtime.allocator.dupe(u16, string.units);
        },
        .uint8_array => blk: {
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(runtime.allocator);
            for (buffer.bytes, 0..) |byte, index| {
                if (index > 0) try output.append(runtime.allocator, ',');
                var number: [3]u8 = undefined;
                const rendered = std.fmt.bufPrint(&number, "{d}", .{byte}) catch unreachable;
                try output.appendSlice(runtime.allocator, rendered);
            }
            break :blk std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, output.items);
        },
        .array_buffer => std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "[object ArrayBuffer]"),
    };
}

pub fn functionStringUtf16Alloc(runtime: *Runtime, name: []const u8) ![]u16 {
    const utf8 = try std.fmt.allocPrint(runtime.allocator, "function {s}() {{ [native code] }}", .{name});
    defer runtime.allocator.free(utf8);
    return std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, utf8);
}

pub fn arrayUtf16Alloc(runtime: *Runtime, object: *Object) anyerror![]u16 {
    for (runtime.stringifying_arrays.items) |active| if (active == object) return runtime.allocator.alloc(u16, 0);
    try runtime.stringifying_arrays.append(runtime.allocator, object);
    defer _ = runtime.stringifying_arrays.pop();
    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    for (object.payload.array.items, 0..) |item, index| {
        if (index > 0) try output.append(runtime.allocator, ',');
        if (item.tag == @intFromEnum(Tag.undefined) or item.tag == @intFromEnum(Tag.null_value)) continue;
        const units = try valueUtf16Alloc(runtime, item);
        defer runtime.allocator.free(units);
        try output.appendSlice(runtime.allocator, units);
    }
    return output.toOwnedSlice(runtime.allocator);
}

pub fn isAotObjectValue(value: Value) bool {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .byte_buffer, .array, .dictionary, .iterator, .function, .promise => true,
        else => false,
    };
}

pub fn valueToPrimitive(runtime: *Runtime, value: Value, hint: AotPrimitiveHint) !Value {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .byte_buffer, .function, .promise => try hostObjectToPrimitive(runtime, value, hint),
        .array => try arrayToPrimitive(runtime, value, hint),
        .dictionary => try dictionaryToPrimitive(runtime, value, hint),
        .iterator => staticStringValue("[object Object]"),
        else => value,
    };
}

pub fn hostObjectToPrimitive(runtime: *Runtime, value: Value, hint: AotPrimitiveHint) !Value {
    const to_string_name: []const u16 = &.{ 't', 'o', 'S', 't', 'r', 'i', 'n', 'g' };
    const value_of_name: []const u16 = &.{ 'v', 'a', 'l', 'u', 'e', 'O', 'f' };
    const first = if (hint == .string) to_string_name else value_of_name;
    const second = if (hint == .string) value_of_name else to_string_name;

    var roots = [_]Value{ value, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const object = roots[0].object().?;

    for ([_][]const u16{ first, second }) |name| {
        const method = runtime.aotObjectOwnPropertyGetUnits(object, name) orelse aotCustomObjectPrototypeProperty(roots[0], name);
        if (method) |callable| {
            if (callable.tag == @intFromEnum(Tag.undefined) or callable.tag == @intFromEnum(Tag.null_value)) continue;
            if (callable.tag != @intFromEnum(Tag.function)) return error.NotCallable;
            roots[1] = try invokeAotCallback(runtime, callable, null, 0);
            if (!isAotObjectValue(roots[1])) return roots[1];
            continue;
        }
        // The host object's ordinary inherited toString is represented by
        // the existing default conversion.  It is selected only when no own
        // property shadows it, matching OrdinaryToPrimitive's method lookup.
        if (std.mem.eql(u16, name, to_string_name)) {
            return switch (@as(Tag, @enumFromInt(roots[0].tag))) {
                .byte_buffer => blk: {
                    const units = try byteBufferUtf16Alloc(runtime, object.payload.byte_buffer);
                    defer runtime.allocator.free(units);
                    break :blk try runtime.createString(units);
                },
                .function => blk: {
                    const units = try functionStringUtf16Alloc(runtime, object.payload.function.name);
                    defer runtime.allocator.free(units);
                    break :blk try runtime.createString(units);
                },
                .promise => staticStringValue("[object Promise]"),
                else => error.CannotConvertObjectToPrimitive,
            };
        }
    }
    return error.CannotConvertObjectToPrimitive;
}

/// Return only properties supplied by an explicitly assigned object
/// prototype.  The synthesized standard Buffer/TypedArray/ArrayBuffer
/// methods are deliberately excluded: hostObjectToPrimitive handles their
/// built-in conversion itself when no custom override exists.
pub fn aotCustomObjectPrototypeProperty(value: Value, key: []const u16) ?Value {
    const object = value.object() orelse return null;
    if (object.prototype.tag != @intFromEnum(Tag.dictionary)) return null;
    return dictionaryOwnProperty(object.prototype, key) orelse dictionaryPrototypeProperty(object.prototype, key);
}

pub fn arrayToPrimitive(runtime: *Runtime, value: Value, hint: AotPrimitiveHint) !Value {
    const to_string_name: []const u16 = &.{ 't', 'o', 'S', 't', 'r', 'i', 'n', 'g' };
    const value_of_name: []const u16 = &.{ 'v', 'a', 'l', 'u', 'e', 'O', 'f' };
    const first = if (hint == .string) to_string_name else value_of_name;
    const second = if (hint == .string) value_of_name else to_string_name;

    var roots = [_]Value{ value, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    for ([_][]const u16{ first, second }) |name| {
        const method = runtime.aotArrayOwnPropertyGetUnits(roots[0].object().?, name) orelse arrayPrototypeProperty(roots[0], name);
        if (method) |callable| {
            if (callable.tag == @intFromEnum(Tag.undefined) or callable.tag == @intFromEnum(Tag.null_value)) continue;
            if (callable.tag != @intFromEnum(Tag.function)) return error.NotCallable;
            roots[1] = try invokeAotCallback(runtime, callable, null, 0);
            if (!isAotObjectValue(roots[1])) return roots[1];
            continue;
        }
        if (std.mem.eql(u16, name, to_string_name) and !arrayPrototypeBlocksStandard(roots[0])) {
            const units = try arrayUtf16Alloc(runtime, roots[0].object().?);
            defer runtime.allocator.free(units);
            return runtime.createString(units);
        }
    }
    return error.CannotConvertObjectToPrimitive;
}

pub fn dictionaryToPrimitive(runtime: *Runtime, value: Value, hint: AotPrimitiveHint) !Value {
    const to_string_name: []const u16 = &.{ 't', 'o', 'S', 't', 'r', 'i', 'n', 'g' };
    const value_of_name: []const u16 = &.{ 'v', 'a', 'l', 'u', 'e', 'O', 'f' };
    const first = if (hint == .string) to_string_name else value_of_name;
    const second = if (hint == .string) value_of_name else to_string_name;

    var roots = [_]Value{ value, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    for ([_][]const u16{ first, second }) |name| {
        const method = dictionaryOwnProperty(roots[0], name) orelse dictionaryPrototypeProperty(roots[0], name);
        if (method) |callable| {
            if (callable.tag == @intFromEnum(Tag.undefined) or callable.tag == @intFromEnum(Tag.null_value)) continue;
            if (callable.tag != @intFromEnum(Tag.function)) return error.NotCallable;
            roots[1] = try invokeAotCallback(runtime, callable, null, 0);
            if (!isAotObjectValue(roots[1])) return roots[1];
            continue;
        }
        if (std.mem.eql(u16, name, to_string_name)) {
            return if (isAotHttpResponse(roots[0])) staticStringValue("[object Response]") else staticStringValue("[object Object]");
        }
    }
    return error.CannotConvertObjectToPrimitive;
}

pub fn stringEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    const left_units = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_units);
    const right_units = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_units);
    return std.mem.eql(u16, left_units, right_units);
}

pub fn stringOrder(runtime: *Runtime, left: Value, right: Value) !std.math.Order {
    const left_units = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_units);
    const right_units = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_units);
    return std.mem.order(u16, left_units, right_units);
}

pub fn strictEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    if (isString(left) and isString(right)) return stringEqual(runtime, left, right);
    if (left.tag != right.tag) return false;
    return switch (@as(Tag, @enumFromInt(left.tag))) {
        .undefined, .null_value => true,
        .boolean => (left.payload != 0) == (right.payload != 0),
        .number => blk: {
            const left_number: f64 = @bitCast(left.payload);
            const right_number: f64 = @bitCast(right.payload);
            break :blk !std.math.isNan(left_number) and !std.math.isNan(right_number) and left_number == right_number;
        },
        .bigint => BigInt.eql(left.object().?.payload.bigint, right.object().?.payload.bigint),
        .static_utf8_string, .utf16_string => unreachable,
        .byte_buffer => left.payload == right.payload,
        .array, .dictionary, .iterator, .function, .promise => left.payload == right.payload,
        .binding_cell => unreachable,
    };
}

/// Node's `assert.strictEqual` uses SameValue semantics rather than the
/// language `===` operator: NaN compares equal to NaN and signed zeroes stay
/// distinct. Objects retain reference identity just like strictEqual.
pub fn sameValue(runtime: *Runtime, left: Value, right: Value) !bool {
    if (isString(left) and isString(right)) return stringEqual(runtime, left, right);
    if (left.tag != right.tag) return false;
    if (@as(Tag, @enumFromInt(left.tag)) == .number) {
        const left_number: f64 = @bitCast(left.payload);
        const right_number: f64 = @bitCast(right.payload);
        if (std.math.isNan(left_number) and std.math.isNan(right_number)) return true;
        return @as(u64, @bitCast(left_number)) == @as(u64, @bitCast(right_number));
    }
    return strictEqual(runtime, left, right);
}

/// Array.prototype.includes uses SameValueZero: NaN matches NaN and signed
/// zeroes compare equal, while objects retain reference identity.
pub fn sameValueZero(runtime: *Runtime, left: Value, right: Value) !bool {
    if (isString(left) and isString(right)) return stringEqual(runtime, left, right);
    if (left.tag != right.tag) return false;
    return switch (@as(Tag, @enumFromInt(left.tag))) {
        .number => blk: {
            const left_number: f64 = @bitCast(left.payload);
            const right_number: f64 = @bitCast(right.payload);
            break :blk (std.math.isNan(left_number) and std.math.isNan(right_number)) or left_number == right_number;
        },
        else => strictEqual(runtime, left, right),
    };
}

pub fn abstractEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    if ((isString(left) and isString(right)) or left.tag == right.tag) return strictEqual(runtime, left, right);
    const left_tag: Tag = @enumFromInt(left.tag);
    const right_tag: Tag = @enumFromInt(right.tag);
    if ((left_tag == .undefined and right_tag == .null_value) or (left_tag == .null_value and right_tag == .undefined)) return true;
    if (isObject(left) and isObject(right)) return false;
    if (left_tag == .boolean) return abstractEqual(runtime, numberValue(if (left.payload == 0) 0 else 1), right);
    if (right_tag == .boolean) return abstractEqual(runtime, left, numberValue(if (right.payload == 0) 0 else 1));
    if (left_tag == .byte_buffer or left_tag == .array or left_tag == .dictionary or left_tag == .iterator or left_tag == .function or left_tag == .promise) return abstractEqual(runtime, try valueToPrimitive(runtime, left, .number), right);
    if (right_tag == .byte_buffer or right_tag == .array or right_tag == .dictionary or right_tag == .iterator or right_tag == .function or right_tag == .promise) return abstractEqual(runtime, left, try valueToPrimitive(runtime, right, .number));
    if (left_tag == .number and isString(right)) return @as(f64, @bitCast(left.payload)) == try valueToNumberRuntime(runtime, right);
    if (isString(left) and right_tag == .number) return try valueToNumberRuntime(runtime, left) == @as(f64, @bitCast(right.payload));
    if (left_tag == .bigint and isString(right)) return bigIntEqualsString(runtime, left.object().?.payload.bigint, right);
    if (isString(left) and right_tag == .bigint) return bigIntEqualsString(runtime, right.object().?.payload.bigint, left);
    if (left_tag == .bigint and right_tag == .number) return bigIntEqualsNumber(runtime, left.object().?.payload.bigint, @bitCast(right.payload));
    if (left_tag == .number and right_tag == .bigint) return bigIntEqualsNumber(runtime, right.object().?.payload.bigint, @bitCast(left.payload));
    return false;
}

pub fn relationalOrder(runtime: *Runtime, left: Value, right: Value) !?std.math.Order {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try valueToPrimitive(runtime, roots[0], .number);
    roots[3] = try valueToPrimitive(runtime, roots[1], .number);
    const left_primitive = roots[2];
    const right_primitive = roots[3];
    if (isString(left_primitive) and isString(right_primitive)) return @as(?std.math.Order, try stringOrder(runtime, left_primitive, right_primitive));
    const left_tag: Tag = @enumFromInt(left_primitive.tag);
    const right_tag: Tag = @enumFromInt(right_primitive.tag);
    if (left_tag == .bigint and right_tag == .bigint) return @as(?std.math.Order, BigInt.order(left_primitive.object().?.payload.bigint, right_primitive.object().?.payload.bigint));
    if (left_tag == .bigint and isString(right_primitive)) return compareBigIntString(runtime, left_primitive.object().?.payload.bigint, right_primitive);
    if (isString(left_primitive) and right_tag == .bigint) {
        const order = (try compareBigIntString(runtime, right_primitive.object().?.payload.bigint, left_primitive)) orelse return null;
        return invertOrder(order);
    }
    if (left_tag == .bigint) return compareBigIntNumber(runtime, left_primitive.object().?.payload.bigint, try valueToNumberRuntime(runtime, right_primitive));
    if (right_tag == .bigint) {
        const order = (try compareBigIntNumber(runtime, right_primitive.object().?.payload.bigint, try valueToNumberRuntime(runtime, left_primitive))) orelse return null;
        return invertOrder(order);
    }
    const left_number = try valueToNumberRuntime(runtime, left_primitive);
    const right_number = try valueToNumberRuntime(runtime, right_primitive);
    if (std.math.isNan(left_number) or std.math.isNan(right_number)) return null;
    return std.math.order(left_number, right_number);
}

pub fn deepEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    // plugin_system_math uses JSON.stringify only when the left operand is an
    // object. Preserve that asymmetric dispatch and let the shared AOT JSON
    // serializer provide omission, NaN, byte-buffer, and cycle semantics.
    if (isJsonStringifyObject(left)) {
        var roots = [_]Value{ left, right, .{}, .{} };
        var frame = RootFrame{};
        runtime.pushRoots(&frame, &roots, roots.len);
        defer runtime.popRoots(&frame);
        roots[2] = try jsonEncodeBuiltin(runtime, roots[0], false);
        roots[3] = try jsonEncodeBuiltin(runtime, roots[1], false);
        return strictEqual(runtime, roots[2], roots[3]);
    }
    return strictEqual(runtime, left, right);
}

pub fn isJsonStringifyObject(value: Value) bool {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .null_value, .byte_buffer, .array, .dictionary, .iterator, .promise => true,
        else => false,
    };
}

pub fn compareValues(runtime: *Runtime, operator: Comparison, left: Value, right: Value) !bool {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    return switch (operator) {
        .abstract_equal => abstractEqual(runtime, roots[0], roots[1]),
        .strict_equal => strictEqual(runtime, roots[0], roots[1]),
        .abstract_not_equal => !try abstractEqual(runtime, roots[0], roots[1]),
        .strict_not_equal => !try strictEqual(runtime, roots[0], roots[1]),
        .deep_equal => deepEqual(runtime, roots[0], roots[1]),
        .deep_not_equal => !try deepEqual(runtime, roots[0], roots[1]),
        .less, .less_equal, .greater, .greater_equal => blk: {
            const order = (try relationalOrder(runtime, roots[0], roots[1])) orelse break :blk false;
            break :blk switch (operator) {
                .less => order == .lt,
                .less_equal => order != .gt,
                .greater => order == .gt,
                .greater_equal => order != .lt,
                else => unreachable,
            };
        },
    };
}

pub fn numberString(allocator: std.mem.Allocator, number: f64) ![]u8 {
    return number_mod.toStringAlloc(allocator, number);
}

pub fn concat(runtime: *Runtime, left: Value, right: Value) !Value {
    const left_units = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_units);
    const right_units = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_units);
    const combined = try runtime.allocator.alloc(u16, left_units.len + right_units.len);
    @memcpy(combined[0..left_units.len], left_units);
    @memcpy(combined[left_units.len..], right_units);
    return runtime.ownString(combined);
}

pub fn bigIntArithmetic(runtime: *Runtime, operator: Arithmetic, left: Value, right: Value) !Value {
    if (left.tag != @intFromEnum(Tag.bigint) or right.tag != @intFromEnum(Tag.bigint)) return error.CannotMixBigIntAndNumber;
    const left_bigint = left.object().?.payload.bigint;
    const right_bigint = right.object().?.payload.bigint;
    const result = switch (operator) {
        .add => try left_bigint.add(runtime.allocator, right_bigint),
        .subtract => try left_bigint.sub(runtime.allocator, right_bigint),
        .multiply => try left_bigint.mul(runtime.allocator, right_bigint),
        .divide => try left_bigint.divTrunc(runtime.allocator, right_bigint),
        .remainder => try left_bigint.rem(runtime.allocator, right_bigint),
        .power => blk: {
            if (right_bigint.isNegative()) return error.NegativeBigIntExponent;
            break :blk try left_bigint.pow(runtime.allocator, right_bigint.toU32() catch return error.BigIntExponentTooLarge);
        },
        .integer_divide => return error.CannotConvertBigIntToNumber,
        .bit_and => try left_bigint.bitAnd(runtime.allocator, right_bigint),
        .bit_or => try left_bigint.bitOr(runtime.allocator, right_bigint),
        .bit_xor => try left_bigint.bitXor(runtime.allocator, right_bigint),
    };
    return runtime.ownBigInt(result);
}

pub fn arithmetic(runtime: *Runtime, operator: Arithmetic, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const hint: AotPrimitiveHint = if (operator == .add) .string else .number;
    roots[2] = try valueToPrimitive(runtime, roots[0], hint);
    roots[3] = try valueToPrimitive(runtime, roots[1], hint);
    const left_primitive = roots[2];
    const right_primitive = roots[3];
    if (left_primitive.tag == @intFromEnum(Tag.bigint) or right_primitive.tag == @intFromEnum(Tag.bigint)) {
        return bigIntArithmetic(runtime, operator, left_primitive, right_primitive);
    }
    const left_number = if (operator == .add) try valueToParseFloatRuntime(runtime, left_primitive) else try valueToNumberRuntime(runtime, left_primitive);
    const right_number = if (operator == .add) try valueToParseFloatRuntime(runtime, right_primitive) else try valueToNumberRuntime(runtime, right_primitive);
    const result: f64 = switch (operator) {
        .add => left_number + right_number,
        .subtract => left_number - right_number,
        .multiply => left_number * right_number,
        .divide => left_number / right_number,
        .remainder => @rem(left_number, right_number),
        .power => std.math.pow(f64, left_number, right_number),
        .integer_divide => @floor(left_number / right_number),
        .bit_and => @floatFromInt(toInt32(left_number) & toInt32(right_number)),
        .bit_or => @floatFromInt(toInt32(left_number) | toInt32(right_number)),
        .bit_xor => @floatFromInt(toInt32(left_number) ^ toInt32(right_number)),
    };
    return numberValue(result);
}

pub fn bigIntEqualsString(runtime: *Runtime, bigint: BigInt, string: Value) !bool {
    var converted = bigIntFromString(runtime, string) catch return false;
    defer converted.deinit();
    return BigInt.eql(bigint, converted);
}

pub fn compareBigIntString(runtime: *Runtime, bigint: BigInt, string: Value) !?std.math.Order {
    var converted = bigIntFromString(runtime, string) catch return null;
    defer converted.deinit();
    return BigInt.order(bigint, converted);
}

pub fn bigIntFromString(runtime: *Runtime, string: Value) !BigInt {
    const units = try valueUtf16Alloc(runtime, string);
    defer runtime.allocator.free(units);
    const trimmed = string_mod.trimWhitespace(units);
    const ascii = try runtime.allocator.alloc(u8, trimmed.len);
    defer runtime.allocator.free(ascii);
    for (trimmed, 0..) |unit, index| {
        if (unit > 0x7f) return error.InvalidBigInt;
        ascii[index] = @intCast(unit);
    }
    return BigInt.parseString(runtime.allocator, ascii);
}

pub fn shift(runtime: *Runtime, operator: ShiftOperator, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try valueToPrimitive(runtime, roots[0], .number);
    roots[3] = try valueToPrimitive(runtime, roots[1], .number);
    const left_primitive = roots[2];
    const right_primitive = roots[3];
    const left_is_bigint = left_primitive.tag == @intFromEnum(Tag.bigint);
    const right_is_bigint = right_primitive.tag == @intFromEnum(Tag.bigint);
    if (left_is_bigint or right_is_bigint) {
        if (!left_is_bigint or !right_is_bigint) return error.CannotMixBigIntAndNumber;
        if (operator == .right_unsigned) return error.UnsignedShiftOfBigInt;
        const left_bigint = left_primitive.object().?.payload.bigint;
        const amount = right_primitive.object().?.payload.bigint.toI64() catch return error.BigIntShiftTooLarge;
        const magnitude = if (amount < 0) @as(u64, @intCast(-(amount + 1))) + 1 else @as(u64, @intCast(amount));
        const shift_amount: usize = std.math.cast(usize, magnitude) orelse return error.BigIntShiftTooLarge;
        const shift_left = (operator == .left) != (amount < 0);
        const result = if (shift_left)
            try left_bigint.shiftLeft(runtime.allocator, shift_amount)
        else
            try left_bigint.shiftRight(runtime.allocator, shift_amount);
        return runtime.ownBigInt(result);
    }
    const amount: u5 = @truncate(toUint32(try valueToNumberRuntime(runtime, right_primitive)) & 31);
    const left_number = try valueToNumberRuntime(runtime, left_primitive);
    const shifted: f64 = switch (operator) {
        .left => @floatFromInt(toInt32(left_number) << amount),
        .right => @floatFromInt(toInt32(left_number) >> amount),
        .right_unsigned => @floatFromInt(toUint32(left_number) >> amount),
    };
    return numberValue(shifted);
}

pub fn bitNot(runtime: *Runtime, value: Value) !Value {
    var roots = [_]Value{ value, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try valueToPrimitive(runtime, roots[0], .number);
    const primitive = roots[1];
    if (primitive.tag == @intFromEnum(Tag.bigint)) {
        const result = try primitive.object().?.payload.bigint.bitNot(runtime.allocator);
        return runtime.ownBigInt(result);
    }
    return numberValue(@floatFromInt(~toInt32(try valueToNumberRuntime(runtime, primitive))));
}

pub fn valueTruthy(value: Value) bool {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined, .null_value => false,
        .boolean => value.payload != 0,
        .number => blk: {
            const number: f64 = @bitCast(value.payload);
            break :blk number != 0 and !std.math.isNan(number);
        },
        .static_utf8_string => staticUtf8(value).len != 0,
        .utf16_string => value.object().?.payload.utf16_string.len != 0,
        .bigint => !value.object().?.payload.bigint.isZero(),
        .byte_buffer, .array, .dictionary, .iterator, .function, .promise => true,
        .binding_cell => valueTruthy(value.object().?.payload.binding_cell),
    };
}

pub fn toInt32(number: f64) i32 {
    if (!std.math.isFinite(number) or number == 0) return 0;
    var value = @mod(@trunc(number), 4294967296.0);
    if (value < 0) value += 4294967296.0;
    if (value >= 2147483648.0) value -= 4294967296.0;
    return @intFromFloat(value);
}

pub fn toUint32(number: f64) u32 {
    if (!std.math.isFinite(number) or number == 0) return 0;
    var value = @mod(@trunc(number), 4294967296.0);
    if (value < 0) value += 4294967296.0;
    return @intFromFloat(value);
}

pub fn bigIntEqualsNumber(runtime: *Runtime, bigint: BigInt, number: f64) !bool {
    if (!std.math.isFinite(number) or @trunc(number) != number) return false;
    var converted = try BigInt.fromF64(runtime.allocator, number);
    defer converted.deinit();
    return BigInt.eql(bigint, converted);
}

pub fn compareBigIntNumber(runtime: *Runtime, bigint: BigInt, number: f64) !?std.math.Order {
    if (std.math.isNan(number)) return null;
    if (number == std.math.inf(f64)) return .lt;
    if (number == -std.math.inf(f64)) return .gt;
    var integer = try BigInt.fromF64(runtime.allocator, @trunc(number));
    defer integer.deinit();
    const integer_order = BigInt.order(bigint, integer);
    if (integer_order != .eq) return integer_order;
    const fraction = number - @trunc(number);
    if (fraction > 0) return .lt;
    if (fraction < 0) return .gt;
    return .eq;
}

pub fn invertOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

pub fn repeatCount(number: f64) !usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.IteratorCountTooLarge;
    return @intFromFloat(@trunc(number));
}

pub fn sameKey(left: Value, right: Value) bool {
    const left_tag: Tag = @enumFromInt(left.tag);
    const right_tag: Tag = @enumFromInt(right.tag);
    if ((left_tag == .static_utf8_string or left_tag == .utf16_string) and
        (right_tag == .static_utf8_string or right_tag == .utf16_string))
    {
        if (left_tag == .static_utf8_string and right_tag == .static_utf8_string) return std.mem.eql(u8, staticUtf8(left), staticUtf8(right));
        if (left_tag == .static_utf8_string) return staticUtf8EqualsUtf16(staticUtf8(left), right.object().?.payload.utf16_string);
        if (right_tag == .static_utf8_string) return staticUtf8EqualsUtf16(staticUtf8(right), left.object().?.payload.utf16_string);
        return std.mem.eql(u16, left.object().?.payload.utf16_string, right.object().?.payload.utf16_string);
    }
    if (left.tag != right.tag) return false;
    return switch (@as(Tag, @enumFromInt(left.tag))) {
        .undefined, .null_value => true,
        .boolean, .number => left.payload == right.payload,
        .static_utf8_string => std.mem.eql(u8, staticUtf8(left), staticUtf8(right)),
        .utf16_string => std.mem.eql(u16, left.object().?.payload.utf16_string, right.object().?.payload.utf16_string),
        .bigint => BigInt.eql(left.object().?.payload.bigint, right.object().?.payload.bigint),
        .byte_buffer => left.payload == right.payload,
        .array, .dictionary, .iterator, .function, .promise => left.payload == right.payload,
        .binding_cell => unreachable,
    };
}

pub fn staticUtf8EqualsUtf16(text: []const u8, units: []const u16) bool {
    var text_index: usize = 0;
    var unit_index: usize = 0;
    while (text_index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[text_index]) catch return false;
        if (text_index + length > text.len) return false;
        const codepoint = std.unicode.utf8Decode(text[text_index .. text_index + length]) catch return false;
        text_index += length;
        if (codepoint <= 0xffff) {
            if (unit_index >= units.len or units[unit_index] != @as(u16, @intCast(codepoint))) return false;
            unit_index += 1;
        } else {
            if (unit_index + 1 >= units.len) return false;
            const offset = codepoint - 0x10000;
            if (units[unit_index] != @as(u16, @intCast(0xd800 + (offset >> 10))) or
                units[unit_index + 1] != @as(u16, @intCast(0xdc00 + (offset & 0x3ff)))) return false;
            unit_index += 2;
        }
    }
    return unit_index == units.len;
}

pub fn staticUtf8(value: Value) []const u8 {
    const pointer: [*:0]const u8 = @ptrFromInt(value.payload);
    return std.mem.span(pointer);
}

pub extern "c" fn putchar(character: c_int) c_int;

pub fn writeUtf16(units: []const u16, newline: bool) void {
    var index: usize = 0;
    while (index < units.len) {
        const first = units[index];
        var codepoint: u21 = undefined;
        if (first >= 0xd800 and first <= 0xdbff and index + 1 < units.len and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) {
            const second = units[index + 1];
            codepoint = @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
            index += 2;
        } else {
            codepoint = if (first >= 0xd800 and first <= 0xdfff) 0xfffd else @intCast(first);
            index += 1;
        }
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch unreachable;
        for (encoded[0..length]) |byte| _ = putchar(byte);
    }
    if (newline) _ = putchar('\n');
}

pub fn valueUtf8LossyAlloc(runtime: *Runtime, value: Value) ![]u8 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return utf16UnitsToUtf8LossyAlloc(runtime.allocator, units);
}

pub fn utf16UnitsToUtf8LossyAlloc(allocator: std.mem.Allocator, units: []const u16) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < units.len) {
        const first = units[index];
        var codepoint: u21 = undefined;
        if (first >= 0xd800 and first <= 0xdbff and index + 1 < units.len and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) {
            const second = units[index + 1];
            codepoint = @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
            index += 2;
        } else {
            codepoint = if (first >= 0xd800 and first <= 0xdfff) 0xfffd else @intCast(first);
            index += 1;
        }
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch return error.InvalidUnicodeScalar;
        try output.appendSlice(allocator, encoded[0..length]);
    }
    return output.toOwnedSlice(allocator);
}

pub fn appendDisplayLog(runtime: *Runtime, display_log: ?*Value, line: []const u8) !void {
    const pointer = display_log orelse return;
    const current = try valueUtf8LossyAlloc(runtime, pointer.*);
    defer runtime.allocator.free(current);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);
    try output.appendSlice(runtime.allocator, current);
    try output.appendSlice(runtime.allocator, line);
    try output.append(runtime.allocator, '\n');
    pointer.* = try runtimeUtf8String(runtime, output.items);
}

pub fn emitDisplayLine(runtime: *Runtime, text: []const u8, newline: bool, display_log: ?*Value) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);
    try output.appendSlice(runtime.allocator, runtime.print_pool.items);
    try output.appendSlice(runtime.allocator, text);
    runtime.print_pool.clearRetainingCapacity();
    writeBytes(output.items, newline);
    if (newline) try appendDisplayLog(runtime, display_log, output.items);
}

pub fn displayValue(runtime: *Runtime, value: Value, newline: bool, display_log: ?*Value) !void {
    const text = try valueUtf8LossyAlloc(runtime, value);
    defer runtime.allocator.free(text);
    try emitDisplayLine(runtime, text, newline, display_log);
}

pub fn continueDisplayValue(runtime: *Runtime, value: Value) !void {
    const text = try valueUtf8LossyAlloc(runtime, value);
    defer runtime.allocator.free(text);
    try runtime.print_pool.appendSlice(runtime.allocator, text);
}

pub fn joinValuesUtf8Alloc(runtime: *Runtime, values: []const Value) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(runtime.allocator);
    for (values) |value| {
        const text = try valueUtf8LossyAlloc(runtime, value);
        defer runtime.allocator.free(text);
        try output.appendSlice(runtime.allocator, text);
    }
    return output.toOwnedSlice(runtime.allocator);
}

pub fn displayMany(runtime: *Runtime, values: []const Value, display_log: ?*Value) !void {
    const text = try joinValuesUtf8Alloc(runtime, values);
    defer runtime.allocator.free(text);
    try emitDisplayLine(runtime, text, true, display_log);
}

pub fn configureHatenaBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    runtime.hatena_callbacks.clearRetainingCapacity();
    if (arguments.len == 0) return .{};

    var setting = arguments[arguments.len - 1];
    var frame = RootFrame{};
    runtime.pushRoots(&frame, @ptrCast(&setting), 1);
    defer runtime.popRoots(&frame);

    switch (@as(Tag, @enumFromInt(setting.tag))) {
        .function, .static_utf8_string, .utf16_string => try runtime.hatena_callbacks.append(runtime.allocator, setting),
        .array => {
            const items = try arrayItems(setting);
            for (items.items) |item| {
                if (!isString(item)) return error.InvalidHatenaCallback;
                const name = try stringUtf8Alloc(runtime, item);
                defer runtime.allocator.free(name);
                if (std.mem.startsWith(u8, name, "JS:")) return error.JavaScriptCompatibilityRequired;
                try runtime.hatena_callbacks.append(runtime.allocator, item);
            }
        },
        else => {},
    }
    return .{};
}

pub fn configureInterruptBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len == 0) return error.InvalidArgumentCount;

    var callback = arguments[0];
    var frame = RootFrame{};
    runtime.pushRoots(&frame, @ptrCast(&callback), 1);
    defer runtime.popRoots(&frame);
    callback = try resolveAotCallback(runtime, callback);
    runtime.interrupt_callback = callback;
    try installAotInterrupt();
    return .{};
}

pub fn invokeHatenaNamedCallback(
    runtime: *Runtime,
    name_value: Value,
    parameter: Value,
    line: u64,
    source_path: []const u8,
    display_log: ?*Value,
) !Value {
    const name = try stringUtf8Alloc(runtime, name_value);
    defer runtime.allocator.free(name);
    if (std.mem.eql(u8, name, "表示") or std.mem.eql(u8, name, "表示する")) {
        try displayValue(runtime, parameter, true, display_log);
        return .{};
    }
    if (std.mem.eql(u8, name, "連続表示")) {
        try displayMany(runtime, &.{parameter}, display_log);
        return .{};
    }
    const command = aot_builtin.lookup(name) orelse return error.UnknownFunction;
    if (command == .system_debug_display) {
        try debugDisplayBuiltin(runtime, parameter, line, source_path, display_log);
        return .{};
    }
    var argument = parameter;
    var result = Value{};
    const start_epoch = runtime.failure_epoch;
    lnako_aot_builtin_call_site(&result, @ptrCast(&argument), 1, @intFromEnum(command), 0);
    if (runtime.has_pending_exception and runtime.failure_epoch != start_epoch) return error.CallbackExecutionFailed;
    return result;
}

pub fn invokeHatenaCallbacks(
    runtime: *Runtime,
    parameter: Value,
    line: u64,
    source_path: []const u8,
    display_log: ?*Value,
) !Value {
    var roots = [_]Value{ parameter, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    for (runtime.hatena_callbacks.items) |callback| {
        roots[1] = if (callback.tag == @intFromEnum(Tag.function))
            try invokeAotCallback(runtime, callback, @ptrCast(&roots[0]), 1)
        else if (isString(callback))
            try invokeHatenaNamedCallback(runtime, callback, roots[0], line, source_path, display_log)
        else
            return error.InvalidHatenaCallback;
        roots[0] = roots[1];
    }
    return roots[0];
}

pub fn writeAllValues(runtime: *Runtime, values: []const Value) !void {
    for (values) |value| {
        const text = try valueUtf8LossyAlloc(runtime, value);
        defer runtime.allocator.free(text);
        writeBytes(text, false);
    }
    writeBytes("", true);
}

pub fn isStdioCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .stdio_continue_display, .stdio_continue_display_many, .stdio_clear_log, .stdio_write_all => true,
        else => false,
    };
}

pub fn isHttpServerCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .http_server_start, .http_server_static, .http_server_receive, .http_server_output, .http_server_headers, .http_server_redirect => true,
        else => false,
    };
}

pub fn isNodeProcessCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_process_run_wait, .node_process_run, .node_process_start, .node_process_run_wait_output, .node_process_start_callback, .node_open_external_browser, .node_open_external_explorer => true,
        else => false,
    };
}

pub fn isNodeHttpCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_ajax_send_callback, .node_ajax_receive_callback, .node_get_send_callback, .node_post_send_callback, .node_post_form_send_callback, .node_ajax_response_promise, .node_http_response_promise, .node_get_response_promise, .node_post_response_promise, .node_post_form_response_promise, .node_ajax_content_get, .node_ajax_receive, .node_post_send, .node_post_form_send, .node_ajax_text_get, .node_ajax_json_get, .node_ajax_binary_get, .node_discord_send, .node_discord_file_send => true,
        else => false,
    };
}

pub fn runAotExternal(runtime: *Runtime, target: []const u8, reveal: bool) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => if (reveal) &.{ "/usr/bin/open", "-R", target } else &.{ "/usr/bin/open", target },
        .windows => if (reveal)
            &.{ "explorer.exe", "/select,", target }
        else
            &.{ "cmd.exe", "/d", "/s", "/c", "start", "", target },
        else => if (reveal)
            &.{ "xdg-open", std.fs.path.dirname(target) orelse "." }
        else
            &.{ "xdg-open", target },
    };
    // Keep platform-specific argv construction on the production path, then
    // stop only the final process launch in the hermetic fixture environment.
    // This mirrors the CLI host and avoids starting a desktop application in
    // CI while preserving the official non-Windows Explorer result.
    if (std.c.getenv("LNAKO_TEST_OPEN_EXTERNAL") != null) {
        if (reveal and builtin.os.tag != .windows) return error.OpenExternalFailed;
        return;
    }
    const result = try std.process.run(runtime.allocator, runtime.process_io.io(), .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    runtime.allocator.free(result.stdout);
    runtime.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.OpenExternalFailed;
}

pub fn nodeProcessBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    switch (command) {
        .node_open_external_browser, .node_open_external_explorer => {
            if (arguments.len < 1) return error.InvalidArgumentCount;
            const target = try valueUtf8LossyAlloc(runtime, arguments[0]);
            defer runtime.allocator.free(target);
            try runAotExternal(runtime, target, command == .node_open_external_explorer);
            return .{};
        },
        .node_process_run_wait, .node_process_run, .node_process_start, .node_process_run_wait_output => {
            if (arguments.len < 1) return error.InvalidArgumentCount;
            const command_text = try valueUtf8LossyAlloc(runtime, arguments[0]);
            defer runtime.allocator.free(command_text);
            if (command == .node_process_run_wait) {
                const cwd = try currentDirectoryAlloc(runtime);
                defer runtime.allocator.free(cwd);
                var result = try runAotShellCommand(runtime, command_text, cwd);
                defer result.deinit(runtime.allocator);
                if (result.exit_code != 0) return error.CommandFailed;
                return runtimeUtf8StringLossy(runtime, result.stdout);
            }
            if (command == .node_process_run_wait_output) {
                const cwd = try currentDirectoryAlloc(runtime);
                defer runtime.allocator.free(cwd);
                var result = try runAotShellCommand(runtime, command_text, cwd);
                defer result.deinit(runtime.allocator);
                writeBytes(result.stdout, false);
                writeAotStderr(result.stderr);
                return numberValue(@floatFromInt(result.exit_code));
            }
            const mode = AotProcessMode.command_output;
            try queueAotProcess(runtime, command_text, mode, .{});
            return .{};
        },
        .node_process_start_callback => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            var roots = [_]Value{arguments[0]};
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            roots[0] = try resolveAotCallback(runtime, roots[0]);
            const command_text = try valueUtf8LossyAlloc(runtime, arguments[1]);
            defer runtime.allocator.free(command_text);
            try queueAotProcess(runtime, command_text, .output_callback, roots[0]);
            return .{};
        },
        else => return error.UnknownCommand,
    }
}

pub fn isArchiveCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_archive_extract, .node_archive_extract_callback, .node_archive_create, .node_archive_create_callback => true,
        else => false,
    };
}

pub fn isPluginManagementCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .plugin_name_set, .namespace_set, .namespace_pop => true,
        else => false,
    };
}

pub fn stdioBuiltin(runtime: *Runtime, command: aot_builtin.Command, values: []const Value, display_log: ?*Value) !void {
    switch (command) {
        .stdio_continue_display => try continueDisplayValue(runtime, if (values.len > 0) values[values.len - 1] else .{}),
        .stdio_continue_display_many => {
            const text = try joinValuesUtf8Alloc(runtime, values);
            defer runtime.allocator.free(text);
            try runtime.print_pool.appendSlice(runtime.allocator, text);
        },
        .stdio_clear_log => {
            if (display_log) |pointer| pointer.* = try runtimeUtf8String(runtime, "");
        },
        .stdio_write_all => try writeAllValues(runtime, values),
        else => return error.UnknownCommand,
    }
}

pub fn pluginManagementArgument(runtime: *Runtime, values: []const Value) !Value {
    var source = if (values.len > 0) values[values.len - 1] else Value{};
    var frame = RootFrame{};
    runtime.pushRoots(&frame, @ptrCast(&source), 1);
    defer runtime.popRoots(&frame);
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

pub fn pluginManagementBuiltin(
    runtime: *Runtime,
    command: aot_builtin.Command,
    values: []const Value,
    plugin_name: *Value,
    namespace: *Value,
) !void {
    switch (command) {
        .plugin_name_set => plugin_name.* = try pluginManagementArgument(runtime, values),
        .namespace_set => {
            var converted = try pluginManagementArgument(runtime, values);
            var frame = RootFrame{};
            runtime.pushRoots(&frame, @ptrCast(&converted), 1);
            defer runtime.popRoots(&frame);
            try runtime.namespace_stack.append(runtime.allocator, .{
                .namespace = namespace.*,
                .plugin_name = plugin_name.*,
            });
            namespace.* = converted;
        },
        .namespace_pop => if (runtime.namespace_stack.pop()) |previous| {
            namespace.* = previous.namespace;
            plugin_name.* = previous.plugin_name;
        },
        else => return error.UnknownCommand,
    }
}

pub fn aotDelayMilliseconds(runtime: *Runtime, value: Value) !u64 {
    const seconds = try valueToNumberRuntime(runtime, value);
    if (!std.math.isFinite(seconds) or seconds <= 0) return 0;
    const milliseconds = @floor(seconds * 1000.0);
    if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.TimerOverflow;
    return @intFromFloat(milliseconds);
}

pub fn sleepAotUntil(runtime: *Runtime, target: u64) !void {
    if (target <= runtime.elapsed_milliseconds) return;
    const delay = target - runtime.elapsed_milliseconds;
    if (delay > @as(u64, std.math.maxInt(i64))) return error.TimerOverflow;
    while (runtime.elapsed_milliseconds < target) {
        try pollAotInterrupt(runtime);
        try drainAotProcessTasks(runtime);
        try drainAotFileTasks(runtime);
        const remaining = target - runtime.elapsed_milliseconds;
        const slice = @min(remaining, @as(u64, 20));
        try std.Io.sleep(
            std.Io.Threaded.global_single_threaded.io(),
            std.Io.Duration.fromMilliseconds(@intCast(slice)),
            .awake,
        );
        runtime.elapsed_milliseconds += slice;
        try pollAotInterrupt(runtime);
        try drainAotProcessTasks(runtime);
        try drainAotFileTasks(runtime);
    }
}

pub fn runAotShellCommand(runtime: *Runtime, command: []const u8, cwd: []const u8) !AotCommandResult {
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/d", "/s", "/c", command }
    else
        &.{ "/bin/sh", "-c", command };
    const result = try std.process.run(runtime.allocator, runtime.process_io.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => 1,
        },
    };
}

pub fn aotRuntimeIo(runtime: *Runtime) std.Io {
    return if (runtime.process_io_initialized) runtime.process_io.io() else std.Io.Threaded.global_single_threaded.io();
}

pub fn queueAotProcess(runtime: *Runtime, command: []const u8, mode: AotProcessMode, callback: Value) !void {
    const allocator = runtime.allocator;
    const task = try allocator.create(AotProcessTask);
    const owned_command = allocator.dupe(u8, command) catch |failure| {
        allocator.destroy(task);
        return failure;
    };
    const owned_cwd = currentDirectoryAlloc(runtime) catch |failure| {
        allocator.free(owned_command);
        allocator.destroy(task);
        return failure;
    };
    task.* = .{
        .runtime = runtime,
        .command = owned_command,
        .cwd = owned_cwd,
        .mode = mode,
        .callback = callback,
    };
    runtime.process_tasks.append(allocator, task) catch |failure| {
        task.deinit(allocator, false);
        return failure;
    };
    task.thread = std.Thread.spawn(.{}, AotProcessTask.run, .{task}) catch |failure| {
        _ = runtime.process_tasks.pop();
        task.deinit(allocator, false);
        return failure;
    };
}

pub fn queueAotFileTask(runtime: *Runtime, operation: AotFileTaskOperation, source: []const u8, destination: []const u8, overwrite: bool, callback: Value) !void {
    const allocator = runtime.allocator;
    const task = try allocator.create(AotFileTask);
    const owned_source = allocator.dupe(u8, source) catch |failure| {
        allocator.destroy(task);
        return failure;
    };
    const owned_destination = allocator.dupe(u8, destination) catch |failure| {
        allocator.free(owned_source);
        allocator.destroy(task);
        return failure;
    };
    task.* = .{
        .runtime = runtime,
        .operation = operation,
        .source = owned_source,
        .destination = owned_destination,
        .overwrite = overwrite,
        .callback = callback,
    };
    runtime.file_tasks.append(allocator, task) catch |failure| {
        task.deinit(allocator, false);
        return failure;
    };
    task.thread = std.Thread.spawn(.{}, AotFileTask.run, .{task}) catch |failure| {
        _ = runtime.file_tasks.pop();
        task.deinit(allocator, false);
        return failure;
    };
}

pub fn readyAotProcessTaskIndex(runtime: *const Runtime) ?usize {
    var selected: ?usize = null;
    for (runtime.process_tasks.items, 0..) |task, index| {
        if (!task.complete.load(.acquire)) continue;
        if (selected == null or task.completion_order < runtime.process_tasks.items[selected.?].completion_order) selected = index;
    }
    return selected;
}

pub fn readyAotFileTaskIndex(runtime: *const Runtime) ?usize {
    var selected: ?usize = null;
    for (runtime.file_tasks.items, 0..) |task, index| {
        if (!task.complete.load(.acquire)) continue;
        if (selected == null or task.completion_order < runtime.file_tasks.items[selected.?].completion_order) selected = index;
    }
    return selected;
}

pub fn writeAotStderr(bytes: []const u8) void {
    if (bytes.len > 0) std.debug.print("{s}", .{bytes});
}

pub fn writeAotAjaxReceiveError(status: u16, failure: ?anyerror) void {
    if (failure) |err| {
        std.debug.print("[AJAX受信のエラー] Error: {s}\n", .{error_message.forFailure(err)});
    } else {
        std.debug.print("[AJAX受信のエラー] Error: status={d}\n", .{status});
    }
}

pub fn drainAotProcessTasks(runtime: *Runtime) !void {
    while (readyAotProcessTaskIndex(runtime)) |index| {
        try countAotEvent(runtime);
        const task = runtime.process_tasks.orderedRemove(index);
        defer task.deinit(runtime.allocator, true);
        if (task.failure) |failure| return failure;
        const result = &(task.result orelse return error.AsyncCommandMissingResult);
        switch (task.mode) {
            .command_output => if (result.exit_code == 0) {
                if (result.stdout.len > 0) writeBytes(result.stdout, true);
            } else writeAotStderr(result.stderr),
            .output_callback => {
                if (result.exit_code != 0) return error.CommandFailed;
                var rooted = [_]Value{ task.callback, .{} };
                var roots = RootFrame{};
                runtime.pushRoots(&roots, &rooted, rooted.len);
                defer runtime.popRoots(&roots);
                rooted[1] = try runtimeUtf8StringLossy(runtime, result.stdout);
                _ = try invokeAotCallback(runtime, rooted[0], @ptrCast(&rooted[1]), 1);
            },
        }
    }
}

pub fn drainAotFileTasks(runtime: *Runtime) !void {
    while (readyAotFileTaskIndex(runtime)) |index| {
        try countAotEvent(runtime);
        const task = runtime.file_tasks.orderedRemove(index);
        defer task.deinit(runtime.allocator, true);
        if (task.failure != null) return error.FileOperationFailed;
        var callback = task.callback;
        var frame = RootFrame{};
        runtime.pushRoots(&frame, @ptrCast(&callback), 1);
        defer runtime.popRoots(&frame);
        _ = try invokeAotCallback(runtime, callback, null, 0);
    }
}

pub fn earliestAotTimerIndex(runtime: *const Runtime) ?usize {
    if (runtime.timers.items.len == 0) return null;
    var earliest: usize = 0;
    for (runtime.timers.items[1..], 1..) |timer, index| {
        if (timer.due_milliseconds < runtime.timers.items[earliest].due_milliseconds) earliest = index;
    }
    return earliest;
}

pub fn countAotEvent(runtime: *Runtime) !void {
    if (runtime.timer_event_count >= aot_timer_event_limit) return error.EventLoopLimitExceeded;
    runtime.timer_event_count += 1;
}

pub fn executeAotTimer(runtime: *Runtime, index: usize) !void {
    try countAotEvent(runtime);
    const timer = runtime.timers.orderedRemove(index);
    var callback = timer.callback;
    var root = RootFrame{};
    runtime.pushRoots(&root, @ptrCast(&callback), 1);
    defer runtime.popRoots(&root);
    try sleepAotUntil(runtime, timer.due_milliseconds);
    if (timer.repeating) {
        const next_due = std.math.add(u64, runtime.elapsed_milliseconds, timer.interval_milliseconds) catch return error.TimerOverflow;
        try runtime.timers.append(runtime.allocator, .{
            .id = timer.id,
            .due_milliseconds = next_due,
            .interval_milliseconds = timer.interval_milliseconds,
            .repeating = true,
            .callback = callback,
        });
    }
    var id = numberValue(@floatFromInt(timer.id));
    _ = try invokeAotCallback(runtime, callback, @ptrCast(&id), 1);
}

pub fn aotArchiveExecute(
    runtime: *Runtime,
    operation: AotArchiveOperation,
    use_external_tool: bool,
    source: []const u8,
    destination: []const u8,
    tool_path: []const u8,
) ![]u8 {
    const allocator = runtime.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    if (!use_external_tool) {
        switch (operation) {
            .create => try zip_archive.create(allocator, io, source, destination),
            .extract => try zip_archive.extract(io, source, destination),
        }
        return allocator.alloc(u8, 0);
    }
    // This is an explicit test-only adapter for the hermetic archive fixture.
    // It preserves the changed tool-path state and AOT callback/event route,
    // while normal AOT executions continue to launch the configured tool.
    if (std.c.getenv("LNAKO_TEST_ARCHIVE_HELPER")) |helper| {
        if (std.mem.eql(u8, std.mem.span(helper), tool_path)) {
            switch (operation) {
                .create => try zip_archive.create(allocator, io, source, destination),
                .extract => try zip_archive.extract(io, source, destination),
            }
            return allocator.alloc(u8, 0);
        }
    }

    var output_option: ?[]u8 = null;
    defer if (output_option) |option| allocator.free(option);
    var argv_storage: [6][]const u8 = undefined;
    const argv: []const []const u8 = switch (operation) {
        .create => blk: {
            argv_storage = .{ tool_path, "a", "-r", destination, source, "-y" };
            break :blk argv_storage[0..6];
        },
        .extract => blk: {
            output_option = try std.fmt.allocPrint(allocator, "-o{s}", .{destination});
            argv_storage = .{ tool_path, "x", source, output_option.?, "-y", undefined };
            break :blk argv_storage[0..5];
        },
    };
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
    allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.ArchiveToolFailed;
    }
    return result.stdout;
}

pub fn drainAotArchiveTasks(runtime: *Runtime) !void {
    while (runtime.archive_tasks.items.len > 0) {
        try countAotEvent(runtime);
        var task = runtime.archive_tasks.orderedRemove(0);
        defer task.deinit(runtime.allocator);
        var callback = task.callback;
        var callback_frame = RootFrame{};
        runtime.pushRoots(&callback_frame, @ptrCast(&callback), 1);
        defer runtime.popRoots(&callback_frame);
        const output = try aotArchiveExecute(runtime, task.operation, task.use_external_tool, task.source, task.destination, task.tool_path);
        defer runtime.allocator.free(output);
        var result = try runtimeUtf8StringLossy(runtime, output);
        var result_frame = RootFrame{};
        runtime.pushRoots(&result_frame, @ptrCast(&result), 1);
        defer runtime.popRoots(&result_frame);
        _ = try invokeAotCallback(runtime, callback, @ptrCast(&result), 1);
    }
}

pub fn drainAotPromiseTasks(runtime: *Runtime) !void {
    while (runtime.promise_tasks.items.len > 0) {
        try countAotEvent(runtime);
        const task = runtime.promise_tasks.orderedRemove(0);
        try executeAotPromiseTask(runtime, task);
    }
}

pub fn drainAotNativePluginTasks(runtime: *Runtime) !bool {
    const state = runtime.dynamic_state orelse return false;
    const native_pending = try state.interpreter.pollExternalPlugins();
    var pending_bridge = false;
    var index: usize = 0;
    while (index < runtime.dynamic_promise_bridges.items.len) {
        const bridge = runtime.dynamic_promise_bridges.items[index];
        if (bridge.state != state or bridge.promise.state == .pending) {
            pending_bridge = pending_bridge or bridge.state == state;
            index += 1;
            continue;
        }

        var rooted = [_]Value{ bridge.aot_promise, .{} };
        var frame = RootFrame{};
        runtime.pushRoots(&frame, &rooted, rooted.len);
        defer runtime.popRoots(&frame);
        rooted[1] = try dynamicToAotValue(state, bridge.promise.result);
        if (bridge.promise.state == .fulfilled) {
            try resolveAotPromise(runtime, rooted[0].object().?, rooted[1]);
        } else {
            try rejectAotPromise(runtime, rooted[0].object().?, rooted[1]);
        }
        _ = runtime.dynamic_promise_bridges.orderedRemove(index);
        runtime.allocator.destroy(bridge);
    }
    return native_pending or pending_bridge;
}

pub fn drainAotClientHttpTasks(runtime: *Runtime) !void {
    while (runtime.client_http_tasks.items.len > 0) {
        try countAotEvent(runtime);
        var task = runtime.client_http_tasks.orderedRemove(0);
        defer task.deinit(runtime.allocator);

        if (task.result.failure) |failure| {
            switch (task.mode) {
                .callback => {
                    const handler: Value = if (task.onerror) |pointer| pointer.* else .{};
                    if (handler.tag == @intFromEnum(Tag.function)) {
                        var rooted = [_]Value{ handler, .{} };
                        var frame = RootFrame{};
                        runtime.pushRoots(&frame, &rooted, rooted.len);
                        defer runtime.popRoots(&frame);
                        rooted[1] = try runtimeUtf8StringLossy(runtime, @errorName(failure));
                        _ = try invokeAotCallback(runtime, rooted[0], @ptrCast(&rooted[1]), 1);
                    } else return error.HttpRequestFailed;
                },
                .set_target => writeAotAjaxReceiveError(task.result.status, failure),
                .response_promise => {
                    if (task.promise.tag != @intFromEnum(Tag.promise)) return error.InvalidPendingPromise;
                    var reason = try runtimeUtf8StringLossy(runtime, @errorName(failure));
                    var frame = RootFrame{};
                    runtime.pushRoots(&frame, @ptrCast(&reason), 1);
                    defer runtime.popRoots(&frame);
                    try rejectAotPromise(runtime, task.promise.object().?, reason);
                },
            }
            continue;
        }

        switch (task.mode) {
            .callback => {
                var rooted = [_]Value{ task.callback, .{} };
                var frame = RootFrame{};
                runtime.pushRoots(&frame, &rooted, rooted.len);
                defer runtime.popRoots(&frame);
                rooted[1] = try runtimeUtf8StringLossy(runtime, task.result.body);
                if (task.target) |target| target.* = rooted[1];
                _ = try invokeAotCallback(runtime, rooted[0], @ptrCast(&rooted[1]), 1);
            },
            .set_target => {
                const status = task.result.status;
                if (status >= 200 and status < 300) {
                    if (task.target) |target| target.* = try runtimeUtf8StringLossy(runtime, task.result.body);
                } else writeAotAjaxReceiveError(status, null);
            },
            .response_promise => {
                if (task.promise.tag != @intFromEnum(Tag.promise)) return error.InvalidPendingPromise;
                var rooted = [_]Value{ task.promise, .{} };
                var frame = RootFrame{};
                runtime.pushRoots(&frame, &rooted, rooted.len);
                defer runtime.popRoots(&frame);
                rooted[1] = try aotClientHttpResponseValue(runtime, task.result);
                try resolveAotPromise(runtime, rooted[0].object().?, rooted[1]);
            },
        }
    }
}

pub fn drainAotEvents(runtime: *Runtime) !void {
    while (true) {
        try drainAotProcessTasks(runtime);
        try drainAotFileTasks(runtime);
        try drainAotClientHttpTasks(runtime);
        try drainAotArchiveTasks(runtime);
        const native_plugins_pending = try drainAotNativePluginTasks(runtime);
        try drainAotPromiseTasks(runtime);
        if (earliestAotTimerIndex(runtime)) |index| {
            try executeAotTimer(runtime, index);
            continue;
        }
        if (runtime.process_tasks.items.len > 0 or runtime.file_tasks.items.len > 0 or runtime.client_http_tasks.items.len > 0 or native_plugins_pending) {
            try std.Io.sleep(
                std.Io.Threaded.global_single_threaded.io(),
                std.Io.Duration.fromMilliseconds(1),
                .awake,
            );
            runtime.elapsed_milliseconds += 1;
            continue;
        }
        break;
    }
}

pub fn drainAotTimers(runtime: *Runtime) !void {
    try drainAotEvents(runtime);
}

pub fn waitAotMilliseconds(runtime: *Runtime, milliseconds: u64) !void {
    const target = std.math.add(u64, runtime.elapsed_milliseconds, milliseconds) catch return error.TimerOverflow;
    while (true) {
        try drainAotProcessTasks(runtime);
        try drainAotFileTasks(runtime);
        try drainAotClientHttpTasks(runtime);
        try drainAotArchiveTasks(runtime);
        _ = try drainAotNativePluginTasks(runtime);
        try drainAotPromiseTasks(runtime);
        const index = earliestAotTimerIndex(runtime) orelse break;
        if (runtime.timers.items[index].due_milliseconds > target) break;
        try executeAotTimer(runtime, index);
    }
    try drainAotProcessTasks(runtime);
    try drainAotFileTasks(runtime);
    try drainAotClientHttpTasks(runtime);
    try drainAotArchiveTasks(runtime);
    _ = try drainAotNativePluginTasks(runtime);
    try drainAotPromiseTasks(runtime);
    try sleepAotUntil(runtime, target);
    try drainAotProcessTasks(runtime);
    try drainAotFileTasks(runtime);
    try drainAotClientHttpTasks(runtime);
    _ = try drainAotNativePluginTasks(runtime);
}

pub fn scheduleAotTimer(runtime: *Runtime, arguments: []const Value, repeating: bool, target: ?*Value) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    var values = [_]Value{ arguments[0], arguments[1], .{} };
    var root = RootFrame{};
    runtime.pushRoots(&root, &values, values.len);
    defer runtime.popRoots(&root);
    values[0] = try resolveAotCallback(runtime, values[0]);
    const delay = try aotDelayMilliseconds(runtime, values[1]);
    const id = runtime.next_timer_id;
    runtime.next_timer_id = std.math.add(u64, runtime.next_timer_id, 1) catch return error.TimerOverflow;
    const due = std.math.add(u64, runtime.elapsed_milliseconds, delay) catch return error.TimerOverflow;
    try runtime.timers.append(runtime.allocator, .{
        .id = id,
        .due_milliseconds = due,
        .interval_milliseconds = if (repeating) delay else 0,
        .repeating = repeating,
        .callback = values[0],
    });
    values[2] = numberValue(@floatFromInt(id));
    if (target) |pointer| pointer.* = values[2];
    return values[2];
}

pub fn timerBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value, target: ?*Value) !Value {
    switch (command) {
        .timer_after => return scheduleAotTimer(runtime, arguments, false, target),
        .timer_every => return scheduleAotTimer(runtime, arguments, true, target),
        .timer_stop => {
            if (arguments.len == 0 or arguments[arguments.len - 1].tag != @intFromEnum(Tag.number)) {
                return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
            }
            const number = @as(f64, @bitCast(arguments[arguments.len - 1].payload));
            if (!std.math.isFinite(number) or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
                return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
            }
            const id: u64 = @intFromFloat(@trunc(number));
            for (runtime.timers.items, 0..) |timer, index| {
                if (timer.id != id) continue;
                _ = runtime.timers.orderedRemove(index);
                return .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 };
            }
            return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
        },
        .timer_stop_all => {
            runtime.timers.clearRetainingCapacity();
            return .{};
        },
        else => return error.UnknownCommand,
    }
}

pub fn timerWaitBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const source = if (arguments.len > 0) arguments[arguments.len - 1] else Value{};
    const delay = try aotDelayMilliseconds(runtime, source);
    try waitAotMilliseconds(runtime, delay);
    return .{};
}

pub fn aotPromiseValue(object: *Object) Value {
    return .{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(object) };
}

pub fn aotPromiseObject(value: Value) ?*Object {
    if (value.tag != @intFromEnum(Tag.promise)) return null;
    const object = value.object() orelse return null;
    return if (object.payload == .promise) object else null;
}

pub fn createAotPromise(runtime: *Runtime) !Value {
    try runtime.beforeAllocation();
    return runtime.createObject(.{ .promise = .{} }, .promise);
}

pub fn enqueueAotPromiseReaction(runtime: *Runtime, promise: *Object, reaction: AotPromiseReaction) !void {
    const state = &promise.payload.promise;
    try runtime.promise_tasks.append(runtime.allocator, .{
        .callback = if (state.state == .rejected) reaction.on_rejected else reaction.on_fulfilled,
        .settled_value = state.result,
        .rejected = state.state == .rejected,
        .next = reaction.next,
        .mode = reaction.mode,
        .target_global = reaction.target_global,
    });
}

pub fn enqueueAotPromiseReactions(runtime: *Runtime, promise: *Object) !void {
    for (promise.payload.promise.reactions.items) |reaction| try enqueueAotPromiseReaction(runtime, promise, reaction);
    promise.payload.promise.reactions.clearRetainingCapacity();
}

pub fn aotPromiseThen(
    runtime: *Runtime,
    source: *Object,
    on_fulfilled: Value,
    on_rejected: Value,
    mode: AotPromiseReactionMode,
    target_global: ?*Value,
) !Value {
    var roots = [_]Value{ aotPromiseValue(source), on_fulfilled, on_rejected, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[3] = try createAotPromise(runtime);
    const reaction = AotPromiseReaction{
        .on_fulfilled = roots[1],
        .on_rejected = roots[2],
        .next = roots[3].object().?,
        .mode = mode,
        .target_global = target_global,
    };
    if (source.payload.promise.state == .pending) {
        try source.payload.promise.reactions.append(runtime.allocator, reaction);
    } else try enqueueAotPromiseReaction(runtime, source, reaction);
    return roots[3];
}

pub fn resolveAotPromise(runtime: *Runtime, promise: *Object, value: Value) !void {
    const state = &promise.payload.promise;
    if (state.state != .pending) return;
    if (aotPromiseObject(value)) |source| {
        if (source == promise) return error.PromiseResolutionCycle;
        const reaction = AotPromiseReaction{ .next = promise };
        if (source.payload.promise.state == .pending) {
            try source.payload.promise.reactions.append(runtime.allocator, reaction);
        } else try enqueueAotPromiseReaction(runtime, source, reaction);
        return;
    }
    state.state = .fulfilled;
    state.result = value;
    try enqueueAotPromiseReactions(runtime, promise);
}

pub fn rejectAotPromise(runtime: *Runtime, promise: *Object, reason: Value) !void {
    const state = &promise.payload.promise;
    if (state.state != .pending) return;
    state.state = .rejected;
    state.result = reason;
    try enqueueAotPromiseReactions(runtime, promise);
}

pub fn forwardAotPromiseTask(runtime: *Runtime, task: AotPromiseTask) !void {
    if (task.rejected) return rejectAotPromise(runtime, task.next, task.settled_value);
    return resolveAotPromise(runtime, task.next, task.settled_value);
}

pub fn callbackFailureReason(runtime: *Runtime, failure: anyerror) !Value {
    if (runtime.has_pending_exception) return runtime.takeException();
    return runtimeUtf8String(runtime, error_message.forFailure(failure));
}

pub fn executeAotPromiseTask(runtime: *Runtime, task: AotPromiseTask) !void {
    var roots = [_]Value{ task.callback, task.settled_value, aotPromiseValue(task.next), .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    if (roots[0].tag == @intFromEnum(Tag.undefined)) return forwardAotPromiseTask(runtime, task);
    if (roots[0].tag != @intFromEnum(Tag.function)) {
        roots[4] = try runtimeUtf8String(runtime, "NotCallable");
        return rejectAotPromise(runtime, task.next, roots[4]);
    }
    if (task.mode != .finally) {
        if (task.target_global) |target| target.* = roots[1];
    }

    var callback_arguments = [_]Value{ .{}, .{} };
    const callback_len: usize = switch (task.mode) {
        .standard => blk: {
            callback_arguments[0] = roots[1];
            break :blk 1;
        },
        .settled_pair => blk: {
            callback_arguments[0] = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(!task.rejected) };
            callback_arguments[1] = roots[1];
            break :blk 2;
        },
        .finally => 0,
    };
    roots[3] = invokeAotCallback(
        runtime,
        roots[0],
        if (callback_len == 0) null else callback_arguments[0..].ptr,
        callback_len,
    ) catch |failure| {
        roots[4] = try callbackFailureReason(runtime, failure);
        return rejectAotPromise(runtime, task.next, roots[4]);
    };
    if (task.mode == .finally) {
        if (task.rejected) return rejectAotPromise(runtime, task.next, task.settled_value);
        return resolveAotPromise(runtime, task.next, task.settled_value);
    }
    return resolveAotPromise(runtime, task.next, roots[3]);
}

pub fn createAotPromiseResolver(runtime: *Runtime, promise: *Object, rejected: bool) !Value {
    return runtime.createPromiseSpecialFunction(
        if (rejected) "reject" else "resolve",
        .{ .resolver = .{ .promise = promise, .rejected = rejected } },
    );
}

pub fn createAotPromiseWithExecutor(runtime: *Runtime, arguments: []const Value, last_promise: ?*Value) !Value {
    if (arguments.len == 0 or arguments[0].tag != @intFromEnum(Tag.function)) return error.NotCallable;
    var roots = [_]Value{ arguments[0], .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[1] = try createAotPromise(runtime);
    const promise = roots[1].object().?;
    roots[2] = try createAotPromiseResolver(runtime, promise, false);
    roots[3] = try createAotPromiseResolver(runtime, promise, true);
    var executor_arguments = [_]Value{ roots[2], roots[3] };
    _ = invokeAotCallback(runtime, roots[0], &executor_arguments, executor_arguments.len) catch |failure| {
        roots[4] = try callbackFailureReason(runtime, failure);
        try rejectAotPromise(runtime, promise, roots[4]);
    };
    if (last_promise) |target| target.* = roots[1];
    return roots[1];
}

pub fn chainAotPromise(
    runtime: *Runtime,
    arguments: []const Value,
    kind: AotPromiseChainKind,
    last_promise: ?*Value,
    target_global: ?*Value,
) !Value {
    if (arguments.len < 2 or arguments[0].tag != @intFromEnum(Tag.function)) return error.InvalidPromiseArguments;
    const source = aotPromiseObject(arguments[1]) orelse return error.InvalidPromiseArguments;
    var roots = [_]Value{ arguments[0], arguments[1], .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[2] = switch (kind) {
        .success => try aotPromiseThen(runtime, source, roots[0], .{}, .standard, target_global),
        .failure => try aotPromiseThen(runtime, source, .{}, roots[0], .standard, target_global),
        .settled => try aotPromiseThen(runtime, source, roots[0], roots[0], .settled_pair, target_global),
        .finally => try aotPromiseThen(runtime, source, roots[0], roots[0], .finally, target_global),
    };
    if (last_promise) |target| target.* = roots[2];
    return roots[2];
}

pub fn destroyAotPromiseAllState(runtime: *Runtime, state: *AotPromiseAllState) void {
    for (runtime.promise_all_states.items, 0..) |candidate, index| {
        if (candidate != state) continue;
        _ = runtime.promise_all_states.orderedRemove(index);
        runtime.allocator.destroy(state);
        return;
    }
}

pub fn handleAotPromiseAll(runtime: *Runtime, handler: AotPromiseAllHandler, settled: Value) !Value {
    const state = handler.state;
    if (handler.rejected) {
        try rejectAotPromise(runtime, state.promise, settled);
    } else {
        state.results.object().?.payload.array.items[handler.index] = settled;
    }
    if (state.remaining == 0) return .{};
    state.remaining -= 1;
    if (state.remaining == 0) {
        if (state.promise.payload.promise.state == .pending) try resolveAotPromise(runtime, state.promise, state.results);
        destroyAotPromiseAllState(runtime, state);
    }
    return .{};
}

pub fn createAotPromiseAllHandler(runtime: *Runtime, state: *AotPromiseAllState, index: usize, rejected: bool) !Value {
    return runtime.createPromiseSpecialFunction(
        if (rejected) "Promise.all rejected" else "Promise.all fulfilled",
        .{ .all_handler = .{ .state = state, .index = index, .rejected = rejected } },
    );
}

pub fn bundleAotPromises(runtime: *Runtime, arguments: []const Value, last_promise: ?*Value) !Value {
    const root_count = std.math.add(usize, arguments.len, 4) catch return error.ArrayTooLarge;
    const roots = try runtime.allocator.alloc(Value, root_count);
    defer runtime.allocator.free(roots);
    @memcpy(roots[0..arguments.len], arguments);
    @memset(roots[arguments.len..], .{});
    var frame = RootFrame{};
    runtime.pushRoots(&frame, roots.ptr, roots.len);
    defer runtime.popRoots(&frame);
    const promise_index = arguments.len;
    const results_index = arguments.len + 1;
    const fulfilled_index = arguments.len + 2;
    const rejected_index = arguments.len + 3;

    roots[promise_index] = try createAotPromise(runtime);
    roots[results_index] = try runtime.createArray(&.{});
    const result_items = &roots[results_index].object().?.payload.array;
    try result_items.ensureTotalCapacity(runtime.allocator, arguments.len);
    for (arguments) |_| try result_items.append(runtime.allocator, .{});

    const state = try runtime.allocator.create(AotPromiseAllState);
    state.* = .{ .promise = roots[promise_index].object().?, .results = roots[results_index] };
    try runtime.promise_all_states.append(runtime.allocator, state);
    var state_active = true;
    errdefer if (state_active) destroyAotPromiseAllState(runtime, state);

    for (arguments, 0..) |argument, index| {
        if (aotPromiseObject(argument)) |source| {
            state.remaining += 1;
            roots[fulfilled_index] = try createAotPromiseAllHandler(runtime, state, index, false);
            roots[rejected_index] = try createAotPromiseAllHandler(runtime, state, index, true);
            _ = try aotPromiseThen(runtime, source, roots[fulfilled_index], roots[rejected_index], .standard, null);
        } else result_items.items[index] = argument;
    }
    if (state.remaining == 0) {
        try resolveAotPromise(runtime, state.promise, state.results);
        destroyAotPromiseAllState(runtime, state);
        state_active = false;
    }
    if (last_promise) |target| target.* = roots[promise_index];
    return roots[promise_index];
}

pub fn promiseAotBuiltin(
    runtime: *Runtime,
    command: aot_builtin.Command,
    arguments: []const Value,
    last_promise: ?*Value,
    target_global: ?*Value,
) !Value {
    return switch (command) {
        .promise_create => createAotPromiseWithExecutor(runtime, arguments, last_promise),
        .promise_success => chainAotPromise(runtime, arguments, .success, last_promise, target_global),
        .promise_settled => chainAotPromise(runtime, arguments, .settled, last_promise, target_global),
        .promise_failure => chainAotPromise(runtime, arguments, .failure, last_promise, target_global),
        .promise_finally => chainAotPromise(runtime, arguments, .finally, last_promise, target_global),
        .promise_all => bundleAotPromises(runtime, arguments, last_promise),
        else => error.UnknownCommand,
    };
}

pub fn awaitAotPromise(runtime: *Runtime, value: Value) !Value {
    const promise = aotPromiseObject(value) orelse return value;
    var rooted = value;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, @ptrCast(&rooted), 1);
    defer runtime.popRoots(&frame);
    while (promise.payload.promise.state == .pending) {
        _ = try drainAotNativePluginTasks(runtime);
        try drainAotPromiseTasks(runtime);
        if (promise.payload.promise.state != .pending) break;
        if (earliestAotTimerIndex(runtime)) |index| {
            try executeAotTimer(runtime, index);
            continue;
        }
        break;
    }
    return switch (promise.payload.promise.state) {
        .fulfilled => promise.payload.promise.result,
        .rejected => {
            runtime.setException(promise.payload.promise.result);
            return error.NakoException;
        },
        .pending => error.PromiseStillPending,
    };
}

pub fn stringArrayBuiltin(runtime: *Runtime, names: []const []const u8) !Value {
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    for (names) |name| {
        roots[1] = try runtimeUtf8String(runtime, name);
        try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
    }
    return roots[0];
}

pub fn systemFunctionExistsBuiltin(runtime: *Runtime, values: []const Value) !Value {
    const source = if (values.len > 0) values[values.len - 1] else Value{};
    const text = try valueUtf8LossyAlloc(runtime, source);
    defer runtime.allocator.free(text);
    for (builtin_catalog.default_names) |candidate| {
        if (std.mem.eql(u8, text, candidate)) return .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 };
    }
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
}

/// Convert a UTF-16 exception message to UTF-8 without rejecting lone
/// surrogates.  JavaScript strings can contain unpaired surrogates, while the
/// process stderr stream is UTF-8; use U+FFFD for an unpaired code unit just
/// as the normal AOT output path does.
pub fn utf16FailureMessageUtf8Alloc(allocator: std.mem.Allocator, units: []const u16) anyerror![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < units.len) {
        const first = units[index];
        var codepoint: u21 = undefined;
        if (first >= 0xd800 and first <= 0xdbff and index + 1 < units.len and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) {
            const second = units[index + 1];
            codepoint = @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
            index += 2;
        } else {
            codepoint = if (first >= 0xd800 and first <= 0xdfff) 0xfffd else @intCast(first);
            index += 1;
        }

        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch return error.InvalidUnicodeScalar;
        try output.appendSlice(allocator, encoded[0..length]);
    }
    return output.toOwnedSlice(allocator);
}

pub fn pendingExceptionMessageUtf8Alloc(runtime: *Runtime) anyerror![]u8 {
    if (!runtime.has_pending_exception) return error.NoPendingException;
    const units = try valueUtf16Alloc(runtime, runtime.pending_exception);
    defer runtime.allocator.free(units);
    return utf16FailureMessageUtf8Alloc(runtime.allocator, units);
}

pub fn writeBytes(bytes: []const u8, newline: bool) void {
    for (bytes) |byte| _ = putchar(byte);
    if (newline) _ = putchar('\n');
}

const AotHttpPathStat = enum { file, directory, missing };

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

pub fn runtimeFailure(failure: anyerror) noreturn {
    std.debug.print("[実行時エラー] {s}\n", .{@errorName(failure)});
    std.process.exit(1);
}

pub var active_runtime: ?Runtime = null;
pub var aot_interrupt_requested = std.atomic.Value(bool).init(false);

const AotPosixInterrupt = if (builtin.os.tag == .windows) struct {} else struct {
    pub fn handler(_: std.posix.SIG) callconv(.c) void {
        aot_interrupt_requested.store(true, .release);
    }
};

const AotWindowsInterrupt = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn SetConsoleCtrlHandler(handler_fn: ?*const fn (u32) callconv(.winapi) i32, add: i32) callconv(.winapi) i32;

    pub fn handler(control_type: u32) callconv(.winapi) i32 {
        if (control_type != 0 and control_type != 1) return 0;
        aot_interrupt_requested.store(true, .release);
        return 1;
    }
} else struct {};

pub fn installAotInterrupt() !void {
    if (builtin.os.tag == .windows) {
        if (AotWindowsInterrupt.SetConsoleCtrlHandler(AotWindowsInterrupt.handler, 1) == 0) return error.InterruptHandlingUnavailable;
    } else {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = AotPosixInterrupt.handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, null);
    }
}

pub fn pollAotInterrupt(runtime: *Runtime) !void {
    if (!aot_interrupt_requested.swap(false, .acquire)) return;
    if (runtime.interrupt_callback.tag != @intFromEnum(Tag.function)) return;

    var undefined_value = Value{};
    const result = try invokeAotCallback(runtime, runtime.interrupt_callback, @ptrCast(&undefined_value), 1);
    if (valueTruthy(result)) {
        runtime.dispatch_trace.finishTerminal("interrupt-callback", 0);
        _ = fflush(null);
        std.process.exit(0);
    }
}

/// Records execution of one statically identified global load. The generated
/// module supplies the ID from its pre-optimization global manifest.
/// Records execution of one statically identified global store. The generated
/// module supplies the ID from its pre-optimization global manifest.
/// Records execution of one statically identified typed literal. The
/// generated module supplies the ID from its pre-optimization literal
/// manifest.
pub fn nodeBasenameWideFor(path: []const u16, windows: bool) []const u16 {
    var end = path.len;
    while (end > 0 and nodePathSeparatorWide(path[end - 1], windows)) end -= 1;
    if (end == 0) return &.{};
    const drive_path = windows and path.len >= 2 and isWindowsDriveLetterWide(path[0]) and path[1] == ':';
    if (drive_path and end == 2 and path.len > end and nodePathSeparatorWide(path[2], true)) return &.{};
    var start = end;
    while (start > 0 and !nodePathSeparatorWide(path[start - 1], windows)) start -= 1;
    if (drive_path and start < 2) start = 2;
    return path[start..end];
}

/// Initializes Node-host constants whose values depend on the generated
/// executable's process arguments.  The generated main has already rooted
/// every referenced global before this function is called, so newly allocated
/// strings and the command-line array remain visible to the collector while
/// the values are being assembled.
/// Windows' `wmain` receives UTF-16 command-line arguments.  Keep those code
/// units intact so WTF-16 input, including unpaired surrogates, follows the
/// same value representation as the rest of the runtime.
/// Initializes Node directory values that are exposed as globals when a
/// program uses the shorthand form without parentheses.
/// Initializes the source directory used by Node's mother-path global and
/// function. Relative source paths are resolved against the executable's
/// current working directory, matching the interpreter host context.
/// Runs callbacks that were registered by the generated program before its
/// global roots are removed. This gives AOT the same top-level timer drain as
/// the Interpreter while keeping callback values inside the native runtime.
/// Installs the four mutable globals used by the built-in HTTP server. The
/// generated main roots these globals for the lifetime of the event loop.
/// Dedicated ABI for the six synchronous commands exposed by
/// `plugin_httpserver.mjs`. The implementation is native AOT code and does
/// not load or evaluate JavaScript.
/// Site-aware display hooks used by generated LLVM.  The hooks are additive;
/// the runtime ABI for existing generated modules remains unchanged.
/// Begins a direct-display trace and returns the failure epoch observed at the
/// same boundary through `epoch_out`.  The extra out parameter avoids making
/// the call ID carry two independent pieces of state across LLVM IR.
/// Records a source-level `エラー発生` throw. This is intentionally a
/// separate ABI from `lnako_aot_builtin_call_site`: the compiler lowers the
/// command to a throw terminator so exception handler control flow remains
/// explicit and no generic builtin dispatch is introduced.
pub fn debugDisplayBuiltin(runtime: *Runtime, value: Value, line: u64, source_path: []const u8, display_log: ?*Value) !void {
    var roots = [_]Value{ value, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    var printable = value;
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .array, .dictionary => {
            roots[1] = try jsonEncodeBuiltin(runtime, value, false);
            printable = roots[1];
        },
        else => {},
    }
    const text = try valueUtf8LossyAlloc(runtime, printable);
    defer runtime.allocator.free(text);
    const normalized_source_path = normalizeDebugSourcePath(source_path, builtin.os.tag == .windows);
    const message = try std.fmt.allocPrint(runtime.allocator, "{s}({d}): {s}", .{ normalized_source_path, line, text });
    defer runtime.allocator.free(message);
    roots[2] = try runtimeUtf8String(runtime, message);
    try displayValue(runtime, roots[2], true, display_log);
}

pub fn normalizeDebugSourcePath(source_path: []const u8, windows: bool) []const u8 {
    if (windows) {
        if (std.mem.indexOfScalar(u8, source_path, ':')) |separator| return source_path[0..separator];
    }
    return source_path;
}

/// AOT版`ハテナ関数実行`は、カスタムコールバックが未設定なら公式既定動作
/// （`デバッグ表示`）を、設定済みなら純Zigのコールバック列を専用ABIで実行する。
/// `JS:`コールバックの評価だけは通常AOTへ持ち込まず、明示的なcompat-js境界に残す。
/// Dedicated ABI for plugin and namespace state.  These commands mutate
/// system globals, so the targets are explicit instead of being looked up by
/// name inside the AOT runtime.
/// Dedicated ABI for Node's archive tool path setter. The setter mutates a
/// system global, while archive execution itself remains a separate external
/// tool boundary.
/// Dedicated ABI for Node's ZIP archive commands. The default path keeps the
/// existing pure-Zig stored-ZIP implementation; an explicitly changed tool
/// path is invoked with argv semantics, matching the command's external-tool
/// boundary without introducing a JavaScript runtime into AOT.
/// Dedicated ABI for Node's AJAX option setter. The option object is kept in
/// the corresponding rooted system global; actual HTTP execution remains a
/// separate external boundary.
/// Dedicated ABI for Node's AJAX error callback setter. The callback value is
/// kept in the corresponding rooted system global; invoking it on a failed
/// HTTP operation remains a separate external boundary.
/// Dedicated ABI for Node's HTTP client commands. Requests use Zig's native
/// HTTP client; callback and Response-Promise results are returned through the
/// AOT event queue so their observable ordering remains compatible with the
/// interpreter without embedding a JavaScript runtime.
pub fn nodeNetworkAddressesBuiltin(runtime: *Runtime, ipv6: bool) !Value {
    const synthetic = if (std.c.getenv("LNAKO_TEST_NETWORK_TOPOLOGY")) |topology|
        std.mem.eql(u8, std.mem.span(topology), "synthetic-v1")
    else
        false;
    var addresses = if (synthetic)
        try syntheticAotNetworkAddresses(runtime.allocator, ipv6)
    else if (builtin.os.tag == .windows)
        try aotWindowsNetworkAddresses(runtime.allocator, ipv6)
    else
        try aotPosixNetworkAddresses(runtime.allocator, ipv6);
    defer deinitAotNetworkAddressList(runtime.allocator, &addresses);

    var result = try runtime.createArray(&.{});
    var frame = RootFrame{};
    runtime.pushRoots(&frame, @ptrCast(&result), 1);
    defer runtime.popRoots(&frame);
    for (addresses.items) |address| {
        const value = try runtimeUtf8StringLossy(runtime, address);
        try result.object().?.payload.array.append(runtime.allocator, value);
    }
    return result;
}

pub fn syntheticAotNetworkAddresses(allocator: std.mem.Allocator, ipv6: bool) !std.ArrayList([]u8) {
    // Keep the AOT test route byte-for-byte aligned with the CLI host's
    // synthetic topology. The marker is injected only by oracle fixtures.
    const addresses: []const []const u8 = if (ipv6)
        &.{ "::1", "fe80::1234", "2001:db8::10" }
    else
        &.{ "127.0.0.1", "192.0.2.10" };
    var items: std.ArrayList([]u8) = .empty;
    errdefer deinitAotNetworkAddressList(allocator, &items);
    for (addresses) |address| try items.append(allocator, try allocator.dupe(u8, address));
    return items;
}

pub fn aotPosixNetworkAddresses(allocator: std.mem.Allocator, ipv6: bool) !std.ArrayList([]u8) {
    if (builtin.os.tag == .windows) return error.NetworkInterfacesUnavailable;
    var first: ?*AotPosixIfAddrs = null;
    if (AotPosixInterfaces.getifaddrs(&first) != 0) return error.NetworkInterfacesUnavailable;
    defer AotPosixInterfaces.freeifaddrs(first);

    var items: std.ArrayList([]u8) = .empty;
    errdefer deinitAotNetworkAddressList(allocator, &items);
    var current = first;
    while (current) |entry| : (current = entry.next) {
        // Nodeのos.networkInterfaces()が内部で使うlibuvと同じく、
        // UPかつRUNNINGのインターフェイスだけを公開する。
        if ((entry.flags & 0x1) == 0 or (entry.flags & 0x40) == 0) continue;
        const address = entry.address orelse continue;
        const family: usize = @intCast(address.family);
        if ((!ipv6 and family != std.posix.AF.INET) or (ipv6 and family != std.posix.AF.INET6)) continue;
        try items.append(allocator, try aotFormatSockAddress(allocator, address));
    }
    return items;
}

pub fn aotWindowsNetworkAddresses(allocator: std.mem.Allocator, ipv6: bool) !std.ArrayList([]u8) {
    if (builtin.os.tag != .windows) return error.NetworkInterfacesUnavailable;
    const overflow_code = 111;
    var size: u32 = 15 * 1024;
    var storage = try allocator.alignedAlloc(u8, .of(AotWindowsAdapterAddresses), size);
    defer allocator.free(storage);
    var result = AotWindowsInterfaces.GetAdaptersAddresses(std.os.windows.ws2_32.AF.UNSPEC, 0, null, @ptrCast(storage.ptr), &size);
    if (result == overflow_code) {
        storage = try allocator.realloc(storage, size);
        result = AotWindowsInterfaces.GetAdaptersAddresses(std.os.windows.ws2_32.AF.UNSPEC, 0, null, @ptrCast(storage.ptr), &size);
    }
    if (result != 0) return error.NetworkInterfacesUnavailable;

    var items: std.ArrayList([]u8) = .empty;
    errdefer deinitAotNetworkAddressList(allocator, &items);
    var adapter: ?*AotWindowsAdapterAddresses = @ptrCast(storage.ptr);
    while (adapter) |current| : (adapter = current.next) {
        var unicast = current.first_unicast_address;
        while (unicast) |entry| : (unicast = entry.next) {
            const address = entry.address.address orelse continue;
            const family: usize = @intCast(address.family);
            if ((!ipv6 and family != std.os.windows.ws2_32.AF.INET) or (ipv6 and family != std.os.windows.ws2_32.AF.INET6)) continue;
            try items.append(allocator, try aotFormatWindowsSockAddress(allocator, address));
        }
    }
    return items;
}

pub fn deinitAotNetworkAddressList(allocator: std.mem.Allocator, items: *std.ArrayList([]u8)) void {
    for (items.items) |item| allocator.free(item);
    items.deinit(allocator);
}

pub fn aotFormatSockAddress(allocator: std.mem.Allocator, address: *const std.posix.sockaddr) ![]u8 {
    if (address.family == std.posix.AF.INET) {
        const source: *const std.posix.sockaddr.in = @ptrCast(@alignCast(address));
        const bytes: *const [4]u8 = @ptrCast(&source.addr);
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    }
    const source: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(address));
    return aotFormatIpv6Address(allocator, source.addr);
}

pub fn aotFormatWindowsSockAddress(allocator: std.mem.Allocator, address: *const std.os.windows.ws2_32.sockaddr) ![]u8 {
    if (address.family == std.os.windows.ws2_32.AF.INET) {
        const source: *const std.os.windows.ws2_32.sockaddr.in = @ptrCast(@alignCast(address));
        const bytes: *const [4]u8 = @ptrCast(&source.addr);
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    }
    const source: *const std.os.windows.ws2_32.sockaddr.in6 = @ptrCast(@alignCast(address));
    return aotFormatIpv6Address(allocator, source.addr);
}

pub fn aotFormatIpv6Address(allocator: std.mem.Allocator, bytes: [16]u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const unresolved: std.Io.net.Ip6Address.Unresolved = .{ .bytes = bytes, .interface_name = null };
    try output.writer.print("{f}", .{unresolved});
    return output.toOwnedSlice();
}

pub fn promiseSentinel(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = .{};
}

pub fn byteBufferUnboundSliceCallback(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    runtime.setFailureText("Cannot read properties of undefined (reading 'subarray')");
}

/// Dedicated ABI for Node's synchronous standard-input callback command. The
/// callback and `対象` storage are passed explicitly so a local variable with
/// the same source-level name cannot redirect the command's side effect.
pub fn builtinDispatchRoute(command: aot_builtin.Command) []const u8 {
    return aot_builtin.dispatchRoute(command);
}

pub fn typeNameValue(value: Value) Value {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => staticStringValue("undefined"),
        .null_value, .byte_buffer, .array, .dictionary, .iterator, .promise => staticStringValue("object"),
        .boolean => staticStringValue("boolean"),
        .number => staticStringValue("number"),
        .static_utf8_string, .utf16_string => staticStringValue("string"),
        .bigint => staticStringValue("bigint"),
        .function => staticStringValue("function"),
        .binding_cell => typeNameValue(value.object().?.payload.binding_cell),
    };
}

pub fn parseIntBuiltin(runtime: *Runtime, value: Value) !f64 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return number_mod.parseIntPrefix(units, null);
}

pub fn parseFloatBuiltin(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => @bitCast(value.payload),
        .bigint => value.object().?.payload.bigint.toF64(),
        else => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk try number_mod.parseFloatPrefix(runtime.allocator, units);
        },
    };
}

pub fn mathBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const a: Value = if (arguments.len > 0) arguments[0] else .{};
    const b: Value = if (arguments.len > 1) arguments[1] else .{};
    return switch (command) {
        .math_sin => numberValue(@sin(try valueToNumberRuntime(runtime, a))),
        .math_cos => numberValue(@cos(try valueToNumberRuntime(runtime, a))),
        .math_tan => numberValue(@tan(try valueToNumberRuntime(runtime, a))),
        .math_arcsin => numberValue(std.math.asin(try valueToNumberRuntime(runtime, a))),
        .math_arccos => numberValue(std.math.acos(try valueToNumberRuntime(runtime, a))),
        .math_arctan => numberValue(std.math.atan(try valueToNumberRuntime(runtime, a))),
        .math_atan2 => numberValue(std.math.atan2(try valueToNumberRuntime(runtime, a), try valueToNumberRuntime(runtime, b))),
        .math_coordinate_angle => numberValue(try mathCoordinateAngle(runtime, a)),
        .math_rad2deg => numberValue(try valueToNumberRuntime(runtime, a) / std.math.pi * 180),
        .math_deg2rad => numberValue(try valueToNumberRuntime(runtime, a) / 180 * std.math.pi),
        .math_sign => numberValue(try mathSign(runtime, a)),
        .math_abs => numberValue(@abs(try valueToNumberRuntime(runtime, a))),
        .math_exp => numberValue(@exp(try valueToNumberRuntime(runtime, a))),
        .math_hypot => numberValue(std.math.hypot(try valueToNumberRuntime(runtime, a), try valueToNumberRuntime(runtime, b))),
        .math_log => numberValue(@log(try valueToNumberRuntime(runtime, a))),
        .math_logn => numberValue(try mathLogarithm(runtime, a, b)),
        .math_frac => numberValue(@rem(try valueToNumberRuntime(runtime, a), 1)),
        .math_integer => numberValue(@trunc(try valueToNumberRuntime(runtime, a))),
        .math_sqrt => numberValue(@sqrt(try valueToNumberRuntime(runtime, a))),
        .math_round => numberValue(mathRound(try valueToNumberRuntime(runtime, a))),
        .math_decimal_ceil => numberValue(try mathDecimalRound(runtime, a, b, .ceil)),
        .math_decimal_floor => numberValue(try mathDecimalRound(runtime, a, b, .floor)),
        .math_decimal_round => numberValue(try mathDecimalRound(runtime, a, b, .round)),
        .math_ceil => numberValue(@ceil(try valueToNumberRuntime(runtime, a))),
        .math_floor => numberValue(@floor(try valueToNumberRuntime(runtime, a))),
        .math_random => try mathRandom(runtime, a),
        .math_random_range => try mathRandomRange(runtime, a, b),
        else => error.UnknownCommand,
    };
}

pub const default_random_seed: u64 = 5573589319906701683;

pub fn initialRandomState() u64 {
    const environment = std.c.getenv("LNAKO_TEST_RANDOM_SEED") orelse {
        const timestamp: u64 = @bitCast(time(null));
        const mixed = timestamp ^ @intFromPtr(&active_runtime);
        return if (mixed == 0) default_random_seed else mixed;
    };
    const parsed = std.fmt.parseInt(u64, std.mem.span(environment), 10) catch return default_random_seed;
    return if (parsed == 0) default_random_seed else parsed;
}

pub fn nextRandom(runtime: *Runtime) f64 {
    if (runtime.random_state == 0) runtime.random_state = initialRandomState();
    var value = runtime.random_state;
    value ^= value >> 12;
    value ^= value << 25;
    value ^= value >> 27;
    runtime.random_state = value;
    const bits = (value *% 0x2545f4914f6cdd1d) >> 11;
    return @as(f64, @floatFromInt(bits)) / 9007199254740992.0;
}

pub fn mathRandom(runtime: *Runtime, source: Value) !Value {
    const random = nextRandom(runtime);
    if (source.tag == @intFromEnum(Tag.number)) return numberValue(@floor(random * @as(f64, @bitCast(source.payload))));

    var minimum: Value = .{};
    var maximum: Value = .{};
    switch (@as(Tag, @enumFromInt(source.tag))) {
        .array => {
            const items = source.object().?.payload.array.items;
            minimum = if (items.len > 0) items[0] else .{};
            maximum = if (items.len > 1) items[1] else .{};
        },
        .dictionary => {
            minimum = runtime.indexGet(source, staticStringValue("先頭"));
            maximum = runtime.indexGet(source, staticStringValue("末尾"));
        },
        else => return .{},
    }
    const lower = try valueToNumberRuntime(runtime, minimum);
    const upper = try valueToNumberRuntime(runtime, maximum);
    return numberValue(@floor(random * (upper - lower + 1)) + lower);
}

pub fn mathRandomRange(runtime: *Runtime, minimum: Value, maximum: Value) !Value {
    const random = nextRandom(runtime);
    const lower = try valueToNumberRuntime(runtime, minimum);
    const upper = try valueToNumberRuntime(runtime, maximum);
    return numberValue(@floor(random * (upper - lower + 1)) + lower);
}

pub fn caniuseBrowsersBuiltin(runtime: *Runtime) !Value {
    if (runtime.caniuse_browsers.tag != @intFromEnum(Tag.undefined)) return runtime.caniuse_browsers;

    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createDictionary(&.{});
    for (caniuse_browsers) |browser| {
        roots[1] = try runtime.createArray(&.{});
        for (browser.versions) |version| {
            const value = try runtimeUtf8String(runtime, version);
            try roots[1].object().?.payload.array.append(runtime.allocator, value);
        }
        roots[2] = try runtimeUtf8String(runtime, browser.key);
        try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[2], roots[1]);
    }
    runtime.caniuse_browsers = roots[0];
    return roots[0];
}

const CaniuseBrowser = struct { key: []const u8, versions: []const []const u8 };

pub fn caniuseAgentsBuiltin(runtime: *Runtime) !Value {
    if (runtime.caniuse_agents.tag != @intFromEnum(Tag.undefined)) return runtime.caniuse_agents;

    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createDictionary(&.{});
    for (caniuse_agents) |agent| {
        roots[1] = try runtimeUtf8String(runtime, agent.key);
        roots[2] = try runtimeUtf8String(runtime, agent.name);
        try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
    }
    runtime.caniuse_agents = roots[0];
    return roots[0];
}

pub fn eraDataBuiltin(runtime: *Runtime) !Value {
    if (runtime.era_data.tag != @intFromEnum(Tag.undefined)) return runtime.era_data;

    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    for (era_data) |era| {
        roots[1] = try runtime.createDictionary(&.{});
        roots[2] = try runtimeUtf8String(runtime, "元号");
        roots[3] = try runtimeUtf8String(runtime, era.name);
        try runtime.setDictionary(&roots[1].object().?.payload.dictionary, roots[2], roots[3]);
        roots[2] = try runtimeUtf8String(runtime, "改元日");
        roots[4] = try runtimeUtf8String(runtime, era.date);
        try runtime.setDictionary(&roots[1].object().?.payload.dictionary, roots[2], roots[4]);
        try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
    }
    runtime.era_data = roots[0];
    return roots[0];
}

const CaniuseAgent = struct { key: []const u8, name: []const u8 };

const AotEra = struct { name: []const u8, date: []const u8 };

const era_data = [_]AotEra{
    .{ .name = "令和", .date = "2019/05/01" },
    .{ .name = "平成", .date = "1989/01/08" },
    .{ .name = "昭和", .date = "1926/12/25" },
    .{ .name = "大正", .date = "1912/07/30" },
    .{ .name = "明治", .date = "1868/10/23" },
};

// This is the generated v3.7.24 browsers_agents.mjs snapshot. The AOT
// runtime owns its copy so normal execution never loads the JavaScript
// caniuse plugin.
const caniuse_agents = [_]CaniuseAgent{
    .{ .key = "ie", .name = "IE" },
    .{ .key = "edge", .name = "Edge" },
    .{ .key = "firefox", .name = "Firefox" },
    .{ .key = "chrome", .name = "Chrome" },
    .{ .key = "safari", .name = "Safari" },
    .{ .key = "opera", .name = "Opera" },
    .{ .key = "ios_saf", .name = "Safari on iOS" },
    .{ .key = "op_mini", .name = "Opera Mini" },
    .{ .key = "android", .name = "Android Browser" },
    .{ .key = "bb", .name = "Blackberry Browser" },
    .{ .key = "op_mob", .name = "Opera Mobile" },
    .{ .key = "and_chr", .name = "Chrome for Android" },
    .{ .key = "and_ff", .name = "Firefox for Android" },
    .{ .key = "ie_mob", .name = "IE Mobile" },
    .{ .key = "and_uc", .name = "UC Browser for Android" },
    .{ .key = "samsung", .name = "Samsung Internet" },
    .{ .key = "and_qq", .name = "QQ Browser" },
    .{ .key = "baidu", .name = "Baidu Browser" },
    .{ .key = "kaios", .name = "KaiOS Browser" },
};

// This is the generated v3.7.24 browsers.mjs snapshot. The AOT runtime owns
// its copy so normal execution never loads the JavaScript caniuse plugin.
const caniuse_browsers = [_]CaniuseBrowser{
    .{ .key = "and_chr", .versions = &.{"145"} },
    .{ .key = "and_ff", .versions = &.{"147"} },
    .{ .key = "and_qq", .versions = &.{"14.9"} },
    .{ .key = "and_uc", .versions = &.{"15.5"} },
    .{ .key = "android", .versions = &.{"145"} },
    .{ .key = "chrome", .versions = &.{ "145", "144", "143", "142", "139", "133", "131", "125", "112", "109" } },
    .{ .key = "edge", .versions = &.{ "145", "144", "143", "142" } },
    .{ .key = "firefox", .versions = &.{ "147", "146", "145", "140" } },
    .{ .key = "ios_saf", .versions = &.{ "26.3", "26.2", "26.1", "18.5-18.7", "16.6-16.7" } },
    .{ .key = "kaios", .versions = &.{ "3.0-3.1", "2.5" } },
    .{ .key = "node", .versions = &.{ "25.1.0", "24.11.0", "22.21.0" } },
    .{ .key = "op_mini", .versions = &.{"all"} },
    .{ .key = "op_mob", .versions = &.{"80"} },
    .{ .key = "opera", .versions = &.{ "125", "124" } },
    .{ .key = "safari", .versions = &.{ "26.3", "26.2" } },
    .{ .key = "samsung", .versions = &.{ "29", "28" } },
};

const datetime_milliseconds_per_second: i64 = 1000;
const datetime_milliseconds_per_minute: i64 = 60 * datetime_milliseconds_per_second;
const datetime_milliseconds_per_hour: i64 = 60 * datetime_milliseconds_per_minute;
const datetime_milliseconds_per_day: i64 = 24 * datetime_milliseconds_per_hour;
const datetime_tokyo_offset_milliseconds: i64 = 9 * datetime_milliseconds_per_hour;

const AotDateFields = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    millisecond: i64,
    weekday: u8,
};

const AotDateDifferenceUnit = enum { year, month, day, hour, minute, second };

pub fn datetimeBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const now = currentTimeMilliseconds(runtime);
    return switch (command) {
        .datetime_now => datetimeTimeString(runtime, datetimeFieldsFromEpoch(now)),
        .datetime_system_time => numberValue(@floor(@as(f64, @floatFromInt(now)) / datetime_milliseconds_per_second)),
        .datetime_system_time_milliseconds => numberValue(@as(f64, @floatFromInt(now))),
        .datetime_today => datetimeDateString(runtime, datetimeFieldsFromEpoch(now)),
        .datetime_tomorrow => datetimeDateString(runtime, datetimeFieldsFromEpoch(now + datetime_milliseconds_per_day)),
        .datetime_yesterday => datetimeDateString(runtime, datetimeFieldsFromEpoch(now - datetime_milliseconds_per_day)),
        .datetime_current_year => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).year))),
        .datetime_next_year => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).year + 1))),
        .datetime_last_year => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).year - 1))),
        .datetime_current_month => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).month))),
        .datetime_next_month => numberValue(@as(f64, @floatFromInt(@mod(datetimeFieldsFromEpoch(now).month, 12) + 1))),
        .datetime_previous_month => numberValue(@as(f64, @floatFromInt(@mod(datetimeFieldsFromEpoch(now).month + 10, 12) + 1))),
        .datetime_weekday => if (arguments.len < 1)
            error.InvalidArgumentCount
        else
            datetimeWeekdayName(runtime, try datetimeParseDate(runtime, arguments[0], now)),
        .datetime_weekday_number => if (arguments.len < 1)
            error.InvalidArgumentCount
        else
            datetimeWeekdayNumber(runtime, arguments[0]),
        .datetime_unix_time => if (arguments.len < 1)
            error.InvalidArgumentCount
        else
            numberValue(try datetimeParseDate(runtime, arguments[0], now) / datetime_milliseconds_per_second),
        .datetime_date_time => if (arguments.len < 1)
            error.InvalidArgumentCount
        else
            datetimeDateTimeString(runtime, try valueToNumberRuntime(runtime, arguments[0]) * datetime_milliseconds_per_second),
        .datetime_format => if (arguments.len < 2)
            error.InvalidArgumentCount
        else
            datetimeFormatCustom(runtime, try datetimeParseDate(runtime, arguments[0], now), arguments[1]),
        .datetime_era => if (arguments.len < 1)
            error.InvalidArgumentCount
        else
            datetimeJapaneseEra(runtime, try datetimeParseDate(runtime, arguments[0], now)),
        .datetime_year_difference => datetimeDifferenceBuiltin(runtime, .year, arguments, now),
        .datetime_month_difference => datetimeDifferenceBuiltin(runtime, .month, arguments, now),
        .datetime_day_difference => datetimeDifferenceBuiltin(runtime, .day, arguments, now),
        .datetime_hour_difference => datetimeDifferenceBuiltin(runtime, .hour, arguments, now),
        .datetime_minute_difference => datetimeDifferenceBuiltin(runtime, .minute, arguments, now),
        .datetime_second_difference => datetimeDifferenceBuiltin(runtime, .second, arguments, now),
        .datetime_difference => if (arguments.len < 3)
            error.InvalidArgumentCount
        else
            datetimeDifferenceWithUnitBuiltin(runtime, arguments, now),
        .datetime_add_time => datetimeAddTimeBuiltin(runtime, arguments, now),
        .datetime_add_date => datetimeAddDateBuiltin(runtime, arguments, now),
        .datetime_add_datetime => datetimeAddDateTimeBuiltin(runtime, arguments, now),
        .datetime_monotonic_milliseconds => numberValue(monotonicTimeMilliseconds(runtime)),
        else => error.UnknownCommand,
    };
}

pub fn currentTimeMilliseconds(runtime: *Runtime) i64 {
    if (runtime.clock_milliseconds) |value| return value;
    if (std.c.getenv("LNAKO_TEST_NOW_MS")) |environment| {
        return std.fmt.parseInt(i64, std.mem.span(environment), 10) catch hostWallClockMilliseconds();
    }
    return hostWallClockMilliseconds();
}

pub fn datetimePluginRouteEnabled() bool {
    const route = std.c.getenv("LNAKO_PLUGIN_ROUTE") orelse return false;
    return std.mem.eql(u8, std.mem.span(route), "plugin_datetime");
}

pub fn hostWallClockMilliseconds() i64 {
    const seconds = time(null);
    return std.math.mul(i64, seconds, datetime_milliseconds_per_second) catch if (seconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

pub fn datetimeFieldsFromEpoch(milliseconds: i64) AotDateFields {
    const local = milliseconds + datetime_tokyo_offset_milliseconds;
    const days = @divFloor(local, datetime_milliseconds_per_day);
    const within_day = @mod(local, datetime_milliseconds_per_day);
    const civil = datetimeCivilFromDays(days);
    return .{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = @divTrunc(within_day, datetime_milliseconds_per_hour),
        .minute = @divTrunc(@mod(within_day, datetime_milliseconds_per_hour), datetime_milliseconds_per_minute),
        .second = @divTrunc(@mod(within_day, datetime_milliseconds_per_minute), datetime_milliseconds_per_second),
        .millisecond = @mod(within_day, datetime_milliseconds_per_second),
        .weekday = @intCast(@mod(days + 4, 7)),
    };
}

pub fn datetimeValueUtf8Alloc(runtime: *Runtime, value: Value) ![]u8 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
}

pub fn datetimeParseDate(runtime: *Runtime, source: Value, now: i64) !f64 {
    const utf8 = try datetimeValueUtf8Alloc(runtime, source);
    defer runtime.allocator.free(utf8);
    const text = std.mem.trim(u8, utf8, " \t\r\n");
    if (datetimeIsUnsignedDecimal(text)) return std.math.trunc((std.fmt.parseFloat(f64, text) catch return std.math.nan(f64)) * 1000);
    if (datetimeIsTimeText(text)) {
        const parts = try datetimeParseDelimited(text, ':');
        const today = datetimeFieldsFromEpoch(now);
        return @floatFromInt(datetimeConstructLocal(today.year, today.month - 1, today.day, parts[0], parts[1], parts[2], 0, true));
    }
    const normalized = try runtime.allocator.dupe(u8, text);
    defer runtime.allocator.free(normalized);
    for (normalized) |*byte| if (byte.* == ' ' or byte.* == ':' or byte.* == '-' or byte.* == 'T') {
        byte.* = '/';
    };
    var parts = [_]i64{ 0, 0, 0, 0, 0, 0 };
    var iterator = std.mem.splitScalar(u8, normalized, '/');
    var index: usize = 0;
    while (iterator.next()) |part| {
        if (index >= parts.len) break;
        parts[index] = datetimeParseIntPrefix(part) orelse return std.math.nan(f64);
        index += 1;
    }
    if (index < 3) return std.math.nan(f64);
    return @floatFromInt(datetimeConstructLocal(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5], 0, true));
}

pub fn datetimeWeekdayName(runtime: *Runtime, milliseconds: f64) !Value {
    if (!std.math.isFinite(milliseconds)) return runtimeUtf8String(runtime, "日");
    const names = [_][]const u8{ "日", "月", "火", "水", "木", "金", "土" };
    return runtimeUtf8String(runtime, names[datetimeFieldsFromEpoch(datetimeFloatToEpoch(milliseconds)).weekday]);
}

pub fn datetimeWeekdayNumber(runtime: *Runtime, source: Value) !Value {
    const text = try datetimeValueUtf8Alloc(runtime, source);
    defer runtime.allocator.free(text);
    var iterator = std.mem.splitScalar(u8, text, '/');
    const year = datetimeParseIntPrefix(iterator.next() orelse return numberValue(std.math.nan(f64))) orelse return numberValue(std.math.nan(f64));
    const month = datetimeParseIntPrefix(iterator.next() orelse return numberValue(std.math.nan(f64))) orelse return numberValue(std.math.nan(f64));
    const day = datetimeParseIntPrefix(iterator.next() orelse return numberValue(std.math.nan(f64))) orelse return numberValue(std.math.nan(f64));
    return numberValue(@floatFromInt(datetimeFieldsFromEpoch(datetimeConstructLocal(year, month - 1, day, 0, 0, 0, 0, true)).weekday));
}

pub fn datetimeConstructLocal(year_input: i64, month_zero_input: i64, day: i64, hour: i64, minute: i64, second: i64, millisecond: i64, constructor_year_rule: bool) i64 {
    var year = year_input;
    if (constructor_year_rule and year >= 0 and year <= 99) year += 1900;
    year += @divFloor(month_zero_input, 12);
    const month_zero = @mod(month_zero_input, 12);
    const days = datetimeDaysFromCivil(year, month_zero + 1, 1) + day - 1;
    return days * datetime_milliseconds_per_day + hour * datetime_milliseconds_per_hour + minute * datetime_milliseconds_per_minute + second * datetime_milliseconds_per_second + millisecond - datetime_tokyo_offset_milliseconds;
}

pub fn datetimeDaysFromCivil(year_input: i64, month: i64, day: i64) i64 {
    var year = year_input;
    year -= @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

pub fn datetimeParseDelimited(text: []const u8, delimiter: u8) ![3]i64 {
    var result = [_]i64{ 0, 0, 0 };
    var iterator = std.mem.splitScalar(u8, text, delimiter);
    var index: usize = 0;
    while (iterator.next()) |part| {
        if (index >= result.len) break;
        result[index] = datetimeParseIntPrefix(part) orelse 0;
        index += 1;
    }
    if (index == 0) return error.InvalidDatePart;
    return result;
}

pub fn datetimeParseIntPrefix(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    var index: usize = 0;
    var negative = false;
    if (text[index] == '+' or text[index] == '-') {
        negative = text[index] == '-';
        index += 1;
    }
    const start = index;
    var value: i64 = 0;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
        value = std.math.mul(i64, value, 10) catch return null;
        value = std.math.add(i64, value, text[index] - '0') catch return null;
    }
    if (index == start) return null;
    return if (negative) -value else value;
}

pub fn datetimeIsUnsignedDecimal(text: []const u8) bool {
    if (text.len == 0) return false;
    var dot = false;
    for (text) |byte| {
        if (byte == '.' and !dot) {
            dot = true;
        } else if (!std.ascii.isDigit(byte)) return false;
    }
    return text[0] != '.' and text[text.len - 1] != '.';
}

pub fn datetimeIsTimeText(text: []const u8) bool {
    var separators: usize = 0;
    if (text.len == 0) return false;
    for (text) |byte| {
        if (byte == ':') separators += 1 else if (!std.ascii.isDigit(byte)) return false;
    }
    return separators == 1 or separators == 2;
}

pub fn datetimeFloatToEpoch(value: f64) i64 {
    if (!std.math.isFinite(value)) return 0;
    const clipped = std.math.clamp(std.math.trunc(value), @as(f64, @floatFromInt(std.math.minInt(i64) + 1)), @as(f64, @floatFromInt(std.math.maxInt(i64))));
    return @intFromFloat(clipped);
}

pub fn datetimeDateString(runtime: *Runtime, fields: AotDateFields) !Value {
    const text = try std.fmt.allocPrint(runtime.allocator, "{d}/{:02}/{:02}", .{ fields.year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)) });
    defer runtime.allocator.free(text);
    return runtimeUtf8String(runtime, text);
}

pub fn datetimeTimeString(runtime: *Runtime, fields: AotDateFields) !Value {
    const text = try std.fmt.allocPrint(runtime.allocator, "{:02}:{:02}:{:02}", .{ @as(u64, @intCast(fields.hour)), @as(u64, @intCast(fields.minute)), @as(u64, @intCast(fields.second)) });
    defer runtime.allocator.free(text);
    return runtimeUtf8String(runtime, text);
}

pub fn datetimeDateTimeString(runtime: *Runtime, milliseconds: f64) !Value {
    const fields = datetimeFieldsFromEpoch(datetimeFloatToEpoch(milliseconds));
    const text = try std.fmt.allocPrint(runtime.allocator, "{d}/{:02}/{:02} {:02}:{:02}:{:02}", .{ fields.year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)), @as(u64, @intCast(fields.hour)), @as(u64, @intCast(fields.minute)), @as(u64, @intCast(fields.second)) });
    defer runtime.allocator.free(text);
    return runtimeUtf8String(runtime, text);
}

const AotDateOutputShape = enum { date_time, date, time };

pub fn datetimeFormatDateTimeFor(runtime: *Runtime, fields: AotDateFields, shape: AotDateOutputShape) !Value {
    return switch (shape) {
        .date => datetimeDateString(runtime, fields),
        .time => datetimeTimeString(runtime, fields),
        .date_time => blk: {
            const text = try std.fmt.allocPrint(runtime.allocator, "{d}/{:02}/{:02} {:02}:{:02}:{:02}", .{ fields.year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)), @as(u64, @intCast(fields.hour)), @as(u64, @intCast(fields.minute)), @as(u64, @intCast(fields.second)) });
            defer runtime.allocator.free(text);
            break :blk runtimeUtf8String(runtime, text);
        },
    };
}

pub fn datetimeOutputShape(runtime: *Runtime, original: Value) !AotDateOutputShape {
    const text = try datetimeValueUtf8Alloc(runtime, original);
    defer runtime.allocator.free(text);
    if (datetimeLooksDateTime(text)) return .date_time;
    if (datetimeLooksDate(text)) return .date;
    if (datetimeIsTimeText(text)) return .time;
    return .date_time;
}

pub fn datetimeFormatCustom(runtime: *Runtime, milliseconds: f64, format_value: Value) !Value {
    if (!std.math.isFinite(milliseconds)) return runtimeUtf8String(runtime, "Invalid Date");
    const fields = datetimeFieldsFromEpoch(datetimeFloatToEpoch(milliseconds));
    const format = try datetimeValueUtf8Alloc(runtime, format_value);
    defer runtime.allocator.free(format);
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    var index: usize = 0;
    while (index < format.len) {
        if (datetimeMatchToken(format, index, "YYYY")) {
            try output.writer.print("{d}", .{fields.year});
            index += 4;
        } else if (datetimeMatchToken(format, index, "ccc")) {
            try output.writer.print("{:03}", .{@as(u64, @intCast(fields.millisecond))});
            index += 3;
        } else if (datetimeMatchToken(format, index, "WWW")) {
            const names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
            try output.writer.writeAll(names[fields.weekday]);
            index += 3;
        } else if (datetimeMatchToken(format, index, "MMM")) {
            const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            try output.writer.writeAll(names[@intCast(fields.month - 1)]);
            index += 3;
        } else if (index + 2 <= format.len and datetimeIsTwoToken(format[index .. index + 2])) {
            const token = format[index .. index + 2];
            if (std.mem.eql(u8, token, "YY"))
                try output.writer.print("{:02}", .{@as(u64, @intCast(@mod(fields.year, 100)))})
            else if (std.mem.eql(u8, token, "MM"))
                try output.writer.print("{:02}", .{@as(u64, @intCast(fields.month))})
            else if (std.mem.eql(u8, token, "DD"))
                try output.writer.print("{:02}", .{@as(u64, @intCast(fields.day))})
            else if (std.mem.eql(u8, token, "HH"))
                try output.writer.print("{:02}", .{@as(u64, @intCast(fields.hour))})
            else if (std.mem.eql(u8, token, "mm"))
                try output.writer.print("{:02}", .{@as(u64, @intCast(fields.minute))})
            else
                try output.writer.print("{:02}", .{@as(u64, @intCast(fields.second))});
            index += 2;
        } else switch (format[index]) {
            'M' => {
                try output.writer.print("{d}", .{fields.month});
                index += 1;
            },
            'D' => {
                try output.writer.print("{d}", .{fields.day});
                index += 1;
            },
            'H' => {
                try output.writer.print("{d}", .{fields.hour});
                index += 1;
            },
            'm' => {
                try output.writer.print("{d}", .{fields.minute});
                index += 1;
            },
            's' => {
                try output.writer.print("{d}", .{fields.second});
                index += 1;
            },
            'W' => {
                const names = [_][]const u8{ "日", "月", "火", "水", "木", "金", "土" };
                try output.writer.writeAll(names[fields.weekday]);
                index += 1;
            },
            else => {
                try output.writer.writeByte(format[index]);
                index += 1;
            },
        }
    }
    return runtimeUtf8String(runtime, output.written());
}

pub fn datetimeJapaneseEra(runtime: *Runtime, milliseconds: f64) !Value {
    if (!std.math.isFinite(milliseconds)) return error.InvalidDate;
    const fields = datetimeFieldsFromEpoch(datetimeFloatToEpoch(milliseconds));
    const day_number = datetimeDaysFromCivil(fields.year, fields.month, fields.day);
    for (era_data) |era| {
        const era_date = datetimeEraDateFields(era.date);
        if (day_number < datetimeDaysFromCivil(era_date.year, era_date.month, era_date.day)) continue;
        const era_year = fields.year - era_date.year + 1;
        const text = if (era_year == 1)
            try std.fmt.allocPrint(runtime.allocator, "{s}元年{:02}月{:02}日", .{ era.name, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)) })
        else
            try std.fmt.allocPrint(runtime.allocator, "{s}{d}年{:02}月{:02}日", .{ era.name, era_year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)) });
        defer runtime.allocator.free(text);
        return runtimeUtf8String(runtime, text);
    }
    return error.DateBeforeMeiji;
}

pub fn datetimeEraDateFields(date: []const u8) struct { year: i64, month: i64, day: i64 } {
    var iterator = std.mem.splitScalar(u8, date, '/');
    return .{
        .year = datetimeParseIntPrefix(iterator.next() orelse "0") orelse 0,
        .month = datetimeParseIntPrefix(iterator.next() orelse "0") orelse 0,
        .day = datetimeParseIntPrefix(iterator.next() orelse "0") orelse 0,
    };
}

pub fn datetimeDifferenceBuiltin(runtime: *Runtime, unit: AotDateDifferenceUnit, arguments: []const Value, now: i64) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const first = try datetimeParseDate(runtime, arguments[0], now);
    const second = try datetimeParseDate(runtime, arguments[1], now);
    if (unit == .year or unit == .month) {
        if (!std.math.isFinite(first) or !std.math.isFinite(second)) return numberValue(std.math.nan(f64));
        const left = datetimeFieldsFromEpoch(datetimeFloatToEpoch(first));
        const right = datetimeFieldsFromEpoch(datetimeFloatToEpoch(second));
        const difference = if (unit == .year)
            right.year - left.year
        else
            right.year * 12 + right.month - 1 - (left.year * 12 + left.month - 1);
        return numberValue(@floatFromInt(difference));
    }
    const first_seconds = @ceil(first / datetime_milliseconds_per_second);
    const second_seconds = @ceil(second / datetime_milliseconds_per_second);
    const divisor: f64 = switch (unit) {
        .day => 86400,
        .hour => 3600,
        .minute => 60,
        .second => 1,
        else => unreachable,
    };
    return numberValue(@ceil((second_seconds - first_seconds) / divisor));
}

pub fn datetimeDifferenceWithUnitBuiltin(runtime: *Runtime, arguments: []const Value, now: i64) !Value {
    const unit = try datetimeDifferenceUnit(runtime, arguments[2]);
    return datetimeDifferenceBuiltin(runtime, unit, arguments[0..2], now);
}

pub fn datetimeDifferenceUnit(runtime: *Runtime, value: Value) !AotDateDifferenceUnit {
    const text = try datetimeValueUtf8Alloc(runtime, value);
    defer runtime.allocator.free(text);
    if (std.mem.eql(u8, text, "年")) return .year;
    if (std.mem.eql(u8, text, "月")) return .month;
    if (std.mem.eql(u8, text, "日")) return .day;
    if (std.mem.eql(u8, text, "時間")) return .hour;
    if (std.mem.eql(u8, text, "分")) return .minute;
    if (std.mem.eql(u8, text, "秒")) return .second;
    return error.UnknownDateUnit;
}

pub fn datetimeAddTimeBuiltin(runtime: *Runtime, arguments: []const Value, now: i64) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const addition = try datetimeValueUtf8Alloc(runtime, arguments[1]);
    defer runtime.allocator.free(addition);
    return datetimeAddTimeText(runtime, arguments[0], addition, now);
}

pub fn datetimeAddTimeText(runtime: *Runtime, source: Value, addition: []const u8, now: i64) !Value {
    var text = addition;
    var sign: i64 = 1;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
        if (text[0] == '-') sign = -1;
        text = text[1..];
    }
    const parts = try datetimeParseDelimited(text, ':');
    const seconds = sign * (parts[0] * 3600 + parts[1] * 60 + parts[2]);
    const original = try datetimeParseDate(runtime, source, now);
    if (!std.math.isFinite(original)) return error.InvalidDate;
    return datetimeFormatDateTimeFor(runtime, datetimeFieldsFromEpoch(datetimeFloatToEpoch(original) + seconds * 1000), try datetimeOutputShape(runtime, source));
}

pub fn datetimeAddDateBuiltin(runtime: *Runtime, arguments: []const Value, now: i64) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const addition = try datetimeValueUtf8Alloc(runtime, arguments[1]);
    defer runtime.allocator.free(addition);
    return datetimeAddDateText(runtime, arguments[0], addition, now);
}

pub fn datetimeAddDateText(runtime: *Runtime, source: Value, addition: []const u8, now: i64) !Value {
    var text = addition;
    var sign: i64 = 1;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
        if (text[0] == '-') sign = -1;
        text = text[1..];
    }
    const parts = try datetimeParseDelimited(text, '/');
    const original = try datetimeParseDate(runtime, source, now);
    if (!std.math.isFinite(original)) return error.InvalidDate;
    const original_epoch = datetimeFloatToEpoch(original);
    const epoch = if (datetimePluginRouteEnabled())
        datetimeAddDatePluginEpoch(original_epoch, parts, sign)
    else
        datetimeAddDateSystemEpoch(original_epoch, parts, sign);
    return datetimeFormatDateTimeFor(runtime, datetimeFieldsFromEpoch(epoch), try datetimeOutputShape(runtime, source));
}

pub fn datetimeAddDateSystemEpoch(original: i64, parts: [3]i64, sign: i64) i64 {
    var fields = datetimeFieldsFromEpoch(original);
    var epoch = datetimeConstructLocal(fields.year + parts[0] * sign, fields.month - 1, fields.day, fields.hour, fields.minute, fields.second, fields.millisecond, false);
    fields = datetimeFieldsFromEpoch(epoch);
    epoch = datetimeConstructLocal(fields.year, fields.month - 1 + parts[1] * sign, fields.day, fields.hour, fields.minute, fields.second, fields.millisecond, false);
    fields = datetimeFieldsFromEpoch(epoch);
    return datetimeConstructLocal(fields.year, fields.month - 1, fields.day + parts[2] * sign, fields.hour, fields.minute, fields.second, fields.millisecond, false);
}

/// The old-format `plugin_datetime` implementation delegates each component
/// to dayjs.  Calendar-unit additions therefore clamp to the last day of the
/// target month, unlike the system plugin's JavaScript Date overflow.
pub fn datetimeAddDatePluginEpoch(original: i64, parts: [3]i64, sign: i64) i64 {
    var fields = datetimeFieldsFromEpoch(original);
    var epoch = datetimeAddCalendarClamped(fields, parts[0] * sign, 0);
    fields = datetimeFieldsFromEpoch(epoch);
    epoch = datetimeAddCalendarClamped(fields, 0, parts[1] * sign);
    return epoch + parts[2] * sign * datetime_milliseconds_per_day;
}

pub fn datetimeAddCalendarClamped(fields: AotDateFields, year_delta: i64, month_delta: i64) i64 {
    const month_zero = fields.month - 1 + month_delta;
    const year = fields.year + year_delta + @divFloor(month_zero, 12);
    const normalized_month_zero = @mod(month_zero, 12);
    const day = @min(fields.day, datetimeDaysInMonth(year, normalized_month_zero + 1));
    return datetimeConstructLocal(year, normalized_month_zero, day, fields.hour, fields.minute, fields.second, fields.millisecond, false);
}

pub fn datetimeDaysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        2 => if (datetimeIsLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

pub fn datetimeIsLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn datetimeAddDateTimeBuiltin(runtime: *Runtime, arguments: []const Value, now: i64) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const addition = try datetimeValueUtf8Alloc(runtime, arguments[1]);
    defer runtime.allocator.free(addition);
    var text = addition;
    var sign: i64 = 1;
    var cursor: usize = 0;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
        if (text[0] == '-') sign = -1;
        cursor = 1;
    }
    const number_start = cursor;
    while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
    if (cursor == number_start) return error.InvalidDateAddition;
    const amount = (std.fmt.parseInt(i64, text[number_start..cursor], 10) catch return error.InvalidDateAddition) * sign;
    const unit = text[cursor..];
    if (std.mem.eql(u8, unit, "年")) return datetimeAddDateTimeWithAffix(runtime, arguments[0], now, amount, "/0/0", false);
    if (std.mem.eql(u8, unit, "ヶ月")) return datetimeAddDateTimeAround(runtime, arguments[0], now, amount, "0/", "/0", false);
    if (std.mem.eql(u8, unit, "週間")) return datetimeAddDateTimeWithAffix(runtime, arguments[0], now, amount * 7, "0/0/", false);
    if (std.mem.eql(u8, unit, "日")) return datetimeAddDateTimeWithAffix(runtime, arguments[0], now, amount, "0/0/", false);
    if (std.mem.eql(u8, unit, "時間")) return datetimeAddDateTimeWithAffix(runtime, arguments[0], now, amount, ":0:0", true);
    if (std.mem.eql(u8, unit, "分")) return datetimeAddDateTimeAround(runtime, arguments[0], now, amount, "0:", ":0", true);
    if (std.mem.eql(u8, unit, "秒")) return datetimeAddDateTimeWithAffix(runtime, arguments[0], now, amount, "0:0:", true);
    return error.InvalidDateAddition;
}

pub fn datetimeAddDateTimeWithAffix(runtime: *Runtime, source: Value, now: i64, amount: i64, prefix_or_suffix: []const u8, is_time: bool) !Value {
    const text = if (prefix_or_suffix.len > 0 and (prefix_or_suffix[0] == '/' or prefix_or_suffix[0] == ':'))
        try std.fmt.allocPrint(runtime.allocator, "{d}{s}", .{ amount, prefix_or_suffix })
    else
        try std.fmt.allocPrint(runtime.allocator, "{s}{d}", .{ prefix_or_suffix, amount });
    defer runtime.allocator.free(text);
    return if (is_time) datetimeAddTimeText(runtime, source, text, now) else datetimeAddDateText(runtime, source, text, now);
}

pub fn datetimeAddDateTimeAround(runtime: *Runtime, source: Value, now: i64, amount: i64, prefix: []const u8, suffix: []const u8, is_time: bool) !Value {
    const text = try std.fmt.allocPrint(runtime.allocator, "{s}{d}{s}", .{ prefix, amount, suffix });
    defer runtime.allocator.free(text);
    return if (is_time) datetimeAddTimeText(runtime, source, text, now) else datetimeAddDateText(runtime, source, text, now);
}

pub fn monotonicTimeMilliseconds(runtime: *Runtime) f64 {
    if (runtime.monotonic_milliseconds) |value| return value;
    if (std.c.getenv("LNAKO_TEST_MONOTONIC_MS")) |environment| {
        if (std.fmt.parseFloat(f64, std.mem.span(environment))) |value| return value else |_| {}
    }
    const timestamp = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake);
    return @as(f64, @floatFromInt(timestamp.nanoseconds)) / 1_000_000.0;
}

pub fn datetimeLooksDate(text: []const u8) bool {
    var separators: usize = 0;
    for (text) |byte| {
        if (byte == '/') separators += 1 else if (!std.ascii.isDigit(byte)) return false;
    }
    return separators == 2;
}

pub fn datetimeLooksDateTime(text: []const u8) bool {
    const space = std.mem.indexOfAny(u8, text, " \t") orelse return false;
    return datetimeLooksDate(text[0..space]) and datetimeIsTimeText(std.mem.trim(u8, text[space..], " \t"));
}

pub fn datetimeIsTwoToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "YY") or std.mem.eql(u8, token, "MM") or std.mem.eql(u8, token, "DD") or std.mem.eql(u8, token, "HH") or std.mem.eql(u8, token, "mm") or std.mem.eql(u8, token, "ss");
}

pub fn datetimeMatchToken(text: []const u8, index: usize, token: []const u8) bool {
    return index + token.len <= text.len and std.mem.eql(u8, text[index .. index + token.len], token);
}

pub fn runtimeUtf8String(runtime: *Runtime, text: []const u8) !Value {
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

pub fn runtimeUtf8StringLossy(runtime: *Runtime, text: []const u8) !Value {
    const decoded = try string_mod.String.fromUtf8Lossy(runtime.allocator, text);
    return runtime.ownString(decoded.units);
}

pub fn urlBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    return switch (command) {
        .url_encode => urlEncodeBuiltin(runtime, arguments[0]),
        .url_decode => urlDecodeBuiltin(runtime, arguments[0]),
        .url_parameters => urlParametersBuiltin(runtime, arguments[0]),
        .base64_encode => base64EncodeBuiltin(runtime, arguments[0]),
        .base64_decode => base64DecodeBuiltin(runtime, arguments[0]),
        else => error.UnknownCommand,
    };
}

pub fn pathBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const required: usize = if (command == .path_change_extension) 2 else 1;
    if (arguments.len < required) return error.InvalidArgumentCount;
    return switch (command) {
        .path_extract_extension => pathExtractExtensionBuiltin(runtime, arguments[0]),
        .path_change_extension => pathChangeExtensionBuiltin(runtime, arguments[0], arguments[1]),
        .path_add_trailing_separator => pathAddTrailingSeparatorBuiltin(runtime, arguments[0]),
        .path_remove_trailing_separator => pathRemoveTrailingSeparatorBuiltin(runtime, arguments[0]),
        .path_delete_trailing_separator => pathRemoveTrailingSeparatorBuiltin(runtime, arguments[0]),
        else => error.UnknownCommand,
    };
}

pub fn pathExtractExtensionBuiltin(runtime: *Runtime, source: Value) !Value {
    const source_tag: Tag = @enumFromInt(source.tag);
    if (source_tag == .undefined or source_tag == .null_value) return runtimeUtf8String(runtime, "");
    if (!isString(source)) return error.InvalidPathSource;
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    const filename = pathBasenameUnits(units, pathSeparatorUnit());
    const dot = std.mem.lastIndexOfScalar(u16, filename, '.') orelse return runtimeUtf8String(runtime, "");
    if (dot + 1 == filename.len or !pathAllExtensionUnits(filename[dot + 1 ..])) return runtimeUtf8String(runtime, "");
    return runtime.createString(filename[dot..]);
}

pub fn pathChangeExtensionBuiltin(runtime: *Runtime, source: Value, extension: Value) !Value {
    const source_tag: Tag = @enumFromInt(source.tag);
    if (source_tag == .undefined or source_tag == .null_value) return extension;
    if (!isString(source)) return error.InvalidPathSource;
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    if (extension.tag == @intFromEnum(Tag.undefined) or extension.tag == @intFromEnum(Tag.null_value)) {
        return pathChangeExtensionUnits(runtime, source_units, &.{});
    }
    if (!isString(extension)) return error.InvalidPathSource;
    const extension_units = try valueUtf16Alloc(runtime, extension);
    defer runtime.allocator.free(extension_units);
    return pathChangeExtensionUnits(runtime, source_units, extension_units);
}

pub fn pathChangeExtensionUnits(runtime: *Runtime, source: []const u16, extension: []const u16) !Value {
    const raw_extension = string_mod.trimWhitespace(extension);
    const separator = pathSeparatorUnit();
    const last_separator = std.mem.lastIndexOfScalar(u16, source, separator);
    const filename_start = if (last_separator) |index| index + 1 else 0;
    const filename = source[filename_start..];
    var filename_end = filename.len;
    if (std.mem.lastIndexOfScalar(u16, filename, '.')) |dot| {
        if (dot + 1 < filename.len and pathAllExtensionUnits(filename[dot + 1 ..])) filename_end = dot;
    }

    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator);
    if (filename_start > 0) try output.appendSlice(runtime.allocator, source[0..filename_start]);
    try output.appendSlice(runtime.allocator, filename[0..filename_end]);
    if (raw_extension.len > 0) {
        if (raw_extension[0] != '.') try output.append(runtime.allocator, '.');
        try output.appendSlice(runtime.allocator, raw_extension);
    }
    return runtime.createString(output.items);
}

pub fn pathAddTrailingSeparatorBuiltin(runtime: *Runtime, source: Value) !Value {
    const source_tag: Tag = @enumFromInt(source.tag);
    if (source_tag == .undefined or source_tag == .null_value) return runtimeUtf8String(runtime, "");
    if (!isString(source)) return error.InvalidPathSource;
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    if (units.len == 0 or units[units.len - 1] == pathSeparatorUnit()) return source;
    var output = try runtime.allocator.alloc(u16, units.len + 1);
    defer runtime.allocator.free(output);
    @memcpy(output[0..units.len], units);
    output[output.len - 1] = pathSeparatorUnit();
    return runtime.createString(output);
}

pub fn pathRemoveTrailingSeparatorBuiltin(runtime: *Runtime, source: Value) !Value {
    const source_tag: Tag = @enumFromInt(source.tag);
    if (source_tag == .undefined or source_tag == .null_value or
        source_tag == .boolean and source.payload == 0 or
        source_tag == .number and (@as(f64, @bitCast(source.payload)) == 0 or std.math.isNan(@as(f64, @bitCast(source.payload)))))
    {
        return runtimeUtf8String(runtime, "");
    }
    if (!isString(source)) return error.InvalidPathSource;
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    if (units.len == 0 or units[units.len - 1] != pathSeparatorUnit()) return source;
    return runtime.createString(units[0 .. units.len - 1]);
}

pub fn pathSeparatorUnit() u16 {
    return if (std.fs.path.sep_str.len > 0) std.fs.path.sep_str[0] else '/';
}

pub fn pathBasenameUnits(path: []const u16, separator: u16) []const u16 {
    const index = std.mem.lastIndexOfScalar(u16, path, separator) orelse return path;
    return path[index + 1 ..];
}

pub fn pathAllExtensionUnits(units: []const u16) bool {
    for (units) |unit| switch (unit) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '+' => {},
        else => return false,
    };
    return true;
}

const kansujiBasicKanji = [_][]const u8{ "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九" };
const kansujiAxes = [_][]const u8{ "", "十", "百", "千" };
const kansujiUnits = [_][]const u8{
    "",
    "万",
    "億",
    "兆",
    "京",
    "垓",
    "𥝱",
    "穣",
    "溝",
    "澗",
    "正",
    "載",
    "極",
    "恒河沙",
    "阿僧祇",
    "那由他",
    "不可思議",
    "無量大数",
};

pub fn kansujiBuiltin(runtime: *Runtime, command: aot_builtin.Command, input: Value) !Value {
    return switch (command) {
        .kansuji_to_kanji => kansujiToKanjiBuiltin(runtime, input),
        .kansuji_to_arabic => kansujiToArabicBuiltin(runtime, input),
        else => error.UnknownCommand,
    };
}

pub fn kansujiInputUtf8(runtime: *Runtime, input: Value) ![]u8 {
    const units = try valueUtf16Alloc(runtime, input);
    defer runtime.allocator.free(units);
    return (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
}

pub fn kansujiToKanjiBuiltin(runtime: *Runtime, input: Value) !Value {
    const raw = try kansujiInputUtf8(runtime, input);
    defer runtime.allocator.free(raw);
    const ascii = try kansujiFullwidthDigits(runtime.allocator, raw);
    defer runtime.allocator.free(ascii);
    const expanded = kansujiExpandDecimal(runtime.allocator, ascii) catch |failure| blk: {
        if (failure != error.InvalidKansujiInput or !kansujiIsJsNumberString(ascii)) return failure;
        break :blk try runtime.allocator.dupe(u8, ascii);
    };
    defer runtime.allocator.free(expanded);

    var source = expanded;
    var sign: []const u8 = "";
    if (source.len > 0 and (source[0] == '+' or source[0] == '-')) {
        sign = source[0..1];
        source = source[1..];
    }
    const units_utf16 = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, source);
    defer runtime.allocator.free(units_utf16);
    const point = std.mem.indexOfScalar(u16, units_utf16, '.') orelse units_utf16.len;
    const integer = units_utf16[0..point];
    const fraction = if (point < units_utf16.len) units_utf16[point + 1 ..] else &.{};
    const magnitude = std.mem.trimStart(u16, integer, &.{@as(u16, '0')});
    if (kansujiAllAsciiDigitUnits(integer) and kansujiAllAsciiDigitUnits(fraction) and magnitude.len > 72 and
        (sign.len == 0 or sign[0] != '-')) return error.KansujiTooLarge;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);
    try output.appendSlice(runtime.allocator, sign);
    var wrote_integer = false;
    if (integer.len > 0) {
        const group_count = (integer.len + 3) / 4;
        var group_index: usize = 0;
        while (group_index < group_count) : (group_index += 1) {
            const start = if (group_index == 0) 0 else integer.len - (group_count - group_index) * 4;
            const end = integer.len - (group_count - group_index - 1) * 4;
            const group = integer[start..end];
            var wrote_group = false;
            for (group, 0..) |digit_unit, digit_index| {
                if (digit_unit == '0') continue;
                const axis_index = group.len - digit_index - 1;
                if (digit_unit != '1' or axis_index == 0) try output.appendSlice(runtime.allocator, kansujiKanjiDigit(digit_unit));
                try output.appendSlice(runtime.allocator, kansujiAxes[axis_index]);
                wrote_group = true;
                wrote_integer = true;
            }
            const large_index = group_count - group_index - 1;
            if (wrote_group and large_index > 0) {
                try output.appendSlice(runtime.allocator, if (large_index < kansujiUnits.len) kansujiUnits[large_index] else "undefined");
            }
        }
    }
    if (!wrote_integer) try output.appendSlice(runtime.allocator, "零");
    if (point < units_utf16.len) {
        try output.appendSlice(runtime.allocator, "・");
        for (fraction) |digit| try output.appendSlice(runtime.allocator, kansujiKanjiDigit(digit));
    }
    return runtimeUtf8String(runtime, output.items);
}

pub fn kansujiToArabicBuiltin(runtime: *Runtime, input: Value) !Value {
    const source = try kansujiInputUtf8(runtime, input);
    defer runtime.allocator.free(source);
    var total = try BigInt.init(runtime.allocator, 0);
    errdefer total.deinit();
    var unit_sum = try BigInt.init(runtime.allocator, 0);
    defer unit_sum.deinit();
    var base: std.ArrayList(u64) = .empty;
    defer base.deinit(runtime.allocator);
    var fraction: std.ArrayList(u8) = .empty;
    defer fraction.deinit(runtime.allocator);
    var after_point = false;
    var index: usize = 0;
    while (index < source.len) {
        if (std.mem.startsWith(u8, source[index..], "・")) {
            if (after_point) return error.InvalidArabicNumeral;
            try kansujiAddFinalBase(runtime.allocator, &unit_sum, &base);
            try kansujiAddBig(runtime.allocator, &total, unit_sum);
            unit_sum.deinit();
            unit_sum = try BigInt.init(runtime.allocator, 0);
            after_point = true;
            index += "・".len;
            continue;
        }
        if (kansujiMatchAny(source[index..], kansujiUnits[1..])) |matched| {
            if (after_point) {
                var ten = try BigInt.init(runtime.allocator, 10);
                defer ten.deinit();
                var factor = try ten.pow(runtime.allocator, @intCast(4 * (matched.index + 1)));
                defer factor.deinit();
                const text = try factor.toString(runtime.allocator, 10);
                defer runtime.allocator.free(text);
                try fraction.appendSlice(runtime.allocator, text);
            } else {
                try kansujiAddDefaultedBase(runtime.allocator, &unit_sum, &base);
                var ten = try BigInt.init(runtime.allocator, 10);
                defer ten.deinit();
                var factor = try ten.pow(runtime.allocator, @intCast(4 * (matched.index + 1)));
                defer factor.deinit();
                const product = try unit_sum.mul(runtime.allocator, factor);
                unit_sum.deinit();
                unit_sum = product;
                try kansujiAddBig(runtime.allocator, &total, unit_sum);
                unit_sum.deinit();
                unit_sum = try BigInt.init(runtime.allocator, 0);
            }
            index += matched.text.len;
            continue;
        }
        if (kansujiMatchAny(source[index..], kansujiAxes[1..])) |matched| {
            const axis_value = std.math.pow(u64, 10, matched.index + 1);
            if (after_point) {
                var buffer: [4]u8 = undefined;
                try fraction.appendSlice(runtime.allocator, try std.fmt.bufPrint(&buffer, "{d}", .{axis_value}));
            } else {
                if (base.items.len == 0) try base.append(runtime.allocator, 1);
                try base.append(runtime.allocator, axis_value);
                try kansujiAddPair(runtime.allocator, &unit_sum, base.items);
                base.clearRetainingCapacity();
            }
            index += matched.text.len;
            continue;
        }
        if (kansujiMatchDigit(source[index..])) |digit| {
            if (after_point) {
                try fraction.append(runtime.allocator, '0' + digit.value);
            } else try base.append(runtime.allocator, digit.value);
            index += digit.length;
            continue;
        }
        if (std.mem.startsWith(u8, source[index..], "零")) {
            if (after_point) try fraction.append(runtime.allocator, '0') else try base.append(runtime.allocator, 0);
            index += "零".len;
            continue;
        }
        return error.InvalidArabicNumeral;
    }
    if (!after_point) {
        try kansujiAddFinalBase(runtime.allocator, &unit_sum, &base);
        try kansujiAddBig(runtime.allocator, &total, unit_sum);
    }
    if (after_point) {
        const integer_text = try total.toString(runtime.allocator, 10);
        defer runtime.allocator.free(integer_text);
        const decimal = try std.fmt.allocPrint(runtime.allocator, "{s}.{s}", .{ integer_text, fraction.items });
        defer runtime.allocator.free(decimal);
        const number = std.fmt.parseFloat(f64, decimal) catch return error.InvalidArabicNumeral;
        total.deinit();
        return numberValue(number);
    }
    const text = try total.toString(runtime.allocator, 10);
    defer runtime.allocator.free(text);
    if (text.len < 16 or (text.len == 16 and std.mem.order(u8, text, "9007199254740991") != .gt)) {
        const number = std.fmt.parseFloat(f64, text) catch unreachable;
        total.deinit();
        return numberValue(number);
    }
    const result = try runtime.createBigInt(text);
    total.deinit();
    return result;
}

const KansujiMatch = struct { index: usize, text: []const u8 };

pub fn kansujiMatchAny(source: []const u8, options: []const []const u8) ?KansujiMatch {
    var best: ?KansujiMatch = null;
    for (options, 0..) |option, index| {
        if (!std.mem.startsWith(u8, source, option)) continue;
        if (best == null or option.len > best.?.text.len) best = .{ .index = index, .text = option };
    }
    return best;
}

const KansujiDigitMatch = struct { value: u8, length: usize };

pub fn kansujiMatchDigit(source: []const u8) ?KansujiDigitMatch {
    for (kansujiBasicKanji, 0..) |digit, value| if (std.mem.startsWith(u8, source, digit)) {
        return .{ .value = @intCast(value), .length = digit.len };
    };
    return null;
}

pub fn kansujiAddDefaultedBase(allocator: std.mem.Allocator, target: *BigInt, base: *std.ArrayList(u64)) !void {
    if (base.items.len == 0) try base.appendSlice(allocator, &.{ 0, 1 }) else if (base.items.len == 1) try base.append(allocator, 1);
    try kansujiAddPair(allocator, target, base.items);
    base.clearRetainingCapacity();
}

pub fn kansujiAddFinalBase(allocator: std.mem.Allocator, target: *BigInt, base: *std.ArrayList(u64)) !void {
    if (base.items.len == 1) {
        try base.append(allocator, 1);
        try kansujiAddPair(allocator, target, base.items);
    }
    base.clearRetainingCapacity();
}

pub fn kansujiAddPair(allocator: std.mem.Allocator, target: *BigInt, pair: []const u64) !void {
    if (pair.len < 2) return;
    var value = try BigInt.init(allocator, pair[0] * pair[1]);
    defer value.deinit();
    const sum = try target.add(allocator, value);
    target.deinit();
    target.* = sum;
}

pub fn kansujiAddBig(allocator: std.mem.Allocator, target: *BigInt, value: BigInt) !void {
    const sum = try target.add(allocator, value);
    target.deinit();
    target.* = sum;
}

pub fn kansujiFullwidthDigits(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(source[index]) catch return error.InvalidKansujiInput;
        const codepoint = std.unicode.utf8Decode(source[index..][0..sequence_length]) catch return error.InvalidKansujiInput;
        if (codepoint >= 0xff10 and codepoint <= 0xff19) {
            try output.append(allocator, @intCast('0' + codepoint - 0xff10));
        } else try output.appendSlice(allocator, source[index .. index + sequence_length]);
        index += sequence_length;
    }
    return output.toOwnedSlice(allocator);
}

pub fn kansujiExpandDecimal(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len > 0 and (source[0] == '+' or source[0] == '-')) {
        if (!kansujiValidDecimal(source)) return error.InvalidKansujiInput;
        return allocator.dupe(u8, source);
    }
    const exponent_marker = std.mem.indexOfAny(u8, source, "eE") orelse {
        if (!kansujiValidDecimal(source)) return error.InvalidKansujiInput;
        return allocator.dupe(u8, source);
    };
    const mantissa = source[0..exponent_marker];
    const exponent_text = source[exponent_marker + 1 ..];
    if (!kansujiValidExponentMantissa(mantissa) or exponent_text.len == 0) return error.InvalidKansujiInput;
    var exponent_digits = exponent_text;
    const negative = exponent_digits[0] == '-';
    if (exponent_digits[0] == '+' or exponent_digits[0] == '-') exponent_digits = exponent_digits[1..];
    if (exponent_digits.len == 0 or !kansujiAllAsciiDigits(exponent_digits)) return error.InvalidKansujiInput;
    const exponent = std.fmt.parseInt(i64, exponent_digits, 10) catch return error.KansujiTooLarge;
    const point = std.mem.indexOfScalar(u8, mantissa, '.') orelse mantissa.len;
    const moved = if (negative) @as(i64, @intCast(point)) - exponent else @as(i64, @intCast(point)) + exponent;
    if (moved > 1_000_000 or moved < -1_000_000) return error.KansujiTooLarge;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    if (moved <= 0) {
        try output.appendSlice(allocator, "0.");
        try output.appendNTimes(allocator, '0', @intCast(-moved));
        for (mantissa) |byte| if (byte != '.') try output.append(allocator, byte);
    } else if (@as(i64, @intCast(mantissa.len - point)) > moved) {
        for (mantissa) |byte| if (byte != '.') try output.append(allocator, byte);
        try output.insert(allocator, @intCast(moved), '.');
    } else if (std.mem.indexOfScalar(u8, mantissa, '.') != null) {
        for (mantissa) |byte| if (byte != '.') try output.append(allocator, byte);
        try output.appendNTimes(allocator, '0', @intCast(moved - @as(i64, @intCast(mantissa.len)) + @as(i64, @intCast(point))));
    } else {
        try output.appendSlice(allocator, mantissa);
        try output.appendNTimes(allocator, '0', @intCast(moved - @as(i64, @intCast(mantissa.len)) + @as(i64, @intCast(point)) - 1));
    }
    return output.toOwnedSlice(allocator);
}

pub fn kansujiValidExponentMantissa(source: []const u8) bool {
    if (source.len == 0) return false;
    var index: usize = 0;
    while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) {}
    const whole_digits = index;
    if (index == source.len) return whole_digits > 0;
    if (source[index] != '.') return false;
    index += 1;
    const fraction_start = index;
    while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) {}
    return index == source.len and index > fraction_start;
}

pub fn kansujiValidDecimal(source: []const u8) bool {
    if (source.len == 0) return false;
    var index: usize = 0;
    if (source[index] == '+' or source[index] == '-') index += 1;
    var digits: usize = 0;
    while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) digits += 1;
    if (index < source.len and source[index] == '.') {
        index += 1;
        while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) digits += 1;
    }
    return digits > 0 and index == source.len;
}

pub fn kansujiIsJsNumberString(source: []const u8) bool {
    const trimmed = kansujiTrimJsWhitespace(source);
    if (trimmed.len == 0) return true;
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity") or std.mem.eql(u8, trimmed, "-Infinity")) return true;
    if (kansujiValidDecimal(trimmed)) return true;
    if (std.mem.indexOfAny(u8, trimmed, "eE")) |marker| {
        if (!kansujiValidDecimal(trimmed[0..marker])) return false;
        var rest = trimmed[marker + 1 ..];
        if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) rest = rest[1..];
        return rest.len > 0 and kansujiAllAsciiDigits(rest);
    }
    if (trimmed.len > 2 and trimmed[0] == '0') {
        const radix: u8 = switch (trimmed[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => return false,
        };
        for (trimmed[2..]) |byte| {
            const digit = std.fmt.charToDigit(byte, radix) catch return false;
            if (digit >= radix) return false;
        }
        return true;
    }
    return false;
}

pub fn kansujiTrimJsWhitespace(source: []const u8) []const u8 {
    var start: usize = 0;
    while (start < source.len) {
        const length = std.unicode.utf8ByteSequenceLength(source[start]) catch break;
        if (start + length > source.len) break;
        const codepoint = std.unicode.utf8Decode(source[start .. start + length]) catch break;
        if (!kansujiIsJsWhitespace(codepoint)) break;
        start += length;
    }
    var end = source.len;
    while (end > start) {
        var codepoint_start = end - 1;
        while (codepoint_start > start and source[codepoint_start] & 0xc0 == 0x80) codepoint_start -= 1;
        const codepoint = std.unicode.utf8Decode(source[codepoint_start..end]) catch break;
        if (!kansujiIsJsWhitespace(codepoint)) break;
        end = codepoint_start;
    }
    return source[start..end];
}

pub fn kansujiIsJsWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000d, 0x0020, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}

pub fn kansujiKanjiDigit(unit: u16) []const u8 {
    return if (unit >= '0' and unit <= '9') kansujiBasicKanji[unit - '0'] else "undefined";
}

pub fn kansujiAllAsciiDigits(source: []const u8) bool {
    for (source) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

pub fn kansujiAllAsciiDigitUnits(source: []const u16) bool {
    for (source) |unit| if (unit < '0' or unit > '9') return false;
    return true;
}

pub fn urlEncodeBuiltin(runtime: *Runtime, source: Value) !Value {
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);

    var index: usize = 0;
    while (index < units.len) {
        const first = units[index];
        const codepoint: u21 = switch (first) {
            0xd800...0xdbff => blk: {
                if (index + 1 >= units.len) return error.MalformedUriSequence;
                const second = units[index + 1];
                if (second < 0xdc00 or second > 0xdfff) return error.MalformedUriSequence;
                index += 1;
                break :blk @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
            },
            0xdc00...0xdfff => return error.MalformedUriSequence,
            else => @intCast(first),
        };
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(codepoint, &encoded);
        for (encoded[0..length]) |byte| {
            if (urlIsComponentByte(byte)) {
                try output.append(runtime.allocator, byte);
            } else {
                try output.appendSlice(runtime.allocator, &.{ '%', urlHexDigit(byte >> 4), urlHexDigit(byte & 0xf) });
            }
        }
        index += 1;
    }
    return runtimeUtf8String(runtime, output.items);
}

pub fn urlDecodeBuiltin(runtime: *Runtime, source: Value) !Value {
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    return urlDecodeUnits(runtime, units);
}

pub fn urlDecodeUnits(runtime: *Runtime, units: []const u16) !Value {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        if (unit == '%') {
            if (index + 2 >= units.len) return error.MalformedUriSequence;
            const high = urlHexValue(units[index + 1]) orelse return error.MalformedUriSequence;
            const low = urlHexValue(units[index + 2]) orelse return error.MalformedUriSequence;
            try output.append(runtime.allocator, high << 4 | low);
            index += 3;
            continue;
        }
        if (unit > 0x7f) {
            var codepoint: u21 = undefined;
            if (unit >= 0xd800 and unit <= 0xdbff) {
                if (index + 1 >= units.len or units[index + 1] < 0xdc00 or units[index + 1] > 0xdfff) return error.MalformedUriSequence;
                const second = units[index + 1];
                codepoint = @intCast(0x10000 + ((@as(u32, unit) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
                index += 2;
            } else if (unit >= 0xdc00 and unit <= 0xdfff) {
                return error.MalformedUriSequence;
            } else {
                codepoint = @intCast(unit);
                index += 1;
            }
            var encoded: [4]u8 = undefined;
            const length = try std.unicode.utf8Encode(codepoint, &encoded);
            try output.appendSlice(runtime.allocator, encoded[0..length]);
            continue;
        }
        try output.append(runtime.allocator, @intCast(unit));
        index += 1;
    }
    if (!std.unicode.utf8ValidateSlice(output.items)) return error.MalformedUriSequence;
    return runtimeUtf8String(runtime, output.items);
}

pub fn urlParametersBuiltin(runtime: *Runtime, source: Value) !Value {
    var protected = [_]Value{ source, try runtime.createDictionary(&.{}) };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &protected, protected.len);
    defer runtime.popRoots(&frame);
    if (!isString(protected[0])) return protected[1];
    const units = try valueUtf16Alloc(runtime, protected[0]);
    defer runtime.allocator.free(units);
    const question = std.mem.indexOfScalar(u16, units, '?') orelse return protected[1];
    var cursor = question + 1;
    while (cursor <= units.len) {
        const ampersand = std.mem.indexOfScalarPos(u16, units, cursor, '&') orelse units.len;
        const line = units[cursor..ampersand];
        if (line.len > 0) {
            const equal = std.mem.indexOfScalar(u16, line, '=');
            const raw_key = if (equal) |position| line[0..position] else line;
            const raw_value = if (equal) |position| line[position + 1 ..] else &.{};
            var entry = [_]Value{ .{}, .{} };
            var entry_frame = RootFrame{};
            runtime.pushRoots(&entry_frame, &entry, entry.len);
            defer runtime.popRoots(&entry_frame);
            entry[0] = try urlDecodeUnits(runtime, raw_key);
            entry[1] = try urlDecodeUnits(runtime, raw_value);
            try runtime.setDictionary(&protected[1].object().?.payload.dictionary, entry[0], entry[1]);
        }
        if (ampersand == units.len) break;
        cursor = ampersand + 1;
    }
    return protected[1];
}

pub fn base64EncodeBuiltin(runtime: *Runtime, source: Value) !Value {
    var bytes: []u8 = undefined;
    var owned = false;
    switch (@as(Tag, @enumFromInt(source.tag))) {
        .static_utf8_string, .utf16_string => {
            const units = try valueUtf16Alloc(runtime, source);
            defer runtime.allocator.free(units);
            bytes = try (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
            owned = true;
        },
        .byte_buffer => bytes = source.object().?.payload.byte_buffer.bytes,
        .array => {
            const items = source.object().?.payload.array.items;
            bytes = try runtime.allocator.alloc(u8, items.len);
            owned = true;
            for (items, bytes) |item, *byte| {
                const number = try valueToNumberRuntime(runtime, item);
                if (!std.math.isFinite(number) or number == 0) {
                    byte.* = 0;
                } else {
                    const remainder = @mod(@trunc(number), @as(f64, 256));
                    byte.* = @intFromFloat(if (remainder < 0) remainder + 256 else remainder);
                }
            }
        },
        else => return error.InvalidBase64Source,
    }
    defer if (owned) runtime.allocator.free(bytes);
    const encoded = try runtime.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    defer runtime.allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return runtimeUtf8String(runtime, encoded);
}

pub fn base64DecodeBuiltin(runtime: *Runtime, source: Value) !Value {
    if (!isString(source)) return error.InvalidBase64Source;
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(runtime.allocator);
    var group: [4]u8 = undefined;
    var length: usize = 0;
    for (units) |unit| {
        if (unit == '=') break;
        const value = base64Digit(unit) orelse continue;
        group[length] = value;
        length += 1;
        if (length == 4) {
            try decoded.appendSlice(runtime.allocator, &.{
                group[0] << 2 | group[1] >> 4,
                group[1] << 4 | group[2] >> 2,
                group[2] << 6 | group[3],
            });
            length = 0;
        }
    }
    if (length >= 2) try decoded.append(runtime.allocator, group[0] << 2 | group[1] >> 4);
    if (length >= 3) try decoded.append(runtime.allocator, group[1] << 4 | group[2] >> 2);
    return runtimeUtf8StringLossy(runtime, decoded.items);
}

pub fn urlIsComponentByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
        else => false,
    };
}

pub fn urlHexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + value - 10;
}

pub fn urlHexValue(unit: u16) ?u8 {
    if (unit >= '0' and unit <= '9') return @intCast(unit - '0');
    if (unit >= 'a' and unit <= 'f') return @intCast(unit - 'a' + 10);
    if (unit >= 'A' and unit <= 'F') return @intCast(unit - 'A' + 10);
    return null;
}

pub fn base64Digit(unit: u16) ?u8 {
    return switch (unit) {
        'A'...'Z' => @intCast(unit - 'A'),
        'a'...'z' => @intCast(unit - 'a' + 26),
        '0'...'9' => @intCast(unit - '0' + 52),
        '+', '-' => 62,
        '/', '_' => 63,
        else => null,
    };
}

pub fn csvBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    return switch (command) {
        .csv_parse => blk: {
            runtime.csv_state.useDelimiter(runtime.allocator, .comma);
            break :blk try csvParse(runtime, &runtime.csv_state, arguments[0]);
        },
        .tsv_parse => blk: {
            runtime.csv_state.useDelimiter(runtime.allocator, .tab);
            break :blk try csvParse(runtime, &runtime.csv_state, arguments[0]);
        },
        .table_csv_stringify, .csv_stringify => blk: {
            runtime.csv_state.useDelimiter(runtime.allocator, .comma);
            break :blk try csvStringify(runtime, &runtime.csv_state, arguments[0]);
        },
        .table_tsv_stringify, .tsv_stringify => blk: {
            runtime.csv_state.useDelimiter(runtime.allocator, .tab);
            break :blk try csvStringify(runtime, &runtime.csv_state, arguments[0]);
        },
        .csv_options => blk: {
            try csvSetOptions(runtime, &runtime.csv_state, arguments[0]);
            break :blk .{};
        },
        else => error.UnknownCommand,
    };
}

pub fn csvParse(runtime: *Runtime, state: *const AotCsvState, source: Value) !Value {
    var rooted = [_]Value{ source, .{}, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);

    const source_units = try valueUtf16Alloc(runtime, rooted[0]);
    defer runtime.allocator.free(source_units);
    var normalized: std.ArrayList(u16) = .empty;
    defer normalized.deinit(runtime.allocator);
    var input_index: usize = 0;
    while (input_index < source_units.len) : (input_index += 1) {
        const unit = source_units[input_index];
        if (unit == '\r') {
            if (input_index + 1 < source_units.len and source_units[input_index + 1] == '\n') input_index += 1;
            try normalized.append(runtime.allocator, '\n');
        } else try normalized.append(runtime.allocator, unit);
    }
    while (normalized.items.len > 0 and csvIsWhitespace(normalized.items[normalized.items.len - 1])) _ = normalized.pop();
    try normalized.append(runtime.allocator, '\n');

    rooted[1] = try runtime.createArray(&.{});
    rooted[2] = try runtime.createArray(&.{});
    const delimiter = if (state.delimiter().len > 0) state.delimiter()[0] else ',';
    var cursor: usize = 0;
    while (cursor < normalized.items.len) {
        var current = normalized.items[cursor];
        if (current == delimiter) {
            try csvAppendCell(runtime, &rooted[2].object().?.payload.array, &.{}, state.auto_convert_number);
            cursor += 1;
            continue;
        }
        if (current == '\n') {
            try csvAppendCell(runtime, &rooted[2].object().?.payload.array, &.{}, state.auto_convert_number);
            try rooted[1].object().?.payload.array.append(runtime.allocator, rooted[2]);
            rooted[2] = try runtime.createArray(&.{});
            cursor += 1;
            continue;
        }
        while (cursor < normalized.items.len and csvIsWhitespace(normalized.items[cursor]) and normalized.items[cursor] != '\n') cursor += 1;
        if (cursor >= normalized.items.len) break;
        current = normalized.items[cursor];
        if (current == delimiter) {
            try csvAppendCell(runtime, &rooted[2].object().?.payload.array, &.{}, state.auto_convert_number);
            cursor += 1;
            continue;
        }
        if (current == '=' and cursor + 1 < normalized.items.len and normalized.items[cursor + 1] == '"') {
            cursor += 1;
            current = '"';
        }
        if (current != '"') {
            const start = cursor;
            while (cursor < normalized.items.len and normalized.items[cursor] != delimiter and normalized.items[cursor] != '\n') cursor += 1;
            try csvAppendCell(runtime, &rooted[2].object().?.payload.array, normalized.items[start..cursor], state.auto_convert_number);
            if (cursor < normalized.items.len and normalized.items[cursor] == '\n') {
                try rooted[1].object().?.payload.array.append(runtime.allocator, rooted[2]);
                rooted[2] = try runtime.createArray(&.{});
            }
            cursor += 1;
            continue;
        }
        if (cursor + 1 < normalized.items.len and normalized.items[cursor + 1] == '"') {
            try csvAppendCell(runtime, &rooted[2].object().?.payload.array, &.{}, state.auto_convert_number);
            cursor += 2;
            continue;
        }
        cursor += 1;
        var quoted: std.ArrayList(u16) = .empty;
        defer quoted.deinit(runtime.allocator);
        while (cursor < normalized.items.len) {
            const first = normalized.items[cursor];
            const second = if (cursor + 1 < normalized.items.len) normalized.items[cursor + 1] else 0;
            if (first == '"' and second == '"') {
                try quoted.append(runtime.allocator, '"');
                cursor += 2;
                continue;
            }
            if (first == '"') {
                cursor += 1;
                if (second == delimiter) {
                    cursor += 1;
                    try csvAppendCell(runtime, &rooted[2].object().?.payload.array, quoted.items, state.auto_convert_number);
                    break;
                }
                if (second == '\n') {
                    cursor += 1;
                    try csvAppendCell(runtime, &rooted[2].object().?.payload.array, quoted.items, state.auto_convert_number);
                    try rooted[1].object().?.payload.array.append(runtime.allocator, rooted[2]);
                    rooted[2] = try runtime.createArray(&.{});
                    break;
                }
                if (cursor < normalized.items.len) cursor += 1;
                continue;
            }
            try quoted.append(runtime.allocator, first);
            cursor += 1;
        }
    }
    if (rooted[2].object().?.payload.array.items.len > 0) try rooted[1].object().?.payload.array.append(runtime.allocator, rooted[2]);
    return rooted[1];
}

pub fn csvAppendCell(runtime: *Runtime, row: *std.ArrayList(Value), units: []const u16, auto_convert: bool) !void {
    if (auto_convert and csvIsNumeric(units)) {
        var ascii = try runtime.allocator.alloc(u8, units.len);
        defer runtime.allocator.free(ascii);
        for (units, 0..) |unit, index| ascii[index] = @intCast(unit);
        try row.append(runtime.allocator, numberValue(std.fmt.parseFloat(f64, ascii) catch std.math.nan(f64)));
        return;
    }
    try row.append(runtime.allocator, try runtime.createString(units));
}

pub fn csvStringify(runtime: *Runtime, state: *const AotCsvState, source: Value) !Value {
    if (source.tag == @intFromEnum(Tag.undefined)) return runtime.createString(&.{});
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    var rooted = [_]Value{ source, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);

    var raw: std.ArrayList(u16) = .empty;
    defer raw.deinit(runtime.allocator);
    const delimiter = state.delimiter();
    for (rooted[0].object().?.payload.array.items) |row| {
        if (row.tag == @intFromEnum(Tag.undefined)) {
            try raw.appendSlice(runtime.allocator, state.eol());
            continue;
        }
        if (row.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
        const row_object = row.object().?;
        for (row_object.payload.array.items, 0..) |cell, column| {
            if (column > 0) try raw.appendSlice(runtime.allocator, delimiter);
            rooted[1] = try csvQuoteCell(runtime, cell, delimiter);
            row_object.payload.array.items[column] = rooted[1];
            try raw.appendSlice(runtime.allocator, rooted[1].object().?.payload.utf16_string);
        }
        try raw.appendSlice(runtime.allocator, state.eol());
    }

    var normalized: std.ArrayList(u16) = .empty;
    defer normalized.deinit(runtime.allocator);
    var index: usize = 0;
    while (index < raw.items.len) : (index += 1) {
        if (raw.items[index] == '\r') {
            if (index + 1 < raw.items.len and raw.items[index + 1] == '\n') index += 1;
            try normalized.appendSlice(runtime.allocator, state.eol());
        } else if (raw.items[index] == '\n') {
            try normalized.appendSlice(runtime.allocator, state.eol());
        } else try normalized.append(runtime.allocator, raw.items[index]);
    }
    return runtime.createString(normalized.items);
}

pub fn csvQuoteCell(runtime: *Runtime, source: Value, delimiter: []const u16) !Value {
    const text = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(text);
    const needs_quote = std.mem.indexOfScalar(u16, text, '\n') != null or
        std.mem.indexOfScalar(u16, text, '\r') != null or
        (delimiter.len > 0 and std.mem.indexOf(u16, text, delimiter) != null) or
        std.mem.indexOfScalar(u16, text, '"') != null;
    if (!needs_quote) return runtime.createString(text);
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator);
    try output.append(runtime.allocator, '"');
    for (text) |unit| {
        if (unit == '"') try output.append(runtime.allocator, '"');
        try output.append(runtime.allocator, unit);
    }
    try output.append(runtime.allocator, '"');
    return runtime.createString(output.items);
}

pub fn csvSetOptions(runtime: *Runtime, state: *AotCsvState, source: Value) !void {
    if (source.tag != @intFromEnum(Tag.dictionary)) return;
    for (source.object().?.payload.dictionary.items) |entry| {
        const key_units = try valueUtf16Alloc(runtime, entry.key);
        defer runtime.allocator.free(key_units);
        const key = try std.unicode.utf16LeToUtf8Alloc(runtime.allocator, key_units);
        defer runtime.allocator.free(key);
        if (std.mem.eql(u8, key, "delimiter") or std.mem.eql(u8, key, "区切文字")) {
            const value_units = try valueUtf16Alloc(runtime, entry.value);
            defer runtime.allocator.free(value_units);
            try state.setDelimiter(runtime.allocator, value_units);
        } else if (std.mem.eql(u8, key, "eol")) {
            const value_units = try valueUtf16Alloc(runtime, entry.value);
            defer runtime.allocator.free(value_units);
            try state.setEol(runtime.allocator, value_units);
        } else if (std.mem.eql(u8, key, "auto_convert_number")) state.auto_convert_number = valueTruthy(entry.value);
    }
}

pub fn csvIsNumeric(units: []const u16) bool {
    if (units.len == 0) return false;
    var index: usize = 0;
    if (units[index] == '-') index += 1;
    const integer_start = index;
    while (index < units.len and units[index] >= '0' and units[index] <= '9') index += 1;
    if (index == integer_start) return false;
    if (index < units.len and units[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < units.len and units[index] >= '0' and units[index] <= '9') index += 1;
        if (index == fraction_start) return false;
    }
    if (index < units.len and (units[index] == 'e' or units[index] == 'E')) {
        index += 1;
        if (index < units.len and (units[index] == '-' or units[index] == '+')) index += 1;
        const exponent_start = index;
        while (index < units.len and units[index] >= '0' and units[index] <= '9') index += 1;
        if (index == exponent_start) return false;
    }
    return index == units.len;
}

pub fn csvIsWhitespace(unit: u16) bool {
    return switch (unit) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x00a0, 0x3000 => true,
        else => false,
    };
}

pub fn tomlBuiltin(runtime: *Runtime, command: aot_builtin.Command, value: Value) !Value {
    return switch (command) {
        .toml_parse => tomlParse(runtime, value),
        .toml_stringify => tomlStringify(runtime, value),
        else => error.UnknownCommand,
    };
}

pub fn tomlParse(runtime: *Runtime, source: Value) !Value {
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    const input = try (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
    defer runtime.allocator.free(input);
    var parser = TomlAotParser{ .runtime = runtime, .input = input };
    return parser.document();
}

const TomlAotTerminator = enum { equal, bracket, double_bracket };

const TomlAotKeyPath = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *TomlAotKeyPath) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }
};

const TomlAotParser = struct {
    runtime: *Runtime,
    input: []const u8,
    index: usize = 0,

    pub fn document(self: *TomlAotParser) !Value {
        var result = try self.runtime.createDictionary(&.{});
        var roots = RootFrame{};
        self.runtime.pushRoots(&roots, @ptrCast(&result), 1);
        defer self.runtime.popRoots(&roots);
        var current = result;
        while (true) {
            self.skipDocumentSpace();
            if (self.index >= self.input.len) break;
            if (self.input[self.index] == '[') {
                const array_table = self.index + 1 < self.input.len and self.input[self.index + 1] == '[';
                self.index += if (array_table) 2 else 1;
                var path = try self.keyPath(if (array_table) .double_bracket else .bracket);
                defer path.deinit();
                current = try self.table(result, path.items.items, array_table);
            } else {
                var path = try self.keyPath(.equal);
                defer path.deinit();
                var parsed_value = try self.value();
                var value_roots = RootFrame{};
                self.runtime.pushRoots(&value_roots, @ptrCast(&parsed_value), 1);
                defer self.runtime.popRoots(&value_roots);
                try self.assign(current, path.items.items, parsed_value);
            }
            self.skipHorizontal();
            if (self.index < self.input.len and self.input[self.index] == '#') self.skipComment();
            if (self.index < self.input.len and self.input[self.index] != '\n' and self.input[self.index] != '\r') return error.InvalidTomlDocument;
        }
        return result;
    }

    pub fn keyPath(self: *TomlAotParser, terminator: TomlAotTerminator) !TomlAotKeyPath {
        var result = TomlAotKeyPath{ .allocator = self.runtime.allocator };
        errdefer result.deinit();
        while (true) {
            self.skipHorizontal();
            if (self.index >= self.input.len) return error.InvalidTomlKey;
            const key = if (self.input[self.index] == '"' or self.input[self.index] == '\'')
                try self.stringBytes(self.input[self.index], false)
            else blk: {
                const start = self.index;
                while (self.index < self.input.len and tomlAotIsBareKey(self.input[self.index])) self.index += 1;
                if (start == self.index) return error.InvalidTomlKey;
                break :blk try self.runtime.allocator.dupe(u8, self.input[start..self.index]);
            };
            try result.items.append(self.runtime.allocator, key);
            self.skipHorizontal();
            if (self.index < self.input.len and self.input[self.index] == '.') {
                self.index += 1;
                continue;
            }
            switch (terminator) {
                .equal => {
                    if (!self.consume('=')) return error.InvalidTomlKey;
                },
                .bracket => {
                    if (!self.consume(']')) return error.InvalidTomlTable;
                },
                .double_bracket => {
                    if (!self.consume(']') or !self.consume(']')) return error.InvalidTomlTable;
                },
            }
            if (result.items.items.len == 0) return error.InvalidTomlKey;
            return result;
        }
    }

    pub fn value(self: *TomlAotParser) anyerror!Value {
        self.skipHorizontal();
        if (self.index >= self.input.len) return error.InvalidTomlValue;
        return switch (self.input[self.index]) {
            '"' => self.stringValue('"'),
            '\'' => self.stringValue('\''),
            '[' => self.array(),
            '{' => self.inlineTable(),
            else => self.bareValue(),
        };
    }

    pub fn stringValue(self: *TomlAotParser, quote: u8) !Value {
        const multiline = self.index + 2 < self.input.len and self.input[self.index + 1] == quote and self.input[self.index + 2] == quote;
        const bytes = try self.stringBytes(quote, multiline);
        defer self.runtime.allocator.free(bytes);
        return runtimeUtf8String(self.runtime, bytes);
    }

    pub fn stringBytes(self: *TomlAotParser, quote: u8, multiline: bool) ![]u8 {
        self.index += if (multiline) 3 else 1;
        if (multiline) {
            if (self.consume('\r')) _ = self.consume('\n') else _ = self.consume('\n');
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.runtime.allocator);
        while (self.index < self.input.len) {
            if (multiline) {
                if (self.index + 2 < self.input.len and self.input[self.index] == quote and self.input[self.index + 1] == quote and self.input[self.index + 2] == quote) {
                    self.index += 3;
                    return output.toOwnedSlice(self.runtime.allocator);
                }
            } else if (self.input[self.index] == quote) {
                self.index += 1;
                return output.toOwnedSlice(self.runtime.allocator);
            }
            const byte = self.input[self.index];
            self.index += 1;
            if (!multiline and (byte == '\n' or byte == '\r')) return error.UnterminatedTomlString;
            if (quote == '\'' or byte != '\\') {
                try output.append(self.runtime.allocator, byte);
                continue;
            }
            if (self.index >= self.input.len) return error.UnterminatedTomlString;
            const escaped = self.input[self.index];
            self.index += 1;
            switch (escaped) {
                'b' => try output.append(self.runtime.allocator, 0x08),
                't' => try output.append(self.runtime.allocator, '\t'),
                'n' => try output.append(self.runtime.allocator, '\n'),
                'f' => try output.append(self.runtime.allocator, 0x0c),
                'r' => try output.append(self.runtime.allocator, '\r'),
                '"' => try output.append(self.runtime.allocator, '"'),
                '\\' => try output.append(self.runtime.allocator, '\\'),
                'u' => try self.appendUnicode(&output, 4),
                'U' => try self.appendUnicode(&output, 8),
                '\n', '\r' => if (multiline) {
                    if (escaped == '\r') _ = self.consume('\n');
                    while (self.index < self.input.len and (self.input[self.index] == ' ' or self.input[self.index] == '\t' or self.input[self.index] == '\n' or self.input[self.index] == '\r')) self.index += 1;
                } else return error.InvalidTomlEscape,
                else => return error.InvalidTomlEscape,
            }
        }
        return error.UnterminatedTomlString;
    }

    pub fn appendUnicode(self: *TomlAotParser, output: *std.ArrayList(u8), digits: usize) !void {
        if (self.index + digits > self.input.len) return error.InvalidTomlEscape;
        const codepoint = std.fmt.parseInt(u21, self.input[self.index .. self.index + digits], 16) catch return error.InvalidTomlEscape;
        self.index += digits;
        if (!std.unicode.utf8ValidCodepoint(codepoint) or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return error.InvalidTomlEscape;
        var buffer: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(codepoint, &buffer);
        try output.appendSlice(self.runtime.allocator, buffer[0..length]);
    }

    pub fn array(self: *TomlAotParser) !Value {
        self.index += 1;
        var result = try self.runtime.createArray(&.{});
        var roots = RootFrame{};
        self.runtime.pushRoots(&roots, @ptrCast(&result), 1);
        defer self.runtime.popRoots(&roots);
        self.skipValueSpace();
        if (self.consume(']')) return result;
        while (true) {
            const item = try self.value();
            try result.object().?.payload.array.append(self.runtime.allocator, item);
            self.skipValueSpace();
            if (self.consume(']')) return result;
            if (!self.consume(',')) return error.InvalidTomlArray;
            self.skipValueSpace();
            if (self.consume(']')) return result;
        }
    }

    pub fn inlineTable(self: *TomlAotParser) !Value {
        self.index += 1;
        var result = try self.runtime.createDictionary(&.{});
        var roots = RootFrame{};
        self.runtime.pushRoots(&roots, @ptrCast(&result), 1);
        defer self.runtime.popRoots(&roots);
        self.skipHorizontal();
        if (self.consume('}')) return result;
        while (true) {
            var path = try self.keyPath(.equal);
            defer path.deinit();
            var item = try self.value();
            var item_roots = RootFrame{};
            self.runtime.pushRoots(&item_roots, @ptrCast(&item), 1);
            defer self.runtime.popRoots(&item_roots);
            try self.assign(result, path.items.items, item);
            self.skipHorizontal();
            if (self.consume('}')) return result;
            if (!self.consume(',')) return error.InvalidTomlInlineTable;
            self.skipHorizontal();
        }
    }

    pub fn bareValue(self: *TomlAotParser) !Value {
        const start = self.index;
        while (self.index < self.input.len) {
            const byte = self.input[self.index];
            if (byte == ' ' and self.index == start + 10 and toml_temporal.hasDatePrefix(self.input[start..]) and self.index + 1 < self.input.len and std.ascii.isDigit(self.input[self.index + 1])) {
                self.index += 1;
                continue;
            }
            if (byte == ',' or byte == ']' or byte == '}' or byte == '#' or byte == '\n' or byte == '\r' or byte == ' ' or byte == '\t') break;
            self.index += 1;
        }
        if (start == self.index) return error.InvalidTomlValue;
        const token = self.input[start..self.index];
        if (std.mem.eql(u8, token, "true")) return .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 };
        if (std.mem.eql(u8, token, "false")) return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
        if (std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "+inf")) return numberValue(std.math.inf(f64));
        if (std.mem.eql(u8, token, "-inf")) return numberValue(-std.math.inf(f64));
        if (std.mem.eql(u8, token, "nan") or std.mem.eql(u8, token, "+nan")) return numberValue(std.math.nan(f64));
        if (std.mem.eql(u8, token, "-nan")) return numberValue(-std.math.nan(f64));
        if (try toml_temporal.normalize(self.runtime.allocator, token)) |normalized_value| {
            var normalized = normalized_value;
            defer normalized.deinit();
            return self.runtime.createTomlTemporal(normalized.kind, normalized.text, normalized.text);
        }
        if (toml_temporal.looksLikeTemporal(token)) return runtimeUtf8String(self.runtime, token);
        const normalized = try tomlAotRemoveUnderscores(self.runtime.allocator, token);
        defer self.runtime.allocator.free(normalized);
        if (tomlAotParseInteger(normalized)) |integer| return numberValue(integer) else |_| {}
        const number = std.fmt.parseFloat(f64, normalized) catch return error.InvalidTomlValue;
        return numberValue(number);
    }

    pub fn table(self: *TomlAotParser, root: Value, path: []const []const u8, array_table: bool) !Value {
        var current = root;
        for (path, 0..) |segment, index| {
            const last = index + 1 == path.len;
            const existing = try tomlAotDictionaryGet(self.runtime, current.object().?.payload.dictionary.items, segment);
            if (last and array_table) {
                var array_value = existing orelse blk: {
                    const created = try self.runtime.createArray(&.{});
                    try tomlAotPut(self.runtime, current, segment, created);
                    break :blk created;
                };
                if (array_value.tag != @intFromEnum(Tag.array)) return error.InvalidTomlTable;
                const table_value = try self.runtime.createDictionary(&.{});
                var table_roots = [_]Value{ array_value, table_value };
                var roots = RootFrame{};
                self.runtime.pushRoots(&roots, &table_roots, table_roots.len);
                defer self.runtime.popRoots(&roots);
                try array_value.object().?.payload.array.append(self.runtime.allocator, table_value);
                return table_value;
            }
            if (existing) |found| {
                if (tomlAotIsTableDictionary(found)) {
                    current = found;
                } else if (tomlAotLastArrayDictionary(found)) |last_table| {
                    current = last_table;
                } else return error.InvalidTomlTable;
            } else {
                const created = try self.runtime.createDictionary(&.{});
                try tomlAotPut(self.runtime, current, segment, created);
                current = created;
            }
        }
        return current;
    }

    pub fn assign(self: *TomlAotParser, base: Value, path: []const []const u8, assigned_value: Value) !void {
        if (path.len == 0) return error.InvalidTomlKey;
        var current = base;
        for (path[0 .. path.len - 1]) |segment| {
            if (try tomlAotDictionaryGet(self.runtime, current.object().?.payload.dictionary.items, segment)) |found| {
                if (!tomlAotIsTableDictionary(found)) return error.InvalidTomlKey;
                current = found;
            } else {
                const created = try self.runtime.createDictionary(&.{});
                try tomlAotPut(self.runtime, current, segment, created);
                current = created;
            }
        }
        if (try tomlAotDictionaryGet(self.runtime, current.object().?.payload.dictionary.items, path[path.len - 1]) != null) return error.DuplicateTomlKey;
        try tomlAotPut(self.runtime, current, path[path.len - 1], assigned_value);
    }

    pub fn skipDocumentSpace(self: *TomlAotParser) void {
        while (self.index < self.input.len) switch (self.input[self.index]) {
            ' ', '\t', '\n', '\r' => self.index += 1,
            '#' => self.skipComment(),
            else => return,
        };
    }

    pub fn skipValueSpace(self: *TomlAotParser) void {
        while (self.index < self.input.len) switch (self.input[self.index]) {
            ' ', '\t', '\n', '\r' => self.index += 1,
            '#' => self.skipComment(),
            else => return,
        };
    }

    pub fn skipHorizontal(self: *TomlAotParser) void {
        while (self.index < self.input.len and (self.input[self.index] == ' ' or self.input[self.index] == '\t')) self.index += 1;
    }

    pub fn skipComment(self: *TomlAotParser) void {
        while (self.index < self.input.len and self.input[self.index] != '\n') self.index += 1;
    }

    pub fn consume(self: *TomlAotParser, byte: u8) bool {
        if (self.index >= self.input.len or self.input[self.index] != byte) return false;
        self.index += 1;
        return true;
    }
};

pub fn tomlAotDictionaryGet(runtime: *Runtime, entries: []const DictionaryEntry, key: []const u8) !?Value {
    for (entries) |entry| if (try tomlAotKeyEquals(runtime, entry.key, key)) return entry.value;
    return null;
}

pub fn tomlAotKeyEquals(runtime: *Runtime, key: Value, expected: []const u8) !bool {
    const actual = try tomlAotValueUtf8Alloc(runtime, key);
    defer runtime.allocator.free(actual);
    return std.mem.eql(u8, actual, expected);
}

pub fn tomlAotPut(runtime: *Runtime, dictionary: Value, key: []const u8, value: Value) !void {
    var rooted = [_]Value{ value, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);
    rooted[1] = try runtimeUtf8String(runtime, key);
    try runtime.setDictionary(&dictionary.object().?.payload.dictionary, rooted[1], rooted[0]);
}

pub fn tomlAotParseInteger(token: []const u8) !f64 {
    var sign: f64 = 1;
    var digits = token;
    if (digits.len > 0 and (digits[0] == '+' or digits[0] == '-')) {
        if (digits[0] == '-') sign = -1;
        digits = digits[1..];
    }
    var radix: u8 = 10;
    if (digits.len > 2 and digits[0] == '0') switch (digits[1]) {
        'x' => radix = 16,
        'o' => radix = 8,
        'b' => radix = 2,
        else => {},
    };
    if (radix != 10) digits = digits[2..];
    if (digits.len == 0 or (radix == 10 and digits.len > 1 and digits[0] == '0')) return error.InvalidTomlInteger;
    const integer = try std.fmt.parseInt(u64, digits, radix);
    if (integer > 9_007_199_254_740_991) return error.TomlIntegerPrecisionLoss;
    return sign * @as(f64, @floatFromInt(integer));
}

pub fn tomlAotRemoveUnderscores(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (token, 0..) |byte, index| {
        if (byte != '_') {
            try output.append(allocator, byte);
            continue;
        }
        if (index == 0 or index + 1 == token.len or !std.ascii.isAlphanumeric(token[index - 1]) or !std.ascii.isAlphanumeric(token[index + 1])) return error.InvalidTomlNumber;
    }
    return output.toOwnedSlice(allocator);
}

pub fn tomlAotIsBareKey(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

pub fn tomlAotLastArrayDictionary(value: Value) ?Value {
    if (value.tag != @intFromEnum(Tag.array)) return null;
    const object = value.object() orelse return null;
    if (object.payload != .array or object.payload.array.items.len == 0) return null;
    const item = object.payload.array.items[object.payload.array.items.len - 1];
    return if (tomlAotIsTableDictionary(item)) item else null;
}

pub fn tomlAotIsTableDictionary(value: Value) bool {
    if (value.tag != @intFromEnum(Tag.dictionary)) return false;
    return value.object().?.toml_temporal == null;
}

pub fn tomlStringify(runtime: *Runtime, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.dictionary)) return error.DictionaryExpected;
    var rooted_source = source;
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&rooted_source), 1);
    defer runtime.popRoots(&roots);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);
    var active_dictionaries: std.AutoHashMapUnmanaged(*Object, void) = .empty;
    defer active_dictionaries.deinit(runtime.allocator);
    var active_arrays: std.AutoHashMapUnmanaged(*Object, void) = .empty;
    defer active_arrays.deinit(runtime.allocator);
    var path: std.ArrayList(Value) = .empty;
    defer path.deinit(runtime.allocator);
    try tomlAotWriteTable(runtime, &output, rooted_source.object().?, &path, false, &active_dictionaries, &active_arrays);
    return runtimeUtf8String(runtime, output.items);
}

pub fn tomlAotWriteTable(runtime: *Runtime, output: *std.ArrayList(u8), dictionary: *Object, path: *std.ArrayList(Value), emit_header: bool, active_dictionaries: *std.AutoHashMapUnmanaged(*Object, void), active_arrays: *std.AutoHashMapUnmanaged(*Object, void)) !void {
    if (active_dictionaries.contains(dictionary)) return error.CircularTomlValue;
    try active_dictionaries.put(runtime.allocator, dictionary, {});
    defer _ = active_dictionaries.remove(dictionary);
    if (emit_header) {
        try tomlAotWriteHeader(runtime, output, path.items, false);
        try output.append(runtime.allocator, '\n');
    }
    for (dictionary.payload.dictionary.items) |entry| {
        if (tomlAotIsTableDictionary(entry.value) or tomlAotIsArrayOfDictionaries(entry.value)) continue;
        try tomlAotWriteKey(runtime, output, entry.key);
        try output.appendSlice(runtime.allocator, " = ");
        try tomlAotWriteValue(runtime, output, entry.value, active_dictionaries, active_arrays);
        try output.append(runtime.allocator, '\n');
    }
    for (dictionary.payload.dictionary.items) |entry| {
        if (!tomlAotIsTableDictionary(entry.value) and !tomlAotIsArrayOfDictionaries(entry.value)) continue;
        if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') try output.append(runtime.allocator, '\n');
        if (output.items.len > 0 and !(output.items.len >= 2 and output.items[output.items.len - 2] == '\n')) try output.append(runtime.allocator, '\n');
        try path.append(runtime.allocator, entry.key);
        defer _ = path.pop();
        if (tomlAotIsTableDictionary(entry.value)) {
            try tomlAotWriteTable(runtime, output, entry.value.object().?, path, true, active_dictionaries, active_arrays);
        } else {
            const array_object = entry.value.object().?;
            if (active_arrays.contains(array_object)) return error.CircularTomlValue;
            try active_arrays.put(runtime.allocator, array_object, {});
            defer _ = active_arrays.remove(array_object);
            for (array_object.payload.array.items, 0..) |item, index| {
                if (!tomlAotIsTableDictionary(item)) return error.UnsupportedTomlValue;
                if (index > 0) try output.append(runtime.allocator, '\n');
                try tomlAotWriteHeader(runtime, output, path.items, true);
                try output.append(runtime.allocator, '\n');
                try tomlAotWriteTable(runtime, output, item.object().?, path, false, active_dictionaries, active_arrays);
            }
        }
    }
}

pub fn tomlAotWriteHeader(runtime: *Runtime, output: *std.ArrayList(u8), path: []const Value, array_table: bool) !void {
    try output.appendSlice(runtime.allocator, if (array_table) "[[" else "[");
    for (path, 0..) |key, index| {
        if (index > 0) try output.append(runtime.allocator, '.');
        try tomlAotWriteKey(runtime, output, key);
    }
    try output.appendSlice(runtime.allocator, if (array_table) "]]" else "]");
}

pub fn tomlAotValueUtf8Alloc(runtime: *Runtime, value: Value) ![]u8 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
}

pub fn tomlAotWriteKey(runtime: *Runtime, output: *std.ArrayList(u8), key: Value) !void {
    const utf8 = try tomlAotValueUtf8Alloc(runtime, key);
    defer runtime.allocator.free(utf8);
    var bare = utf8.len > 0;
    for (utf8) |byte| bare = bare and tomlAotIsBareKey(byte);
    if (bare) return output.appendSlice(runtime.allocator, utf8);
    try tomlAotWriteQuoted(runtime, output, utf8);
}

pub fn tomlAotWriteValue(runtime: *Runtime, output: *std.ArrayList(u8), value: Value, active_dictionaries: *std.AutoHashMapUnmanaged(*Object, void), active_arrays: *std.AutoHashMapUnmanaged(*Object, void)) !void {
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .boolean => try output.appendSlice(runtime.allocator, if (value.payload != 0) "true" else "false"),
        .number => {
            const number: f64 = @bitCast(value.payload);
            if (std.math.isNan(number)) return output.appendSlice(runtime.allocator, "nan");
            if (std.math.isInf(number)) return output.appendSlice(runtime.allocator, if (number < 0) "-inf" else "inf");
            const text = if (std.math.isFinite(number) and @trunc(number) == number and number >= @as(f64, @floatFromInt(std.math.minInt(i64))) and number <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
                try std.fmt.allocPrint(runtime.allocator, "{d}", .{@as(i64, @intFromFloat(number))})
            else
                try std.fmt.allocPrint(runtime.allocator, "{d}", .{number});
            defer runtime.allocator.free(text);
            try output.appendSlice(runtime.allocator, text);
        },
        .static_utf8_string, .utf16_string => {
            const utf8 = try tomlAotValueUtf8Alloc(runtime, value);
            defer runtime.allocator.free(utf8);
            try tomlAotWriteQuoted(runtime, output, utf8);
        },
        .array => {
            const object = value.object() orelse return error.UnsupportedTomlValue;
            if (active_arrays.contains(object)) return error.CircularTomlValue;
            try active_arrays.put(runtime.allocator, object, {});
            defer _ = active_arrays.remove(object);
            try output.appendSlice(runtime.allocator, "[ ");
            for (object.payload.array.items, 0..) |item, index| {
                if (index > 0) try output.appendSlice(runtime.allocator, ", ");
                try tomlAotWriteValue(runtime, output, item, active_dictionaries, active_arrays);
            }
            try output.appendSlice(runtime.allocator, " ]");
        },
        .dictionary => {
            const object = value.object() orelse return error.UnsupportedTomlValue;
            if (object.toml_temporal) |temporal| return output.appendSlice(runtime.allocator, temporal.toml_text);
            if (active_dictionaries.contains(object)) return error.CircularTomlValue;
            try active_dictionaries.put(runtime.allocator, object, {});
            defer _ = active_dictionaries.remove(object);
            try output.appendSlice(runtime.allocator, "{ ");
            for (object.payload.dictionary.items, 0..) |entry, index| {
                if (index > 0) try output.appendSlice(runtime.allocator, ", ");
                try tomlAotWriteKey(runtime, output, entry.key);
                try output.appendSlice(runtime.allocator, " = ");
                try tomlAotWriteValue(runtime, output, entry.value, active_dictionaries, active_arrays);
            }
            try output.appendSlice(runtime.allocator, " }");
        },
        else => return error.UnsupportedTomlValue,
    }
}

pub fn tomlAotWriteQuoted(runtime: *Runtime, output: *std.ArrayList(u8), bytes: []const u8) !void {
    try output.append(runtime.allocator, '"');
    for (bytes) |byte| switch (byte) {
        '\n' => try output.appendSlice(runtime.allocator, "\\n"),
        '\r' => try output.appendSlice(runtime.allocator, "\\r"),
        '\t' => try output.appendSlice(runtime.allocator, "\\t"),
        '\\' => try output.appendSlice(runtime.allocator, "\\\\"),
        '"' => try output.appendSlice(runtime.allocator, "\\\""),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
            const escaped = try std.fmt.allocPrint(runtime.allocator, "\\u{X:0>4}", .{byte});
            defer runtime.allocator.free(escaped);
            try output.appendSlice(runtime.allocator, escaped);
        },
        else => try output.append(runtime.allocator, byte),
    };
    try output.append(runtime.allocator, '"');
}

pub fn tomlAotIsArrayOfDictionaries(value: Value) bool {
    if (value.tag != @intFromEnum(Tag.array)) return false;
    const object = value.object() orelse return false;
    return switch (object.payload) {
        .array => |items| items.items.len > 0 and tomlAotIsTableDictionary(items.items[0]),
        else => false,
    };
}

pub fn markupBuiltin(runtime: *Runtime, command: aot_builtin.Command, value: Value) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const source = try (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
    defer runtime.allocator.free(source);
    const output = switch (command) {
        .markdown_to_html => try markup.markdownUtf8(runtime.allocator, source),
        .html_pretty => try markup.prettyHtmlUtf8(runtime.allocator, source),
        else => return error.UnknownCommand,
    };
    defer runtime.allocator.free(output);
    return runtimeUtf8String(runtime, output);
}

pub fn courtesyBuiltin(runtime: *Runtime, command: aot_builtin.Command) Value {
    switch (command) {
        .courtesy_increment => {
            if (!std.math.isFinite(runtime.courtesy_level) or runtime.courtesy_level == 0) runtime.courtesy_level = 0;
            runtime.courtesy_level += 1;
            return .{};
        },
        .courtesy_begin => {
            runtime.courtesy_level = 0;
            return .{};
        },
        .courtesy_end => {
            runtime.courtesy_level += 100;
            return .{};
        },
        .courtesy_level => {
            if (!std.math.isFinite(runtime.courtesy_level) or runtime.courtesy_level == 0) runtime.courtesy_level = 0;
            return numberValue(runtime.courtesy_level);
        },
        else => unreachable,
    }
}

pub fn systemExecutionBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    switch (command) {
        .system_execute => {
            if (arguments.len == 0) return .{};
            const candidate = arguments[arguments.len - 1];
            if (candidate.tag == @intFromEnum(Tag.function)) return invokeAotCallback(runtime, candidate, null, 0);
            if (isString(candidate)) {
                const callable = try resolveAotCallback(runtime, candidate);
                return invokeAotCallback(runtime, callable, null, 0);
            }
            return candidate;
        },
        .system_await_execute => {
            if (arguments.len < 2) return error.InvalidAwaitArguments;
            var roots = [_]Value{ arguments[0], arguments[1], .{} };
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            roots[0] = try resolveAotCallback(runtime, roots[0]);
            if (roots[1].tag == @intFromEnum(Tag.array)) {
                const call_arguments = try arrayItems(roots[1]);
                const pointer = if (call_arguments.items.len > 0) @as(?[*]const Value, call_arguments.items.ptr) else null;
                roots[2] = try invokeAotCallback(runtime, roots[0], pointer, call_arguments.items.len);
            } else roots[2] = try invokeAotCallback(runtime, roots[0], @ptrCast(&roots[1]), 1);
            roots[2] = try awaitAotPromise(runtime, roots[2]);
            return roots[2];
        },
        else => return error.UnknownCommand,
    }
}

pub fn debugBreakpointWaitBuiltin(
    runtime: *Runtime,
    breakpoints: *Value,
    force_wait: *Value,
    wait_flag: *Value,
    plugin_name: *Value,
    arguments: []const Value,
) !Value {
    const line_value = if (arguments.len > 0) arguments[arguments.len - 1] else Value{};
    const line = try valueToNumberRuntime(runtime, line_value);
    const force = valueTruthy(force_wait.*);
    force_wait.* = numberValue(0);
    var breakpoint_hit = false;
    if (breakpoints.object()) |object| if (object.payload == .array) {
        const line_number = numberValue(line);
        for (object.payload.array.items) |candidate| if (try strictEqual(runtime, candidate, line_number)) {
            breakpoint_hit = true;
            break;
        };
    };
    if (!force and !breakpoint_hit) return numberValue(line);
    if (!(try strictEqual(runtime, plugin_name.*, staticStringValue("メイン")))) return createAotPromise(runtime);

    const line_text = try numberString(runtime.allocator, line);
    defer runtime.allocator.free(line_text);
    const marker = try std.fmt.allocPrint(runtime.allocator, "@__DEBUG_BP_WAIT({s})", .{line_text});
    defer runtime.allocator.free(marker);
    writeBytes(marker, true);

    while (true) {
        const flag = wait_flag.*;
        if (flag.tag == @intFromEnum(Tag.number) and @as(f64, @bitCast(flag.payload)) == 1) {
            wait_flag.* = numberValue(0);
            return numberValue(line);
        }
        try waitAotMilliseconds(runtime, 500);
    }
}

pub fn measureCallableBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len == 0) return error.NotCallable;
    var roots = [_]Value{ arguments[arguments.len - 1], .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try resolveAotCallback(runtime, roots[0]);
    const started = monotonicTimeMilliseconds(runtime);
    roots[2] = try invokeAotCallback(runtime, roots[1], null, 0);
    const finished = monotonicTimeMilliseconds(runtime);
    return numberValue(finished - started);
}

pub fn shouldRegisterNamedFunction(name: []const u8) bool {
    // HIR gives anonymous functions an internal name for calls and debug
    // metadata, but the official global-function list exposes named language
    // functions only.  Closures must therefore not enter named_functions.
    return name.len > 0 and std.mem.indexOf(u8, name, "__lambda$") == null;
}

pub fn systemGlobalFunctionNamesBuiltin(runtime: *Runtime) !Value {
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    for (runtime.named_functions.items) |registered| {
        roots[1] = try runtimeUtf8String(runtime, registered.name);
        try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
    }
    return roots[0];
}

pub fn nodeEnvironmentBuiltin(runtime: *Runtime, command: aot_builtin.Command) !Value {
    return runtimeUtf8String(runtime, if (command == .node_os) aotOsName() else aotArchitectureName());
}

pub fn nodeProcessExitCode(runtime: *Runtime, value: Value) !u8 {
    const number = try valueToNumberRuntime(runtime, value);
    if (!std.math.isFinite(number)) return 0;
    return @intFromFloat(@mod(@trunc(number), 256.0));
}

pub fn nodeCryptoBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    switch (command) {
        .node_hash_value => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            const input = if (arguments[0].tag == @intFromEnum(Tag.byte_buffer))
                try runtime.allocator.dupe(u8, arguments[0].object().?.payload.byte_buffer.bytes)
            else
                try valueUtf8LossyAlloc(runtime, arguments[0]);
            defer runtime.allocator.free(input);
            const algorithm = try valueUtf8LossyAlloc(runtime, arguments[1]);
            defer runtime.allocator.free(algorithm);
            const digest = try crypto.calculateDigest(runtime.allocator, input, algorithm);
            defer runtime.allocator.free(digest);

            const encoding_value: Value = if (arguments.len > 2) arguments[2] else .{};
            if (encoding_value.tag == @intFromEnum(Tag.undefined) or encoding_value.tag == @intFromEnum(Tag.null_value)) return runtime.createBytes(digest);
            const encoding_name = try valueUtf8LossyAlloc(runtime, encoding_value);
            defer runtime.allocator.free(encoding_name);
            if (std.ascii.eqlIgnoreCase(encoding_name, "hex")) {
                const result = try runtime.allocator.alloc(u8, digest.len * 2);
                defer runtime.allocator.free(result);
                _ = std.fmt.bufPrint(result, "{x}", .{digest}) catch unreachable;
                return runtimeUtf8String(runtime, result);
            }
            if (std.ascii.eqlIgnoreCase(encoding_name, "base64") or std.ascii.eqlIgnoreCase(encoding_name, "base64url")) {
                const result = try runtime.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(digest.len));
                defer runtime.allocator.free(result);
                _ = std.base64.standard.Encoder.encode(result, digest);
                if (std.ascii.eqlIgnoreCase(encoding_name, "base64")) return runtimeUtf8String(runtime, result);
                for (result) |*byte| byte.* = switch (byte.*) {
                    '+' => '-',
                    '/' => '_',
                    else => byte.*,
                };
                var length = result.len;
                while (length > 0 and result[length - 1] == '=') length -= 1;
                return runtimeUtf8String(runtime, result[0..length]);
            }
            if (std.ascii.eqlIgnoreCase(encoding_name, "latin1") or std.ascii.eqlIgnoreCase(encoding_name, "binary")) {
                const units = try runtime.allocator.alloc(u16, digest.len);
                defer runtime.allocator.free(units);
                for (digest, 0..) |byte, index| units[index] = byte;
                return runtime.createString(units);
            }
            if (std.ascii.eqlIgnoreCase(encoding_name, "utf8") or std.ascii.eqlIgnoreCase(encoding_name, "utf-8")) return runtimeUtf8StringLossy(runtime, digest);
            return error.UnsupportedDigestEncoding;
        },
        .node_random_uuid => {
            if (arguments.len != 0) return error.InvalidArgumentCount;
            var bytes: [16]u8 = undefined;
            try std.Io.Threaded.global_single_threaded.io().randomSecure(&bytes);
            const uuid = crypto.formatUuid(bytes);
            return runtimeUtf8String(runtime, &uuid);
        },
        .node_random_array => {
            const source: Value = if (arguments.len > 0) arguments[0] else .{};
            const count_number = try valueToNumberRuntime(runtime, source);
            if (std.math.isInf(count_number) or count_number < 0 or count_number > 65_536) return error.InvalidRandomByteCount;
            const count: usize = if (std.math.isNan(count_number)) 0 else @intFromFloat(@trunc(count_number));
            const bytes = try runtime.allocator.alloc(u8, count);
            defer runtime.allocator.free(bytes);
            try std.Io.Threaded.global_single_threaded.io().randomSecure(bytes);
            return runtime.createUint8Array(bytes);
        },
        else => return error.UnknownCommand,
    }
}

pub fn nodeFileExistenceBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const path = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(path);
    const stat = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch {
        return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
    };
    const result = command == .node_file_exists or stat.kind == .directory;
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(result) };
}

pub fn nodeFileReadBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const path = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        path,
        runtime.allocator,
        .limited(1024 * 1024 * 1024),
    );
    defer runtime.allocator.free(bytes);
    return if (command == .node_file_binary_read) runtime.createBytes(bytes) else runtimeUtf8StringLossy(runtime, bytes);
}

pub fn nodeFileSaveBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const path = try valueUtf8LossyAlloc(runtime, arguments[1]);
    defer runtime.allocator.free(path);
    if (arguments[0].tag == @intFromEnum(Tag.byte_buffer)) {
        try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
            .sub_path = path,
            .data = arguments[0].object().?.payload.byte_buffer.bytes,
        });
    } else {
        const bytes = try valueUtf8LossyAlloc(runtime, arguments[0]);
        defer runtime.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = bytes });
    }
    return .{};
}

pub fn nodeEncodingName(command: aot_builtin.Command) []const u8 {
    return switch (command) {
        .node_file_sjis_read, .node_file_sjis_save, .node_encoding_sjis_encode, .node_encoding_sjis_decode => "shift_jis",
        .node_file_euc_read, .node_file_euc_save => "euc-jp",
        else => unreachable,
    };
}

pub fn nodeEncodingValueBytesAlloc(runtime: *Runtime, value: Value) ![]u8 {
    if (value.tag == @intFromEnum(Tag.byte_buffer)) return runtime.allocator.dupe(u8, value.object().?.payload.byte_buffer.bytes);
    if (value.tag == @intFromEnum(Tag.array)) {
        const items = value.object().?.payload.array.items;
        const bytes = try runtime.allocator.alloc(u8, items.len);
        errdefer runtime.allocator.free(bytes);
        for (items, 0..) |item, index| {
            const number = try valueToNumberRuntime(runtime, item);
            bytes[index] = if (!std.math.isFinite(number)) 0 else @intFromFloat(@mod(@trunc(number), 256.0));
        }
        return bytes;
    }
    return valueUtf8LossyAlloc(runtime, value);
}

pub fn nodeEncodingBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    if ((command == .node_encoding_encode or command == .node_encoding_decode) and arguments.len < 2) {
        return error.InvalidArgumentCount;
    }
    const encoding_name = if (command == .node_encoding_encode or command == .node_encoding_decode)
        try valueUtf8LossyAlloc(runtime, arguments[1])
    else
        try runtime.allocator.dupe(u8, nodeEncodingName(command));
    defer runtime.allocator.free(encoding_name);

    return switch (command) {
        .node_encoding_sjis_encode, .node_encoding_encode => blk: {
            const units = try valueUtf16Alloc(runtime, arguments[0]);
            defer runtime.allocator.free(units);
            const bytes = try encoding.encodeUnits(runtime.allocator, units, encoding_name);
            defer runtime.allocator.free(bytes);
            break :blk try runtime.createBytes(bytes);
        },
        .node_encoding_sjis_decode, .node_encoding_decode => blk: {
            const bytes = try nodeEncodingValueBytesAlloc(runtime, arguments[0]);
            defer runtime.allocator.free(bytes);
            const units = try encoding.decodeBytes(runtime.allocator, bytes, encoding_name);
            defer runtime.allocator.free(units);
            break :blk try runtime.createString(units);
        },
        else => error.UnknownCommand,
    };
}

pub fn nodeEncodedFileReadBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const path = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        path,
        runtime.allocator,
        .limited(1024 * 1024 * 1024),
    );
    defer runtime.allocator.free(bytes);
    const units = try encoding.decodeBytes(runtime.allocator, bytes, nodeEncodingName(command));
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

pub fn nodeEncodedFileSaveBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const units = try valueUtf16Alloc(runtime, arguments[0]);
    defer runtime.allocator.free(units);
    const bytes = try encoding.encodeUnits(runtime.allocator, units, nodeEncodingName(command));
    defer runtime.allocator.free(bytes);
    const path = try valueUtf8LossyAlloc(runtime, arguments[1]);
    defer runtime.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = bytes });
    return .{};
}

pub fn isNodeFileOperationCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_file_list, .node_file_list_all, .node_folder_create, .node_file_copy, .node_file_copy_overwrite, .node_file_move, .node_file_move_overwrite, .node_file_delete => true,
        else => false,
    };
}

pub fn isNodeFileCallbackCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_file_process_callback, .node_file_process_stop, .node_file_copy_callback, .node_file_move_callback, .node_file_delete_callback => true,
        else => false,
    };
}

pub fn nodeFileCallbackBuiltin(runtime: *Runtime, target: ?*Value, command: aot_builtin.Command, arguments: []const Value) !Value {
    switch (command) {
        .node_file_process_callback => {
            if (arguments.len < 1) return error.InvalidArgumentCount;
            var callback = arguments[0];
            var frame = RootFrame{};
            runtime.pushRoots(&frame, @ptrCast(&callback), 1);
            defer runtime.popRoots(&frame);
            callback = try resolveAotCallback(runtime, callback);
            runtime.file_process_callback = callback;
            runtime.file_process_target = target;
            runtime.file_process_stop = false;
            return .{};
        },
        .node_file_process_stop => {
            runtime.file_process_stop = true;
            return .{};
        },
        .node_file_copy_callback, .node_file_move_callback => {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            var rooted = [_]Value{ arguments[0], arguments[1], arguments[2] };
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &rooted, rooted.len);
            defer runtime.popRoots(&frame);
            rooted[0] = try resolveAotCallback(runtime, rooted[0]);
            const source = try valueUtf8LossyAlloc(runtime, rooted[1]);
            defer runtime.allocator.free(source);
            const destination = try valueUtf8LossyAlloc(runtime, rooted[2]);
            defer runtime.allocator.free(destination);
            runtime.file_process_target = target;
            try queueAotFileTask(
                runtime,
                if (command == .node_file_copy_callback) .copy else .move,
                source,
                destination,
                command == .node_file_copy_callback,
                rooted[0],
            );
            return .{};
        },
        .node_file_delete_callback => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            var rooted = [_]Value{ arguments[0], arguments[1] };
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &rooted, rooted.len);
            defer runtime.popRoots(&frame);
            rooted[0] = try resolveAotCallback(runtime, rooted[0]);
            const source = try valueUtf8LossyAlloc(runtime, rooted[1]);
            defer runtime.allocator.free(source);
            runtime.file_process_target = target;
            try queueAotFileTask(runtime, .delete, source, &.{}, false, rooted[0]);
            return .{};
        },
        else => return error.UnknownCommand,
    }
}

pub fn nodeFileOperationBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value, file_copy_default: *Value) !Value {
    return switch (command) {
        .node_file_list => nodeFileListBuiltin(runtime, arguments, false),
        .node_file_list_all => nodeFileListBuiltin(runtime, arguments, true),
        .node_folder_create => nodeFolderCreateBuiltin(runtime, arguments),
        .node_file_copy, .node_file_copy_overwrite, .node_file_move, .node_file_move_overwrite => nodeFileCopyMoveBuiltin(runtime, command, arguments, file_copy_default),
        .node_file_delete => nodeFileDeleteBuiltin(runtime, arguments),
        else => error.UnknownCommand,
    };
}

pub fn nodeFileListBuiltin(runtime: *Runtime, arguments: []const Value, recursive: bool) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const pattern = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(pattern);
    const has_wildcard = std.mem.indexOfScalar(u8, pattern, '*') != null;
    const base = if (has_wildcard) nodeDirname(pattern) else pattern;
    const mask = if (has_wildcard) nodeBasename(pattern) else "*";
    const io = std.Io.Threaded.global_single_threaded.io();

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| runtime.allocator.free(name);
        names.deinit(runtime.allocator);
    }

    var directory = try std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true });
    defer directory.close(io);
    if (recursive) {
        const current = try currentDirectoryAlloc(runtime);
        defer runtime.allocator.free(current);
        const absolute_base = try std.fs.path.resolve(runtime.allocator, &.{ current, base });
        defer runtime.allocator.free(absolute_base);
        var walker = try directory.walk(runtime.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!try nodeWildcardMatches(runtime, mask, nodeBasename(entry.path))) continue;
            try names.append(runtime.allocator, try std.fs.path.join(runtime.allocator, &.{ absolute_base, entry.path }));
        }
    } else {
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            if (!try nodeWildcardMatches(runtime, mask, entry.name)) continue;
            try names.append(runtime.allocator, try runtime.allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]u8, names.items, {}, lessThanNodeAotFileName);

    var result = try runtime.createArray(&.{});
    var frame = RootFrame{};
    runtime.pushRoots(&frame, @ptrCast(&result), 1);
    defer runtime.popRoots(&frame);
    for (names.items) |name| {
        const value = try runtimeUtf8String(runtime, name);
        try result.object().?.payload.array.append(runtime.allocator, value);
    }
    return result;
}

pub fn nodeWildcardMatches(runtime: *Runtime, pattern: []const u8, name: []const u8) !bool {
    var expression: std.ArrayList(u8) = .empty;
    defer expression.deinit(runtime.allocator);
    const multiple = std.mem.indexOfScalar(u8, pattern, ';') != null;
    if (multiple) try expression.append(runtime.allocator, '(');
    for (pattern) |byte| switch (byte) {
        '.' => try expression.appendSlice(runtime.allocator, "\\."),
        '*' => try expression.appendSlice(runtime.allocator, ".*"),
        ';' => try expression.append(runtime.allocator, '|'),
        else => try expression.append(runtime.allocator, byte),
    };
    if (multiple) try expression.append(runtime.allocator, ')');
    try expression.append(runtime.allocator, '$');
    var pattern_string = try string_mod.String.fromUtf8(runtime.allocator, expression.items);
    defer pattern_string.deinit();
    var name_string = try string_mod.String.fromUtf8Lossy(runtime.allocator, name);
    defer name_string.deinit();
    return regexp.testRaw(runtime.allocator, pattern_string.units, name_string.units, true);
}

pub fn lessThanNodeAotFileName(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

pub fn nodeFolderCreateBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const path = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), path);
    return .{};
}

pub fn nodeFileDeleteBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const path = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(path);
    try std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path);
    return .{};
}

pub fn nodeFileCopyDefaultOverwrite(runtime: *Runtime, value: Value) !bool {
    const mode = try valueUtf8LossyAlloc(runtime, value);
    defer runtime.allocator.free(mode);
    return std.mem.eql(u8, mode, "上書き") or std.mem.eql(u8, mode, "上書") or std.mem.eql(u8, mode, "overwrite");
}

pub fn nodeFileCopyMoveBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value, file_copy_default: *Value) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const source = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(source);
    const destination = try valueUtf8LossyAlloc(runtime, arguments[1]);
    defer runtime.allocator.free(destination);
    const explicit_overwrite = command == .node_file_copy_overwrite or command == .node_file_move_overwrite;
    const overwrite = if (explicit_overwrite) true else try nodeFileCopyDefaultOverwrite(runtime, file_copy_default.*);
    const io = aotRuntimeIo(runtime);
    if (!overwrite and nodeAotPathExists(io, destination)) return error.CopyDestinationExists;
    runtime.file_process_stop = false;

    const move = command == .node_file_move or command == .node_file_move_overwrite;
    if (runtime.file_process_callback.tag == @intFromEnum(Tag.function)) {
        try aotFileCopyMoveWithProgress(runtime, io, source, destination, overwrite, move);
    } else try aotFileCopyMoveWithIo(runtime, io, source, destination, overwrite, move);
    return .{};
}

pub fn aotFileCopyMoveWithIo(runtime: *Runtime, io: std.Io, source: []const u8, destination: []const u8, overwrite: bool, move: bool) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, source, .{});
    if (stat.kind != .directory) {
        try std.Io.Dir.cwd().copyFile(source, std.Io.Dir.cwd(), destination, io, .{ .replace = overwrite, .make_path = true });
    } else {
        try std.Io.Dir.cwd().createDirPath(io, destination);
        var directory = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
        defer directory.close(io);
        var walker = try directory.walk(runtime.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            const target = try std.fs.path.join(runtime.allocator, &.{ destination, entry.path });
            defer runtime.allocator.free(target);
            if (entry.kind == .directory) {
                try std.Io.Dir.cwd().createDirPath(io, target);
            } else if (entry.kind == .file) {
                const from = try std.fs.path.join(runtime.allocator, &.{ source, entry.path });
                defer runtime.allocator.free(from);
                try std.Io.Dir.cwd().copyFile(from, std.Io.Dir.cwd(), target, io, .{ .replace = overwrite, .make_path = true });
            }
        }
    }
    if (move) try std.Io.Dir.cwd().deleteTree(io, source);
}

pub fn aotFileCopyMoveWithProgress(runtime: *Runtime, io: std.Io, source: []const u8, destination: []const u8, overwrite: bool, move: bool) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, source, .{});
    if (stat.kind != .directory) {
        try std.Io.Dir.cwd().copyFile(source, std.Io.Dir.cwd(), destination, io, .{ .replace = overwrite, .make_path = true });
        try emitAotFileProgress(runtime, 1, 1);
    } else {
        try std.Io.Dir.cwd().createDirPath(io, destination);
        var directory = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
        defer directory.close(io);
        var files: std.ArrayList([]u8) = .empty;
        defer {
            for (files.items) |path| runtime.allocator.free(path);
            files.deinit(runtime.allocator);
        }
        var walker = try directory.walk(runtime.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .file) {
                try files.append(runtime.allocator, try runtime.allocator.dupe(u8, entry.path));
            }
        }
        std.mem.sort([]u8, files.items, {}, lessThanNodeAotFileName);
        var current: usize = 0;
        for (files.items) |path| {
            if (runtime.file_process_stop) break;
            const from = try std.fs.path.join(runtime.allocator, &.{ source, path });
            defer runtime.allocator.free(from);
            const target = try std.fs.path.join(runtime.allocator, &.{ destination, path });
            defer runtime.allocator.free(target);
            try std.Io.Dir.cwd().copyFile(from, std.Io.Dir.cwd(), target, io, .{ .replace = overwrite, .make_path = true });
            current += 1;
            emitAotFileProgress(runtime, files.items.len, current) catch {};
        }
    }
    if (move and !runtime.file_process_stop) try std.Io.Dir.cwd().deleteTree(io, source);
}

pub fn emitAotFileProgress(runtime: *Runtime, total: usize, current: usize) !void {
    if (runtime.file_process_stop) return;
    var rooted = [_]Value{ runtime.file_process_callback, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    rooted[1] = try runtime.createDictionary(&.{});
    rooted[2] = try runtimeUtf8String(runtime, "件数");
    rooted[3] = try runtimeUtf8String(runtime, "現在");
    try runtime.setDictionary(&rooted[1].object().?.payload.dictionary, rooted[2], numberValue(@floatFromInt(total)));
    try runtime.setDictionary(&rooted[1].object().?.payload.dictionary, rooted[3], numberValue(@floatFromInt(current)));
    if (runtime.file_process_target) |target| target.* = rooted[1];
    _ = try invokeAotCallback(runtime, rooted[0], @ptrCast(&rooted[1]), 1);
}

pub fn nodeAotPathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

pub fn nodeFileSizeBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const path = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(path);
    const stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{});
    return numberValue(@floatFromInt(stat.size));
}

pub fn nodeFileInfoBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const path = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(path);
    const stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{});

    var result = try runtime.createDictionary(&.{});
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&result), 1);
    defer runtime.popRoots(&roots);

    try setNodeFileInfoValue(runtime, result, "size", numberValue(@floatFromInt(stat.size)));
    try setNodeFileInfoValue(runtime, result, "mtimeMs", numberValue(@as(f64, @floatFromInt(stat.mtime.nanoseconds)) / 1_000_000.0));
    try setNodeFileInfoValue(runtime, result, "ctimeMs", numberValue(@as(f64, @floatFromInt(stat.ctime.nanoseconds)) / 1_000_000.0));
    try setNodeFileInfoValue(runtime, result, "atimeMs", numberValue(if (stat.atime) |access_time| @as(f64, @floatFromInt(access_time.nanoseconds)) / 1_000_000.0 else 0));
    try setNodeFileInfoValue(runtime, result, "ino", numberValue(@floatFromInt(stat.inode)));
    try setNodeFileInfoValue(runtime, result, "nlink", numberValue(@floatFromInt(stat.nlink)));
    try setNodeFileInfoValue(runtime, result, "blksize", numberValue(@floatFromInt(stat.block_size)));
    try setNodeFileInfoMethod(runtime, result, "isFile", stat.kind == .file);
    try setNodeFileInfoMethod(runtime, result, "isDirectory", stat.kind == .directory);
    for ([_][]const u8{ "isBlockDevice", "isCharacterDevice", "isSymbolicLink", "isFIFO", "isSocket" }) |name| {
        try setNodeFileInfoMethod(runtime, result, name, false);
    }
    return result;
}

pub fn setNodeFileInfoValue(runtime: *Runtime, dictionary: Value, name: []const u8, value: Value) !void {
    var rooted = [_]Value{ dictionary, value, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);
    rooted[2] = try runtimeUtf8String(runtime, name);
    try runtime.setDictionary(&rooted[0].object().?.payload.dictionary, rooted[2], rooted[1]);
}

pub fn setNodeFileInfoMethod(runtime: *Runtime, dictionary: Value, name: []const u8, result: bool) !void {
    var rooted = [_]Value{ dictionary, .{}, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);
    rooted[1] = try runtime.createMethodFunction(if (result) nodeFileInfoTrue else nodeFileInfoFalse, 0, name, &.{});
    rooted[2] = try runtimeUtf8String(runtime, name);
    try runtime.setDictionary(&rooted[0].object().?.payload.dictionary, rooted[2], rooted[1]);
}

pub fn nodeFileInfoTrue(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 };
}

pub fn nodeFileInfoFalse(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
}

pub fn nodeEncodingSupportsBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const name = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(name);
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(encoding.supports(name)) };
}

pub fn ensureAotStdin(runtime: *Runtime) ![]const u8 {
    if (runtime.stdin_bytes == null) {
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(std.Io.Threaded.global_single_threaded.io(), &buffer);
        runtime.stdin_bytes = try reader.interface.allocRemaining(runtime.allocator, .limited(64 * 1024 * 1024));
    }
    return runtime.stdin_bytes.?;
}

pub fn nextAotStdinLine(runtime: *Runtime) []const u8 {
    const bytes = runtime.stdin_bytes orelse return "";
    if (runtime.stdin_offset >= bytes.len) return "";
    const start = runtime.stdin_offset;
    var end = start;
    while (end < bytes.len and bytes[end] != '\n') end += 1;
    runtime.stdin_offset = if (end < bytes.len) end + 1 else end;
    if (end > start and bytes[end - 1] == '\r') end -= 1;
    return bytes[start..end];
}

pub fn nodeStdinCallbackBuiltin(runtime: *Runtime, target: *Value, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    _ = try ensureAotStdin(runtime);
    var rooted = [_]Value{ arguments[0], .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);
    rooted[0] = try resolveAotCallback(runtime, rooted[0]);
    while (runtime.stdin_offset < runtime.stdin_bytes.?.len) {
        rooted[1] = try runtimeUtf8StringLossy(runtime, nextAotStdinLine(runtime));
        target.* = rooted[1];
        _ = try invokeAotCallback(runtime, rooted[0], @ptrCast(&rooted[1]), 1);
    }
    return .{};
}

pub fn nodeStdinLineBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    _ = try ensureAotStdin(runtime);
    const prompt_value = if (arguments.len > 0) arguments[0] else Value{};
    const prompt = try valueUtf8LossyAlloc(runtime, prompt_value);
    defer runtime.allocator.free(prompt);
    writeBytes(prompt, false);

    const raw_line = nextAotStdinLine(runtime);
    const text = try runtimeUtf8StringLossy(runtime, raw_line);
    if (command == .node_stdin_character) return text;
    const number = try valueToNumberRuntime(runtime, text);
    return if (std.math.isNan(number)) text else numberValue(number);
}

pub fn nodeStdinAllBuiltin(runtime: *Runtime) !Value {
    const bytes = try ensureAotStdin(runtime);
    return runtimeUtf8StringLossy(runtime, bytes);
}

pub fn nodeStdinValueBuiltin(runtime: *Runtime, bytes: []const u8) !Value {
    return runtimeUtf8StringLossy(runtime, bytes);
}

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

pub fn nodeDirectoryBuiltin(runtime: *Runtime, command: aot_builtin.Command) !Value {
    if (command == .node_temporary_directory) {
        const fallback = if (builtin.os.tag == .windows) "." else "/tmp";
        const raw = if (builtin.os.tag == .windows)
            std.c.getenv("TEMP") orelse std.c.getenv("TMP") orelse fallback
        else
            std.c.getenv("TMPDIR") orelse fallback;
        const value = std.mem.span(raw);
        const trimmed = std.mem.trimEnd(u8, value, "/\\");
        return runtimeUtf8StringLossy(runtime, if (trimmed.len == 0) value else trimmed);
    }

    const home_name = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = std.c.getenv(home_name) orelse return .{};
    const home_path = std.mem.span(home);
    if (command == .node_home_directory) return runtimeUtf8StringLossy(runtime, home_path);
    const child = switch (command) {
        .node_desktop => "Desktop",
        .node_documents => "Documents",
        else => return error.UnknownCommand,
    };
    const path = try std.fs.path.join(runtime.allocator, &.{ home_path, child });
    defer runtime.allocator.free(path);
    return runtimeUtf8StringLossy(runtime, path);
}

pub fn nodeTemporaryDirectoryPrefixAlloc(runtime: *Runtime) ![]u8 {
    const fallback = if (builtin.os.tag == .windows) "." else "/tmp";
    const raw = if (builtin.os.tag == .windows)
        std.c.getenv("TEMP") orelse std.c.getenv("TMP") orelse fallback
    else
        std.c.getenv("TMPDIR") orelse fallback;
    const value = std.mem.span(raw);
    const trimmed = std.mem.trimEnd(u8, value, "/\\");
    return runtime.allocator.dupe(u8, if (trimmed.len == 0) value else trimmed);
}

pub fn nodeCreateTemporaryDirectoryBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const prefix = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(prefix);

    var fallback_prefix: ?[]u8 = null;
    const effective_prefix = if (prefix.len == 0) blk: {
        fallback_prefix = try nodeTemporaryDirectoryPrefixAlloc(runtime);
        break :blk fallback_prefix.?;
    } else prefix;
    defer if (fallback_prefix) |value| runtime.allocator.free(value);

    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    const io = std.Io.Threaded.global_single_threaded.io();
    for (0..128) |_| {
        const candidate = try runtime.allocator.alloc(u8, effective_prefix.len + 6);
        errdefer runtime.allocator.free(candidate);
        @memcpy(candidate[0..effective_prefix.len], effective_prefix);
        for (candidate[effective_prefix.len..]) |*byte| {
            const index = @as(usize, @intFromFloat(@floor(nextRandom(runtime) * @as(f64, @floatFromInt(alphabet.len)))));
            byte.* = alphabet[index];
        }

        if (std.fs.path.isAbsolute(candidate)) {
            std.Io.Dir.createDirAbsolute(io, candidate, .default_dir) catch |failure| switch (failure) {
                error.PathAlreadyExists => {
                    runtime.allocator.free(candidate);
                    continue;
                },
                else => return failure,
            };
        } else {
            std.Io.Dir.cwd().createDir(io, candidate, .default_dir) catch |failure| switch (failure) {
                error.PathAlreadyExists => {
                    runtime.allocator.free(candidate);
                    continue;
                },
                else => return failure,
            };
        }

        defer runtime.allocator.free(candidate);
        return runtimeUtf8StringLossy(runtime, candidate);
    }
    return error.TemporaryDirectoryCollision;
}

pub fn nodeMotherPathBuiltin(runtime: *Runtime) !Value {
    const path = runtime.aot_source_directory orelse return error.SourcePathUnavailable;
    return runtimeUtf8StringLossy(runtime, path);
}

pub fn nodeEnvironmentValueBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const key_units = try valueUtf16Alloc(runtime, arguments[0]);
    defer runtime.allocator.free(key_units);
    const key = try (string_mod.String{ .allocator = runtime.allocator, .units = key_units }).toUtf8Lossy(runtime.allocator);
    defer runtime.allocator.free(key);
    const key_z = try runtime.allocator.dupeZ(u8, key);
    defer runtime.allocator.free(key_z);
    const environment = std.c.getenv(key_z.ptr) orelse return .{};
    return runtimeUtf8String(runtime, std.mem.span(environment));
}

pub fn nodeEnvironmentListBuiltin(runtime: *Runtime) !Value {
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createDictionary(&.{});
    if (comptime builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        var map = try std.process.Environ.createMap(environ, runtime.allocator);
        defer map.deinit();
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            roots[1] = try runtimeUtf8StringLossy(runtime, entry.key_ptr.*);
            roots[2] = try runtimeUtf8StringLossy(runtime, entry.value_ptr.*);
            try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
        }
    } else {
        var index: usize = 0;
        while (std.c.environ[index]) |entry| : (index += 1) {
            const bytes = std.mem.span(entry);
            const separator = std.mem.indexOfScalar(u8, bytes, '=') orelse continue;
            if (separator == 0) continue;
            roots[1] = try runtimeUtf8StringLossy(runtime, bytes[0..separator]);
            roots[2] = try runtimeUtf8StringLossy(runtime, bytes[separator + 1 ..]);
            try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
        }
    }
    return roots[0];
}

pub fn nodeCurrentDirectoryBuiltin(runtime: *Runtime) !Value {
    const path = try currentDirectoryAlloc(runtime);
    defer runtime.allocator.free(path);
    return runtimeUtf8StringLossy(runtime, path);
}

pub fn currentDirectoryAlloc(runtime: *Runtime) ![]u8 {
    // Keep AOT's cwd semantics aligned with the CLI host.  In particular,
    // Node reports the canonical path after entering a directory through a
    // symlink; a raw getcwd buffer is a separate platform-specific path.
    const io = std.Io.Threaded.global_single_threaded.io();
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", runtime.allocator);
    defer runtime.allocator.free(canonical.ptr[0 .. canonical.len + 1]);
    return runtime.allocator.dupe(u8, canonical);
}

pub fn aotProcessEnvironment() std.process.Environ {
    if (comptime builtin.os.tag == .windows) return .{ .block = .global };
    var count: usize = 0;
    while (std.c.environ[count] != null) : (count += 1) {}
    return .{ .block = .{ .slice = std.c.environ[0..count :null] } };
}

pub fn nodeChangeDirectoryBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const units = try valueUtf16Alloc(runtime, arguments[0]);
    defer runtime.allocator.free(units);
    const display_path = try (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
    defer runtime.allocator.free(display_path);
    const path = if (comptime builtin.os.tag == .windows)
        try std.unicode.wtf16LeToWtf8Alloc(runtime.allocator, units)
    else
        try runtime.allocator.dupe(u8, display_path);
    defer runtime.allocator.free(path);
    const cwd_raw = try currentDirectoryAlloc(runtime);
    defer runtime.allocator.free(cwd_raw);
    const cwd = try aotNodeErrorPathAlloc(runtime, cwd_raw);
    defer runtime.allocator.free(cwd);
    const io = std.Io.Threaded.global_single_threaded.io();
    var directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch |failure| {
        try setAotNodeChangeDirectoryFailure(runtime, cwd, display_path, failure);
        return failure;
    };
    defer directory.close(io);
    std.process.setCurrentDir(io, directory) catch |failure| {
        try setAotNodeChangeDirectoryFailure(runtime, cwd, display_path, failure);
        return failure;
    };
    return .{};
}

const AotNodeChangeDirectoryErrorInfo = struct {
    code: []const u8,
    description: []const u8,
};

pub fn aotNodeChangeDirectoryErrorInfo(failure: anyerror) ?AotNodeChangeDirectoryErrorInfo {
    return switch (failure) {
        error.FileNotFound => .{ .code = "ENOENT", .description = "no such file or directory" },
        error.NotDir => .{ .code = "ENOTDIR", .description = "not a directory" },
        error.AccessDenied, error.PermissionDenied => .{ .code = "EACCES", .description = "permission denied" },
        error.NameTooLong => .{ .code = "ENAMETOOLONG", .description = "name too long" },
        error.BadPathName, error.InvalidWtf8 => .{ .code = "EINVAL", .description = "invalid argument" },
        error.SymLinkLoop => .{ .code = "ELOOP", .description = "too many levels of symbolic links" },
        else => null,
    };
}

pub fn aotNodeErrorPathAlloc(runtime: *Runtime, path: []const u8) ![]u8 {
    if (comptime builtin.os.tag == .windows) {
        return std.unicode.wtf8ToUtf8LossyAlloc(runtime.allocator, path);
    }
    return runtime.allocator.dupe(u8, path);
}

pub fn setAotNodeChangeDirectoryFailure(runtime: *Runtime, cwd: []const u8, path: []const u8, failure: anyerror) !void {
    const info = aotNodeChangeDirectoryErrorInfo(failure) orelse return;
    const message = try std.fmt.allocPrint(
        runtime.allocator,
        "{s}: {s}, chdir '{s}' -> '{s}'",
        .{ info.code, info.description, cwd, path },
    );
    defer runtime.allocator.free(message);
    runtime.setFailureText(message);
}

pub fn nodePathBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const required: usize = if (command == .node_path_resolve) 2 else 1;
    if (arguments.len < required) return error.InvalidArgumentCount;

    const first_label = if (command == .node_path_absolute) "paths[0]" else "path";
    const first = try nodePathArgument(runtime, first_label, arguments[0]);
    defer runtime.allocator.free(first);
    const cwd = try currentDirectoryAlloc(runtime);
    defer runtime.allocator.free(cwd);

    const resolved = switch (command) {
        .node_path_absolute => try std.fs.path.resolve(runtime.allocator, &.{ cwd, first }),
        .node_path_resolve => blk: {
            const second = try nodePathArgument(runtime, "path", arguments[1]);
            defer runtime.allocator.free(second);
            const joined = try std.fs.path.join(runtime.allocator, &.{ first, second });
            defer runtime.allocator.free(joined);
            break :blk try std.fs.path.resolve(runtime.allocator, &.{ cwd, joined });
        },
        else => return error.UnknownCommand,
    };
    defer runtime.allocator.free(resolved);
    return runtimeUtf8StringLossy(runtime, resolved);
}

pub fn nodePathComponentBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const path = try nodePathArgument(runtime, "path", arguments[0]);
    defer runtime.allocator.free(path);
    const component = switch (command) {
        .node_path_basename => nodeBasename(path),
        .node_path_dirname => nodeDirname(path),
        else => return error.UnknownCommand,
    };
    return runtimeUtf8StringLossy(runtime, component);
}

pub fn systemPathComponentBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    if (!isString(arguments[0])) return error.InvalidPathSource;
    const path = try valueUtf16Alloc(runtime, arguments[0]);
    defer runtime.allocator.free(path);
    const component = switch (command) {
        .system_path_basename => pathBasenameUnits(path, '/'),
        .system_path_dirname => blk: {
            const separator = std.mem.lastIndexOfScalar(u16, path, '/');
            break :blk if (separator) |index| path[0..index] else &.{};
        },
        else => return error.UnknownCommand,
    };
    return runtime.createString(component);
}

pub fn nodePathArgument(runtime: *Runtime, label: []const u8, value: Value) ![]u8 {
    if (!isString(value)) {
        const received = try nodePathReceivedType(runtime, value);
        defer runtime.allocator.free(received);
        const message = try std.fmt.allocPrint(
            runtime.allocator,
            "The \"{s}\" argument must be of type string. Received {s}",
            .{ label, received },
        );
        defer runtime.allocator.free(message);
        runtime.setFailureText(message);
        return error.InvalidPathSource;
    }
    return stringUtf8Alloc(runtime, value);
}

pub fn nodePathReceivedType(runtime: *Runtime, value: Value) ![]u8 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => runtime.allocator.dupe(u8, "undefined"),
        .null_value => runtime.allocator.dupe(u8, "null"),
        .boolean => runtime.allocator.dupe(u8, if (value.payload == 0) "type boolean (false)" else "type boolean (true)"),
        .number => nodePathPrimitiveReceivedType(runtime, value, "number", false),
        .bigint => nodePathPrimitiveReceivedType(runtime, value, "bigint", true),
        .byte_buffer => switch (value.object().?.payload.byte_buffer.kind) {
            .buffer => runtime.allocator.dupe(u8, "an instance of Buffer"),
            .uint8_array => runtime.allocator.dupe(u8, "an instance of Uint8Array"),
            .array_buffer => runtime.allocator.dupe(u8, "an instance of ArrayBuffer"),
        },
        .array => runtime.allocator.dupe(u8, "an instance of Array"),
        .dictionary, .iterator, .binding_cell => runtime.allocator.dupe(u8, "an instance of Object"),
        .function => runtime.allocator.dupe(u8, "function "),
        .promise => runtime.allocator.dupe(u8, "an instance of Promise"),
        .static_utf8_string, .utf16_string => unreachable,
    };
}

pub fn nodePathPrimitiveReceivedType(runtime: *Runtime, value: Value, type_name: []const u8, bigint_suffix: bool) ![]u8 {
    const text = try valueUtf8LossyAlloc(runtime, value);
    defer runtime.allocator.free(text);
    return std.fmt.allocPrint(
        runtime.allocator,
        "type {s} ({s}{s})",
        .{ type_name, text, if (bigint_suffix) "n" else "" },
    );
}

pub fn nodeBasename(path: []const u8) []const u8 {
    return nodeBasenameFor(path, builtin.os.tag == .windows);
}

pub fn nodeBasenameFor(path: []const u8, windows: bool) []const u8 {
    // This follows Node's path.win32.basename loop: the drive prefix is
    // skipped before trimming trailing separators, and the first separator
    // before the basename becomes the exclusive start.  In particular, the
    // loop preserves mixed `/` and `\\` runs instead of normalizing them.
    var start: usize = 0;
    var end: ?usize = null;
    var matched_separator = true;
    if (windows and path.len >= 2 and isWindowsDriveLetter(path[0]) and path[1] == ':') start = 2;

    var index = path.len;
    while (index > start) {
        index -= 1;
        if (nodePathSeparator(path[index], windows)) {
            if (!matched_separator) {
                start = index + 1;
                break;
            }
        } else if (end == null) {
            matched_separator = false;
            end = index + 1;
        }
    }
    return path[start..(end orelse return "")];
}

pub fn nodeDirname(path: []const u8) []const u8 {
    return nodeDirnameFor(path, builtin.os.tag == .windows);
}

pub fn nodeDirnameFor(path: []const u8, windows: bool) []const u8 {
    if (windows) return nodeDirnameWindowsFor(path);
    if (path.len == 0) return ".";
    if (path.len == 1) return if (nodePathSeparator(path[0], false)) path else ".";
    var end = path.len;
    while (end > 0 and nodePathSeparator(path[end - 1], false)) end -= 1;
    if (end == 0) return path[0..1];

    var start = end;
    while (start > 0 and !nodePathSeparator(path[start - 1], false)) start -= 1;
    if (start == 0) return ".";
    if (start == 1 and nodePathSeparator(path[0], false)) return path[0..1];
    if (start == 2 and nodePathSeparator(path[0], false) and nodePathSeparator(path[1], false)) return path[0..2];
    return path[0 .. start - 1];
}

pub fn nodeDirnameWindowsFor(path: []const u8) []const u8 {
    // Port the root scan used by Node 24's path.win32.dirname.  A matched
    // UNC root is only special when it has a server, share, and a leftover
    // component; a root-only path is returned unchanged.  This matters for
    // mixed separator input such as `//\\server/share/\\file`.
    const len = path.len;
    if (len == 0) return ".";
    if (len == 1) return if (nodePathSeparator(path[0], true)) path else ".";

    var root_end: ?usize = null;
    var offset: usize = 0;
    const first = path[0];
    if (nodePathSeparator(first, true)) {
        root_end = 1;
        offset = 1;
        if (nodePathSeparator(path[1], true)) {
            var index: usize = 2;
            var last = index;
            while (index < len and !nodePathSeparator(path[index], true)) index += 1;
            if (index < len and index != last) {
                last = index;
                while (index < len and nodePathSeparator(path[index], true)) index += 1;
                if (index < len and index != last) {
                    last = index;
                    while (index < len and !nodePathSeparator(path[index], true)) index += 1;
                    if (index == len) return path;
                    if (index != last) {
                        root_end = index + 1;
                        offset = index + 1;
                    }
                }
            }
        }
    } else if (isWindowsDriveLetter(first) and path[1] == ':') {
        root_end = if (len > 2 and nodePathSeparator(path[2], true)) 3 else 2;
        offset = root_end.?;
    }

    var end: ?usize = null;
    var matched_separator = true;
    var index = len;
    while (index > offset) {
        index -= 1;
        if (nodePathSeparator(path[index], true)) {
            if (!matched_separator) {
                end = index;
                break;
            }
        } else {
            matched_separator = false;
        }
    }
    if (end == null) end = root_end orelse return ".";
    return path[0..end.?];
}

pub fn isWindowsDriveLetter(byte: u8) bool {
    return byte >= 'A' and byte <= 'Z' or byte >= 'a' and byte <= 'z';
}

pub fn nodePathSeparator(byte: u8, windows: bool) bool {
    return byte == std.fs.path.sep or (windows and (byte == '/' or byte == '\\'));
}

pub fn nodePathSeparatorWide(unit: u16, windows: bool) bool {
    return unit == @as(u16, std.fs.path.sep) or (windows and (unit == '/' or unit == '\\'));
}

pub fn isWindowsDriveLetterWide(unit: u16) bool {
    return unit >= 'A' and unit <= 'Z' or unit >= 'a' and unit <= 'z';
}

pub fn aotOsName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        .linux => "linux",
        else => @tagName(builtin.os.tag),
    };
}

pub fn aotArchitectureName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        .x86 => "ia32",
        else => @tagName(builtin.cpu.arch),
    };
}

pub fn datetimeCivilFromDays(days_input: i64) struct { year: i64, month: i64, day: i64 } {
    const days = days_input + 719468;
    const era = @divFloor(days, 146097);
    const day_of_era = days - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
    const month = month_prime + (if (month_prime < 10) @as(i64, 3) else -9);
    year += @intFromBool(month <= 2);
    return .{ .year = year, .month = month, .day = day };
}

pub fn mathCoordinateAngle(runtime: *Runtime, source: Value) !f64 {
    if (source.tag != @intFromEnum(Tag.array)) return std.math.nan(f64);
    const items = source.object().?.payload.array.items;
    const x = try valueToNumberRuntime(runtime, if (items.len > 0) items[0] else .{});
    const y = try valueToNumberRuntime(runtime, if (items.len > 1) items[1] else .{});
    return std.math.atan2(y, x) / std.math.pi * 180;
}

pub fn mathParseFloat(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => @bitCast(value.payload),
        .bigint => value.object().?.payload.bigint.toF64(),
        else => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk number_mod.parseFloatPrefix(runtime.allocator, units);
        },
    };
}

pub fn mathSign(runtime: *Runtime, source: Value) !f64 {
    const parsed = try mathParseFloat(runtime, source);
    if (parsed == 0) return 0;
    const coerced = try valueToNumberRuntime(runtime, source);
    return if (coerced > 0) 1 else -1;
}

pub fn mathLogarithm(runtime: *Runtime, base_value: Value, source_value: Value) !f64 {
    const base = try valueToNumberRuntime(runtime, base_value);
    const source = try valueToNumberRuntime(runtime, source_value);
    if (base == 2) return std.math.log2e * @log(source);
    if (base == 10) return std.math.log10e * @log(source);
    return @log(source) / @log(base);
}

const MathDecimalMode = enum { ceil, floor, round };

pub fn mathDecimalRound(runtime: *Runtime, source: Value, digits_value: Value, mode: MathDecimalMode) !f64 {
    const value = try valueToNumberRuntime(runtime, source);
    const digits = try valueToNumberRuntime(runtime, digits_value);
    const base = std.math.pow(f64, 10, digits);
    const scaled = value * base;
    const rounded = switch (mode) {
        .ceil => @ceil(scaled),
        .floor => @floor(scaled),
        .round => mathRound(scaled),
    };
    return rounded / base;
}

pub fn mathRound(value: f64) f64 {
    if (!std.math.isFinite(value) or value == 0) return value;
    const result = @floor(value + 0.5);
    if (result == 0 and value < 0) return -0.0;
    return result;
}

pub fn radixBuiltin(runtime: *Runtime, value: Value, radix_value: Value) !Value {
    const number = try parseIntBuiltin(runtime, value);
    const radix_number: f64 = if (radix_value.tag == @intFromEnum(Tag.undefined)) 10 else try valueToNumberRuntime(runtime, radix_value);
    const truncated = @trunc(radix_number);
    if (!std.math.isFinite(radix_number) or truncated < 2 or truncated > 36) return error.InvalidRadix;
    const text = try number_mod.integerToRadixAlloc(runtime.allocator, number, @intFromFloat(truncated));
    defer runtime.allocator.free(text);
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    return runtime.ownString(units);
}

pub fn rgbBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    var components: [3]f64 = undefined;
    for (0..3) |index| components[index] = try parseIntBuiltin(runtime, arguments[index]);
    const text = try number_mod.rgbAlloc(runtime.allocator, components);
    defer runtime.allocator.free(text);
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    return runtime.ownString(units);
}

pub fn rangeBuiltin(runtime: *Runtime, first: Value, last: Value) !Value {
    var roots = [_]Value{ first, last, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try runtime.createString(&.{ 0x5148, 0x982d });
    roots[3] = try runtime.createString(&.{ 0x672b, 0x5c3e });
    roots[4] = try runtime.createDictionary(&.{ roots[2], roots[0], roots[3], roots[1] });
    return roots[4];
}

pub fn repeatMultiplyBuiltin(runtime: *Runtime, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (!isString(roots[0]) and roots[0].tag != @intFromEnum(Tag.array)) return arithmetic(runtime, .multiply, roots[0], roots[1]);
    const count_number = try parseIntBuiltin(runtime, roots[1]);
    const count: usize = if (std.math.isNan(count_number) or count_number <= 0)
        0
    else if (!std.math.isFinite(count_number) or count_number > @as(f64, @floatFromInt(std.math.maxInt(usize))))
        return error.RepetitionTooLarge
    else
        @intFromFloat(@trunc(count_number));
    if (isString(roots[0])) {
        const source = try valueUtf16Alloc(runtime, roots[0]);
        defer runtime.allocator.free(source);
        const length = std.math.mul(usize, source.len, count) catch return error.RepetitionTooLarge;
        const units = try runtime.allocator.alloc(u16, length);
        for (0..count) |index| @memcpy(units[index * source.len ..][0..source.len], source);
        return runtime.ownString(units);
    }
    const source = roots[0].object().?.payload.array.items;
    const length = std.math.mul(usize, source.len, count) catch return error.RepetitionTooLarge;
    const values = try runtime.allocator.alloc(Value, length);
    defer runtime.allocator.free(values);
    for (0..count) |index| @memcpy(values[index * source.len ..][0..source.len], source);
    roots[2] = try runtime.createArray(values);
    return roots[2];
}

pub fn codePointCount(units: []const u16) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < units.len) : (count += 1) index += codePointLength(units, index);
    return count;
}

pub fn codePointLength(units: []const u16, index: usize) usize {
    return if (index + 1 < units.len and units[index] >= 0xd800 and units[index] <= 0xdbff and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) 2 else 1;
}

/// Fast path for the common string/string form of `何文字目`.  Both
/// operands are already strings, so allocating one UTF-16 buffer per value
/// is enough.  The window width is measured in Array.from elements rather
/// than UTF-16 units; this is important for a lone high surrogate not to
/// match the prefix of a supplementary pair.
pub fn codePointFindStringBuiltin(runtime: *Runtime, source: Value, needle: Value) !usize {
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const needle_units = try valueUtf16Alloc(runtime, needle);
    defer runtime.allocator.free(needle_units);
    if (source_units.len == 0) return 0;

    const needle_count = codePointCount(needle_units);
    var end: usize = 0;
    var initial: usize = 0;
    while (initial < needle_count and end < source_units.len) : (initial += 1) end += codePointLength(source_units, end);

    var start: usize = 0;
    var scalar_index: usize = 0;
    while (start < source_units.len) : (scalar_index += 1) {
        if (std.mem.eql(u16, source_units[start..end], needle_units)) return scalar_index + 1;
        start += codePointLength(source_units, start);
        if (end < source_units.len) end += codePointLength(source_units, end);
    }
    return 0;
}

pub const search_element_limit: usize = 1_000_000;

/// `何文字目` uses `Array.from(value)` and then compares joined windows.  A
/// single concatenated string is not sufficient: a match may start only at
/// an Array.from element boundary (for example, `['AB', 'C']` must not match
/// `BC`).  Keep ordinary values as owned UTF-16 while searching, but retain
/// dictionary array-like values as a lazy indexed view so a first match does
/// not eagerly materialize every missing element.
const SearchElements = struct {
    runtime: *Runtime,
    items: std.ArrayList([]u16) = .empty,
    dictionary: ?Value = null,
    dictionary_length: usize = 0,
    array_buffer: ?Value = null,
    array_buffer_length: usize = 0,

    pub fn deinit(self: *SearchElements) void {
        for (self.items.items) |units| if (units.len != 0) self.runtime.allocator.free(units);
        self.items.deinit(self.runtime.allocator);
        self.* = undefined;
    }

    pub fn len(self: SearchElements) usize {
        if (self.dictionary != null) return self.dictionary_length;
        if (self.array_buffer != null) return self.array_buffer_length;
        return self.items.items.len;
    }

    pub fn element(self: *const SearchElements, index: usize) !SearchElement {
        if (self.dictionary) |dictionary| {
            var key_buffer: [32]u16 = undefined;
            const key = searchIndexKey(&key_buffer, index);
            return SearchElement.fromValue(self.runtime, dictionaryProperty(dictionary, key));
        }
        if (self.array_buffer) |array_buffer| {
            var key_buffer: [32]u16 = undefined;
            const key = searchIndexKey(&key_buffer, index);
            return SearchElement.fromValue(self.runtime, try byteBufferArrayLikeProperty(self.runtime, array_buffer, key));
        }
        return .{ .units = self.items.items[index] };
    }

    pub fn appendEmpty(self: *SearchElements) !void {
        try self.items.append(self.runtime.allocator, &.{});
    }

    pub fn appendOwned(self: *SearchElements, units: []u16) !void {
        errdefer if (units.len != 0) self.runtime.allocator.free(units);
        try self.items.append(self.runtime.allocator, units);
    }

    pub fn appendValue(self: *SearchElements, value: Value) !void {
        const tag: Tag = @enumFromInt(value.tag);
        switch (tag) {
            .undefined, .null_value => try self.appendEmpty(),
            .binding_cell => try self.appendValue(value.object().?.payload.binding_cell),
            else => try self.appendOwned(try valueUtf16Alloc(self.runtime, value)),
        }
    }
};

const SearchElement = struct {
    units: []const u16,
    owned: ?[]u16 = null,

    pub fn fromValue(runtime: *Runtime, value: Value) !SearchElement {
        return switch (@as(Tag, @enumFromInt(value.tag))) {
            .undefined, .null_value => .{ .units = &.{} },
            .binding_cell => try fromValue(runtime, value.object().?.payload.binding_cell),
            else => blk: {
                const units = try valueUtf16Alloc(runtime, value);
                break :blk .{ .units = units, .owned = units };
            },
        };
    }

    pub fn deinit(self: *SearchElement, runtime: *Runtime) void {
        if (self.owned) |units| runtime.allocator.free(units);
        self.* = undefined;
    }
};

pub fn searchArrayFromLength(runtime: *Runtime, value: Value) !usize {
    const number = try valueToNumberRuntime(runtime, value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > @as(f64, @floatFromInt(search_element_limit))) return error.ArraySizeLimitExceeded;
    return @intFromFloat(@trunc(number));
}

pub fn appendStringSearchElements(elements: *SearchElements, value: Value) !void {
    const units = try valueUtf16Alloc(elements.runtime, value);
    defer elements.runtime.allocator.free(units);
    var index: usize = 0;
    while (index < units.len) {
        const length = codePointLength(units, index);
        try elements.appendOwned(try elements.runtime.allocator.dupe(u16, units[index .. index + length]));
        index += length;
    }
}

pub fn appendDictionarySearchElements(elements: *SearchElements, value: Value) !void {
    const length = searchArrayFromLength(elements.runtime, dictionaryProperty(value, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) catch |failure| return failure;
    elements.dictionary = value;
    elements.dictionary_length = length;
}

pub fn byteBufferArrayLikeProperty(runtime: *Runtime, value: Value, key_units: []const u16) !Value {
    const object = value.object() orelse return .{};
    if (runtime.aotObjectOwnPropertyGetUnits(object, key_units)) |property| return property;
    return (try tableInheritedProperty(runtime, value, .byte_buffer, key_units)) orelse .{};
}

pub fn appendArrayBufferSearchElements(elements: *SearchElements, value: Value) !void {
    const length = searchArrayFromLength(elements.runtime, elements.runtime.indexGet(value, staticStringValue("length"))) catch |failure| return failure;
    elements.array_buffer = value;
    elements.array_buffer_length = length;
}

pub fn searchIndexKey(buffer: *[32]u16, index: usize) []const u16 {
    var utf8: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&utf8, "{d}", .{index}) catch unreachable;
    const length = std.unicode.utf8ToUtf16Le(buffer, text) catch unreachable;
    return buffer[0..length];
}

pub fn appendSearchElements(runtime: *Runtime, value: Value) !SearchElements {
    const tag: Tag = @enumFromInt(value.tag);
    if (tag == .null_value) {
        runtime.setFailureText("object null is not iterable (cannot read property Symbol(Symbol.iterator))");
        return error.NakoException;
    }
    if (tag == .undefined) {
        runtime.setFailureText("undefined is not iterable (cannot read property Symbol(Symbol.iterator))");
        return error.NakoException;
    }

    var elements = SearchElements{ .runtime = runtime };
    errdefer elements.deinit();
    switch (tag) {
        .static_utf8_string, .utf16_string => try appendStringSearchElements(&elements, value),
        .byte_buffer => {
            const buffer = value.object().?.payload.byte_buffer;
            if (buffer.kind != .array_buffer) for (buffer.bytes) |byte| try elements.appendValue(numberValue(@floatFromInt(byte)));
            if (buffer.kind == .array_buffer) try appendArrayBufferSearchElements(&elements, value);
        },
        .array => for (value.object().?.payload.array.items) |item| try elements.appendValue(item),
        .dictionary => try appendDictionarySearchElements(&elements, value),
        // The official generated function wrapper is not an iterable or
        // array-like value for this command, so Array.from(function) is []
        // regardless of the source function's language-level arity.
        .function => {},
        else => {},
    }
    return elements;
}

pub fn joinedSearchElementsEqual(runtime: *Runtime, source: SearchElements, start: usize, count: usize, needle: SearchElements) !bool {
    const source_end = start + count;
    var source_index = start;
    var source_offset: usize = 0;
    var needle_index: usize = 0;
    var needle_offset: usize = 0;
    var source_element = SearchElement{ .units = &.{} };
    var source_loaded = false;
    defer if (source_loaded) source_element.deinit(runtime);
    var needle_element = SearchElement{ .units = &.{} };
    var needle_loaded = false;
    defer if (needle_loaded) needle_element.deinit(runtime);

    while (true) {
        while (source_index < source_end and (!source_loaded or source_offset == source_element.units.len)) {
            if (source_loaded) {
                source_element.deinit(runtime);
                source_loaded = false;
            }
            source_element = try source.element(source_index);
            source_loaded = true;
            source_offset = 0;
            source_index += 1;
        }
        while (needle_index < needle.len() and (!needle_loaded or needle_offset == needle_element.units.len)) {
            if (needle_loaded) {
                needle_element.deinit(runtime);
                needle_loaded = false;
            }
            needle_element = try needle.element(needle_index);
            needle_loaded = true;
            needle_offset = 0;
            needle_index += 1;
        }
        const source_done = !source_loaded or (source_index == source_end and source_offset == source_element.units.len);
        const needle_done = !needle_loaded or (needle_index == needle.len() and needle_offset == needle_element.units.len);
        if (source_done or needle_done) return source_done and needle_done;
        if (source_element.units[source_offset] != needle_element.units[needle_offset]) return false;
        source_offset += 1;
        needle_offset += 1;
    }
}

pub fn codePointFindBuiltin(runtime: *Runtime, source: Value, needle: Value) !usize {
    var roots = [_]Value{ source, needle };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    if (isString(roots[0]) and isString(roots[1])) return codePointFindStringBuiltin(runtime, roots[0], roots[1]);

    var source_elements = try appendSearchElements(runtime, roots[0]);
    defer source_elements.deinit();
    var needle_elements = try appendSearchElements(runtime, roots[1]);
    defer needle_elements.deinit();
    const source_length = source_elements.len();
    const needle_length = needle_elements.len();
    var index: usize = 0;
    while (index < source_length) : (index += 1) {
        const count = @min(needle_length, source_length - index);
        if (try joinedSearchElementsEqual(runtime, source_elements, index, count, needle_elements)) return index + 1;
    }
    return 0;
}

pub fn stringBoundaryBuiltin(runtime: *Runtime, source: Value, needle: Value, starts: bool) !Value {
    try requireStringReceiver(source, starts);
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const needle_units = try valueUtf16Alloc(runtime, needle);
    defer runtime.allocator.free(needle_units);
    const matches = if (starts)
        source_units.len >= needle_units.len and std.mem.eql(u16, source_units[0..needle_units.len], needle_units)
    else
        source_units.len >= needle_units.len and std.mem.eql(u16, source_units[source_units.len - needle_units.len ..], needle_units);
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(matches) };
}

pub fn requireStringReceiver(value: Value, starts: bool) !void {
    if (isString(value)) return;
    const tag: Tag = @enumFromInt(value.tag);
    if (starts) return switch (tag) {
        .null_value => error.StartsWithNullReceiver,
        .undefined => error.StartsWithUndefinedReceiver,
        else => error.StartsWithReceiverExpected,
    };
    return switch (tag) {
        .null_value => error.EndsWithNullReceiver,
        .undefined => error.EndsWithUndefinedReceiver,
        else => error.EndsWithReceiverExpected,
    };
}

pub fn elementCountBuiltin(runtime: *Runtime, value: Value) !usize {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .byte_buffer => value.object().?.payload.byte_buffer.bytes.len,
        .array => value.object().?.payload.array.items.len,
        .dictionary => value.object().?.payload.dictionary.items.len,
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk units.len;
        },
        .function, .iterator, .promise => 0,
        .binding_cell => elementCountBuiltin(runtime, value.object().?.payload.binding_cell),
        else => 1,
    };
}

pub fn addParsedBuiltin(runtime: *Runtime, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.bigint) and roots[1].tag != @intFromEnum(Tag.bigint)) {
        return numberValue(try parseFloatBuiltin(runtime, roots[0]) + try parseFloatBuiltin(runtime, roots[1]));
    }
    roots[2] = try toBigIntBuiltin(runtime, roots[0]);
    roots[3] = try toBigIntBuiltin(runtime, roots[1]);
    return bigIntArithmetic(runtime, .add, roots[2], roots[3]);
}

pub fn sumParsedBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len > 0 and arguments[0].tag == @intFromEnum(Tag.array)) {
        var total: f64 = 0;
        for (arguments[0].object().?.payload.array.items) |item| {
            const number = try parseFloatBuiltin(runtime, item);
            if (!std.math.isNan(number)) total += number;
        }
        return numberValue(total);
    }
    var has_bigint = false;
    for (arguments) |argument| if (argument.tag == @intFromEnum(Tag.bigint)) {
        has_bigint = true;
        break;
    };
    if (!has_bigint) {
        var total: f64 = 0;
        for (arguments) |argument| total += try parseFloatBuiltin(runtime, argument);
        return numberValue(total);
    }
    var roots = [_]Value{ try runtime.createBigInt("0n"), .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    for (arguments) |argument| {
        roots[1] = try toBigIntBuiltin(runtime, argument);
        roots[0] = try bigIntArithmetic(runtime, .add, roots[0], roots[1]);
    }
    return roots[0];
}

pub fn toBigIntBuiltin(runtime: *Runtime, value: Value) !Value {
    var roots = [_]Value{ value, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try valueToPrimitive(runtime, roots[0], .number);
    const primitive = roots[1];
    return switch (@as(Tag, @enumFromInt(primitive.tag))) {
        .bigint => primitive,
        .number => runtime.ownBigInt(try BigInt.fromF64(runtime.allocator, @bitCast(primitive.payload))),
        .static_utf8_string, .utf16_string => blk: {
            const converted = try bigIntFromString(runtime, primitive);
            break :blk try runtime.ownBigInt(converted);
        },
        .boolean => runtime.ownBigInt(try BigInt.init(runtime.allocator, @as(u1, @intCast(primitive.payload)))),
        .null_value => error.CannotConvertNullToBigInt,
        .undefined => error.CannotConvertUndefinedToBigInt,
        else => error.InvalidBigIntConversion,
    };
}

pub fn jsAdd(runtime: *Runtime, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try valueToPrimitive(runtime, roots[0], .number);
    roots[3] = try valueToPrimitive(runtime, roots[1], .number);
    if (isString(roots[2]) or isString(roots[3])) return concat(runtime, roots[2], roots[3]);
    if (roots[2].tag == @intFromEnum(Tag.bigint) or roots[3].tag == @intFromEnum(Tag.bigint)) return bigIntArithmetic(runtime, .add, roots[2], roots[3]);
    return numberValue(try valueToNumberRuntime(runtime, roots[2]) + try valueToNumberRuntime(runtime, roots[3]));
}

const CutResult = struct { result: Value, remainder: Value };

/// `切取` and `範囲切取` deliberately use two different lengths for a
/// delimiter: `indexOf` stringifies the argument, but the following
/// `substring(index + delimiter.length)` reads the original value's property.
/// Keep this helper in the AOT runtime so the generated executable does not
/// need a JavaScript compatibility layer.
pub fn cutLengthProperty(runtime: *Runtime, value: Value) !Value {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => error.CutUndefinedDelimiterLength,
        .null_value => error.CutNullDelimiterLength,
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk numberValue(@floatFromInt(units.len));
        },
        .array => numberValue(@floatFromInt(value.object().?.payload.array.items.len)),
        .byte_buffer => if (value.object().?.payload.byte_buffer.kind == .array_buffer) .{} else numberValue(@floatFromInt(value.object().?.payload.byte_buffer.bytes.len)),
        .function => numberValue(@floatFromInt(value.object().?.payload.function.arity)),
        .dictionary => dictionaryLengthValue(value),
        else => .{},
    };
}

pub fn dictionaryLengthValue(value: Value) Value {
    const entries = value.object().?.payload.dictionary.items;
    for (entries) |entry| {
        const is_length = switch (@as(Tag, @enumFromInt(entry.key.tag))) {
            .static_utf8_string => std.mem.eql(u8, staticUtf8(entry.key), "length"),
            .utf16_string => std.mem.eql(u16, entry.key.object().?.payload.utf16_string, &.{ 'l', 'e', 'n', 'g', 't', 'h' }),
            else => false,
        };
        if (is_length) return entry.value;
    }
    return .{};
}

pub fn cutEndIndex(runtime: *Runtime, match_index: usize, delimiter: Value, source_length: usize) !usize {
    const length = try cutLengthProperty(runtime, delimiter);
    const sum = try jsAdd(runtime, numberValue(@floatFromInt(match_index)), length);
    const number = try valueToNumberRuntime(runtime, sum);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(source_length))) return source_length;
    return @intFromFloat(@trunc(number));
}

pub fn cutBuiltin(runtime: *Runtime, source: Value, first: Value, last: ?Value, range: bool) !CutResult {
    var roots = [_]Value{ source, first, last orelse .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const source_units = try valueUtf16Alloc(runtime, roots[0]);
    defer runtime.allocator.free(source_units);
    const first_units = try valueUtf16Alloc(runtime, roots[1]);
    defer runtime.allocator.free(first_units);
    const first_index = indexOfUnitsBuiltin(source_units, first_units, 0);
    if (first_index == null) {
        if (range) {
            roots[3] = try runtime.createString(&.{});
            roots[4] = try runtime.createString(source_units);
        } else {
            roots[3] = try runtime.createString(source_units);
            roots[4] = try runtime.createString(&.{});
        }
        return .{ .result = roots[3], .remainder = roots[4] };
    }
    const first_start = first_index.?;
    const middle_start = try cutEndIndex(runtime, first_start, roots[1], source_units.len);
    if (!range) {
        roots[3] = try runtime.createString(source_units[0..first_start]);
        roots[4] = try runtime.createString(source_units[middle_start..]);
        return .{ .result = roots[3], .remainder = roots[4] };
    }

    // Delimiter B is converted only after A matched.  In particular, a null
    // or undefined B is harmless when A is absent, matching String#indexOf.
    const last_value = roots[2];
    const last_units = try valueUtf16Alloc(runtime, last_value);
    defer runtime.allocator.free(last_units);
    const prefix = source_units[0..first_start];
    const relative_last = indexOfUnitsBuiltin(source_units[middle_start..], last_units, 0);
    if (relative_last == null) {
        roots[3] = try runtime.createString(source_units[middle_start..]);
        roots[4] = try runtime.createString(prefix);
        return .{ .result = roots[3], .remainder = roots[4] };
    }
    const last_relative = relative_last.?;
    const last_end = middle_start + try cutEndIndex(runtime, last_relative, last_value, source_units.len - middle_start);
    roots[3] = try runtime.createString(source_units[middle_start .. middle_start + last_relative]);
    roots[4] = try runtime.createString(prefix);
    if (last_end < source_units.len) {
        const combined_len = std.math.add(usize, prefix.len, source_units.len - last_end) catch return error.StringTooLarge;
        const combined = try runtime.allocator.alloc(u16, combined_len);
        @memcpy(combined[0..prefix.len], prefix);
        @memcpy(combined[prefix.len..], source_units[last_end..]);
        roots[4] = try runtime.ownString(combined);
    }
    return .{ .result = roots[3], .remainder = roots[4] };
}

pub fn sequentialAddBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len == 0) return runtime.systemContext();
    if (arguments.len == 1) return arguments[0];
    var roots = [_]Value{ arguments[1], .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    for (arguments[2..]) |argument| roots[0] = try jsAdd(runtime, roots[0], argument);
    roots[1] = try jsAdd(runtime, roots[0], arguments[0]);
    return roots[1];
}

pub fn chrBuiltin(runtime: *Runtime, value: Value) !Value {
    if (value.tag != @intFromEnum(Tag.array)) return codePointStringBuiltin(runtime, try valueToNumberRuntime(runtime, value));
    var roots = [_]Value{ value, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    for (roots[0].object().?.payload.array.items) |item| {
        roots[2] = try codePointStringBuiltin(runtime, try valueToNumberRuntime(runtime, item));
        try roots[1].object().?.payload.array.append(runtime.allocator, roots[2]);
    }
    return roots[1];
}

pub fn codePointStringBuiltin(runtime: *Runtime, number: f64) !Value {
    if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or number > 0x10ffff) {
        const number_text = try number_mod.toStringAlloc(runtime.allocator, number);
        defer runtime.allocator.free(number_text);
        const message = try std.fmt.allocPrint(runtime.allocator, "Invalid code point {s}", .{number_text});
        defer runtime.allocator.free(message);
        runtime.setFailureText(message);
        return error.NakoException;
    }
    const codepoint: u21 = @intFromFloat(number);
    if (codepoint <= 0xffff) return runtime.createString(&.{@intCast(codepoint)});
    const offset: u32 = codepoint - 0x10000;
    return runtime.createString(&.{ @intCast(0xd800 + (offset >> 10)), @intCast(0xdc00 + (offset & 0x3ff)) });
}

pub fn ascBuiltin(runtime: *Runtime, value: Value) !Value {
    if (value.tag != @intFromEnum(Tag.array)) return numberValue(@floatFromInt(try firstCodePointBuiltin(runtime, value)));
    var roots = [_]Value{ value, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    for (roots[0].object().?.payload.array.items) |item| {
        try roots[1].object().?.payload.array.append(runtime.allocator, numberValue(@floatFromInt(try firstCodePointBuiltin(runtime, item))));
    }
    return roots[1];
}

pub fn firstCodePointBuiltin(runtime: *Runtime, value: Value) !u21 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    if (units.len == 0) return 0;
    if (units[0] >= 0xd800 and units[0] <= 0xdbff and units.len > 1 and units[1] >= 0xdc00 and units[1] <= 0xdfff) {
        return @intCast(0x10000 + ((@as(u32, units[0]) - 0xd800) << 10) + (@as(u32, units[1]) - 0xdc00));
    }
    return @intCast(units[0]);
}

pub fn stringInsertBuiltin(runtime: *Runtime, source_value: Value, position_value: Value, addition_value: Value) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const addition = try valueUtf16Alloc(runtime, addition_value);
    defer runtime.allocator.free(addition);
    var position = try valueToNumberRuntime(runtime, position_value);
    if (position <= 0) position = 1;
    const scalar_index = stringCollectionIndex(position - 1, codePointCount(source));
    const unit_index = codePointOffsetBuiltin(source, scalar_index);
    const output = try runtime.allocator.alloc(u16, source.len + addition.len);
    @memcpy(output[0..unit_index], source[0..unit_index]);
    @memcpy(output[unit_index .. unit_index + addition.len], addition);
    @memcpy(output[unit_index + addition.len ..], source[unit_index..]);
    return runtime.ownString(output);
}

pub fn stringSearchBuiltin(runtime: *Runtime, source_value: Value, start_value: Value, needle_value: Value) !f64 {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const needle = try valueUtf16Alloc(runtime, needle_value);
    defer runtime.allocator.free(needle);
    var start = try valueToNumberRuntime(runtime, start_value);
    if (start <= 0) start = 1;
    var index = start - 1;
    const source_count = codePointCount(source);
    const needle_count = codePointCount(needle);
    while (index < @as(f64, @floatFromInt(source_count))) : (index += 1) {
        const scalar_index = stringCollectionIndex(index, source_count);
        const unit_start = codePointOffsetBuiltin(source, scalar_index);
        const unit_end = codePointOffsetBuiltin(source, @min(source_count, scalar_index +| needle_count));
        if (std.mem.eql(u16, source[unit_start..unit_end], needle)) return index + 1;
    }
    return 0;
}

pub fn codePointOffsetBuiltin(units: []const u16, target: usize) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < units.len and count < target) : (count += 1) index += codePointLength(units, index);
    return index;
}

pub fn stringCollectionIndex(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(@trunc(number));
}

pub fn appendBuiltin(runtime: *Runtime, source: Value, addition: Value, newline: bool) !Value {
    if (source.tag == @intFromEnum(Tag.array)) {
        try source.object().?.payload.array.append(runtime.allocator, addition);
        return source;
    }
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const addition_units = try valueUtf16Alloc(runtime, addition);
    defer runtime.allocator.free(addition_units);
    const extra: usize = @intFromBool(newline);
    const base_length = std.math.add(usize, source_units.len, addition_units.len) catch return error.StringTooLarge;
    const length = std.math.add(usize, base_length, extra) catch return error.StringTooLarge;
    const output = try runtime.allocator.alloc(u16, length);
    @memcpy(output[0..source_units.len], source_units);
    @memcpy(output[source_units.len .. source_units.len + addition_units.len], addition_units);
    if (newline) output[output.len - 1] = '\n';
    return runtime.ownString(output);
}

pub fn joinBuiltin(runtime: *Runtime, values: []const Value) !Value {
    var units: std.ArrayList(u16) = .empty;
    errdefer units.deinit(runtime.allocator);
    for (values) |value| switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined, .null_value => {},
        else => {
            const part = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(part);
            try units.appendSlice(runtime.allocator, part);
        },
    };
    return runtime.ownString(try units.toOwnedSlice(runtime.allocator));
}

/// `配列結合` is intentionally separate from `連結`.  The former delegates
/// to JavaScript's Array.join when its first value is an array, while the
/// official plugin also accepts other values by splitting their String form
/// at LF before joining.  `配列只結合` is the same operation with an empty
/// separator.
pub fn arrayJoinBuiltin(runtime: *Runtime, source: Value, separator: Value, only: bool) !Value {
    var separator_units: []const u16 = &.{};
    var allocated_separator: ?[]u16 = null;
    defer if (allocated_separator) |units| runtime.allocator.free(units);
    if (!only) {
        allocated_separator = try valueUtf16Alloc(runtime, separator);
        separator_units = allocated_separator.?;
    }

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    if (source.tag == @intFromEnum(Tag.array)) {
        const object = source.object() orelse return error.InvalidArray;
        if (object.payload != .array) return error.InvalidArray;
        for (object.payload.array.items, 0..) |item, index| {
            if (index > 0) try output.appendSlice(runtime.allocator, separator_units);
            if (item.tag == @intFromEnum(Tag.undefined) or item.tag == @intFromEnum(Tag.null_value)) continue;
            const item_units = try valueUtf16Alloc(runtime, item);
            defer runtime.allocator.free(item_units);
            try output.appendSlice(runtime.allocator, item_units);
        }
    } else {
        const source_units = try valueUtf16Alloc(runtime, source);
        defer runtime.allocator.free(source_units);
        // String(a).split("\n").join(separator) preserves empty pieces at
        // both ends, including the trailing piece after a final LF.
        var start: usize = 0;
        var first = true;
        for (source_units, 0..) |unit, index| {
            if (unit != '\n') continue;
            if (!first) try output.appendSlice(runtime.allocator, separator_units);
            try output.appendSlice(runtime.allocator, source_units[start..index]);
            start = index + 1;
            first = false;
        }
        if (!first) try output.appendSlice(runtime.allocator, separator_units);
        try output.appendSlice(runtime.allocator, source_units[start..]);
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn arraySearchBuiltin(runtime: *Runtime, source: Value, needle: Value) !f64 {
    if (source.tag != @intFromEnum(Tag.array)) return -1;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    for (object.payload.array.items, 0..) |item, index| {
        if (!runtime.aotArrayIsPresent(object, index)) continue;
        if (try strictEqual(runtime, item, needle)) return @floatFromInt(index);
    }
    return -1;
}

pub fn arrayOrderingBuiltin(runtime: *Runtime, command: aot_builtin.Command, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    const items = &object.payload.array;
    switch (command) {
        .array_reverse => {
            try runtime.normalizeAotArrayPresence(object);
            std.mem.reverse(Value, items.items);
            std.mem.reverse(bool, object.array_presence.items);
            return source;
        },
        .array_numeric_convert => {
            var source_root = source;
            var roots = RootFrame{};
            runtime.pushRoots(&roots, @ptrCast(&source_root), 1);
            defer runtime.popRoots(&roots);
            try runtime.normalizeAotArrayPresence(object);
            for (items.items, 0..) |*item, index| {
                item.* = numberValue(try parseFloatBuiltin(runtime, item.*));
                // Assignment through every indexed position materializes a
                // hole as the parsed value of undefined (NaN).
                object.array_presence.items[index] = true;
            }
            return source_root;
        },
        .array_sort, .array_numeric_sort => return try stableArraySort(runtime, source, command == .array_numeric_sort),
        .array_shuffle => return try arrayShuffleBuiltin(runtime, source),
        else => unreachable,
    }
}

pub fn arrayShuffleBuiltin(runtime: *Runtime, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    try runtime.normalizeAotArrayPresence(object);
    var index = object.payload.array.items.len;
    while (index > 1) {
        index -= 1;
        const random_index: usize = @intFromFloat(@floor(nextRandom(runtime) * @as(f64, @floatFromInt(index + 1))));
        std.mem.swap(Value, &object.payload.array.items[index], &object.payload.array.items[random_index]);
        // The upstream implementation uses two indexed assignments.  A hole
        // reads as undefined, while both assignment targets become present.
        object.array_presence.items[index] = true;
        object.array_presence.items[random_index] = true;
    }
    return source;
}

pub fn arrayCallbackBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    var roots = [_]Value{ arguments[0], arguments[1], .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try resolveAotCallback(runtime, roots[0]);
    _ = try arrayItems(roots[1]);
    if (command == .array_custom_sort) return try stableArrayCallbackSort(runtime, roots[1], roots[0]);

    roots[2] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[2]);
    var index: usize = 0;
    while (index < (try arrayItems(roots[1])).items.len) : (index += 1) {
        const item = (try arrayItems(roots[1])).items[index];
        roots[3] = item;
        const mapped = try invokeAotCallback(runtime, roots[0], @ptrCast(&roots[3]), 1);
        roots[3] = mapped;
        if (command != .array_filter or valueTruthy(mapped)) try result.append(runtime.allocator, if (command == .array_filter) item else mapped);
    }
    return roots[2];
}

pub fn stableArrayCallbackSort(runtime: *Runtime, source: Value, callable: Value) !Value {
    const items = try arrayItems(source);
    const original_length = items.items.len;
    if (original_length < 2) return source;

    const object = source.object() orelse return error.InvalidArray;
    try runtime.normalizeAotArrayPresence(object);

    const first = try runtime.allocator.dupe(Value, items.items);
    defer runtime.allocator.free(first);
    const second = try runtime.allocator.dupe(Value, first);
    defer runtime.allocator.free(second);
    const first_presence = try runtime.allocator.dupe(bool, object.array_presence.items);
    defer runtime.allocator.free(first_presence);
    const second_presence = try runtime.allocator.dupe(bool, first_presence);
    defer runtime.allocator.free(second_presence);

    const root_count = std.math.add(usize, 4, std.math.mul(usize, original_length, 2) catch return error.ArrayTooLarge) catch return error.ArrayTooLarge;
    const root_values = try runtime.allocator.alloc(Value, root_count);
    defer runtime.allocator.free(root_values);
    root_values[0] = source;
    root_values[1] = callable;
    root_values[2] = .{};
    root_values[3] = .{};
    std.mem.copyForwards(Value, root_values[4 .. 4 + original_length], first);
    std.mem.copyForwards(Value, root_values[4 + original_length ..], second);
    var roots = RootFrame{};
    runtime.pushRoots(&roots, root_values.ptr, root_values.len);
    defer runtime.popRoots(&roots);
    var sort_context = V8SortContext{ .callback = .{
        .callable_root = &root_values[1],
        .result_root = &root_values[2],
    } };

    if (original_length < v8_small_callback_sort_limit) {
        try v8SmallArrayCallbackSort(runtime, first, first_presence, &root_values[1], &root_values[2], &root_values[3]);
    } else {
        try v8TimSortArrayCallback(runtime, first, first_presence, second, second_presence, &sort_context, &root_values[3]);
    }

    if (items.items.len < original_length) {
        const old_length = items.items.len;
        try items.resize(runtime.allocator, original_length);
        @memset(items.items[old_length..], .{});
        try object.array_presence.resize(runtime.allocator, original_length);
        @memset(object.array_presence.items[old_length..], false);
    }
    std.mem.copyForwards(Value, items.items[0..original_length], first);
    std.mem.copyForwards(bool, object.array_presence.items[0..original_length], first_presence);
    return root_values[0];
}

const v8_small_callback_sort_limit: usize = 64;
const v8_timsort_max_pending_runs: usize = 85;
const v8_timsort_min_gallop: usize = 7;

const V8ArraySortRun = struct {
    base: usize,
    length: usize,
};

const V8TableSortContext = struct {
    column_root: *Value,
    numeric: bool,
    left_cell_root: *Value,
    right_cell_root: *Value,
};

const V8SortContext = union(enum) {
    callback: struct {
        callable_root: *Value,
        result_root: *Value,
    },
    table: V8TableSortContext,
};

pub fn compareV8Sort(
    runtime: *Runtime,
    left: Value,
    left_present: bool,
    right: Value,
    right_present: bool,
    context: *V8SortContext,
) !std.math.Order {
    return switch (context.*) {
        .callback => |callback| compareAotCallback(
            runtime,
            callback.callable_root.*,
            left,
            left_present,
            right,
            right_present,
            callback.result_root,
        ),
        .table => |table| compareTableRowsBuiltin(
            runtime,
            left,
            left_present,
            right,
            right_present,
            table.column_root.*,
            table.numeric,
            table.left_cell_root,
            table.right_cell_root,
        ),
    };
}

pub fn v8SmallArrayCallbackSort(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    callable_root: *Value,
    result_root: *Value,
    pivot_root: *Value,
) !void {
    // V8 uses CountAndMakeRun followed by BinaryInsertionSort when the
    // receiver length is below 64. The collected AOT values stay detached
    // from the live array until stableArrayCallbackSort commits the result.
    if (items.len < 2) return;

    var run_length: usize = 2;
    const first_order = try compareAotCallback(runtime, callable_root.*, items[1], presence[1], items[0], presence[0], result_root);
    if (first_order == .lt) {
        while (run_length < items.len) : (run_length += 1) {
            const order = try compareAotCallback(runtime, callable_root.*, items[run_length], presence[run_length], items[run_length - 1], presence[run_length - 1], result_root);
            if (order != .lt) break;
        }
        var left: usize = 0;
        var right: usize = run_length - 1;
        while (left < right) : ({
            left += 1;
            right -= 1;
        }) {
            std.mem.swap(Value, &items[left], &items[right]);
            std.mem.swap(bool, &presence[left], &presence[right]);
        }
    } else {
        while (run_length < items.len) : (run_length += 1) {
            const order = try compareAotCallback(runtime, callable_root.*, items[run_length], presence[run_length], items[run_length - 1], presence[run_length - 1], result_root);
            if (order == .lt) break;
        }
    }

    var start = run_length;
    while (start < items.len) : (start += 1) {
        pivot_root.* = items[start];
        const pivot_presence = presence[start];
        var left: usize = 0;
        var right: usize = start;
        while (left < right) {
            const middle = left + (right - left) / 2;
            const order = try compareAotCallback(runtime, callable_root.*, pivot_root.*, pivot_presence, items[middle], presence[middle], result_root);
            if (order == .lt) right = middle else left = middle + 1;
        }
        var cursor = start;
        while (cursor > left) : (cursor -= 1) {
            items[cursor] = items[cursor - 1];
            presence[cursor] = presence[cursor - 1];
        }
        items[left] = pivot_root.*;
        presence[left] = pivot_presence;
    }
}

pub fn v8CopyArrayRange(comptime T: type, destination: []T, destination_index: usize, source: []const T, source_index: usize, length: usize) void {
    if (length == 0) return;
    if (@intFromPtr(destination.ptr) == @intFromPtr(source.ptr) and destination_index > source_index) {
        var offset = length;
        while (offset > 0) {
            offset -= 1;
            destination[destination_index + offset] = source[source_index + offset];
        }
    } else {
        std.mem.copyForwards(T, destination[destination_index .. destination_index + length], source[source_index .. source_index + length]);
    }
}

pub fn v8ComputeMinRunLengthArray(length: usize) usize {
    var n = length;
    var remainder: usize = 0;
    while (n >= 64) {
        remainder |= n & 1;
        n >>= 1;
    }
    return n + remainder;
}

pub fn v8CountAndMakeRunArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    low: usize,
    high: usize,
    context: *V8SortContext,
) !usize {
    if (low + 1 == high) return 1;

    var run_length: usize = 2;
    const first_order = try compareV8Sort(runtime, items[low + 1], presence[low + 1], items[low], presence[low], context);
    const descending = first_order == .lt;
    while (low + run_length < high) : (run_length += 1) {
        const order = try compareV8Sort(
            runtime,
            items[low + run_length],
            presence[low + run_length],
            items[low + run_length - 1],
            presence[low + run_length - 1],
            context,
        );
        if (descending) {
            if (order != .lt) break;
        } else if (order == .lt) {
            break;
        }
    }

    if (descending) {
        var left = low;
        var right = low + run_length - 1;
        while (left < right) : ({
            left += 1;
            right -= 1;
        }) {
            std.mem.swap(Value, &items[left], &items[right]);
            std.mem.swap(bool, &presence[left], &presence[right]);
        }
    }
    return run_length;
}

pub fn v8BinaryInsertionSortArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    low: usize,
    start_argument: usize,
    high: usize,
    context: *V8SortContext,
    pivot_root: *Value,
) !void {
    var start = if (low == start_argument) start_argument + 1 else start_argument;
    while (start < high) : (start += 1) {
        pivot_root.* = items[start];
        const pivot_present = presence[start];
        var left = low;
        var right = start;
        while (left < right) {
            const middle = left + (right - left) / 2;
            const order = try compareV8Sort(runtime, pivot_root.*, pivot_present, items[middle], presence[middle], context);
            if (order == .lt) right = middle else left = middle + 1;
        }
        var cursor = start;
        while (cursor > left) : (cursor -= 1) {
            items[cursor] = items[cursor - 1];
            presence[cursor] = presence[cursor - 1];
        }
        items[left] = pivot_root.*;
        presence[left] = pivot_present;
    }
}

pub fn v8GallopLeftArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    key: *Value,
    key_present: bool,
    base: usize,
    length: usize,
    hint: usize,
    context: *V8SortContext,
) !usize {
    var key_root = key.*;
    var key_frame = RootFrame{};
    runtime.pushRoots(&key_frame, @ptrCast(&key_root), 1);
    defer runtime.popRoots(&key_frame);

    var last_offset: isize = 0;
    var offset: isize = 1;
    const initial_order = try compareV8Sort(runtime, items[base + hint], presence[base + hint], key_root, key_present, context);
    if (initial_order == .lt) {
        const max_offset: isize = @intCast(length - hint);
        while (offset < max_offset) {
            const index: usize = base + hint + @as(usize, @intCast(offset));
            const order = try compareV8Sort(runtime, items[index], presence[index], key_root, key_present, context);
            if (order != .lt) break;
            last_offset = offset;
            offset = (offset << 1) + 1;
        }
        if (offset > max_offset) offset = max_offset;
        last_offset += @intCast(hint);
        offset += @intCast(hint);
    } else {
        const max_offset: isize = @intCast(hint + 1);
        while (offset < max_offset) {
            const index: usize = base + hint - @as(usize, @intCast(offset));
            const order = try compareV8Sort(runtime, items[index], presence[index], key_root, key_present, context);
            if (order == .lt) break;
            last_offset = offset;
            offset = (offset << 1) + 1;
        }
        if (offset > max_offset) offset = max_offset;
        const previous = last_offset;
        last_offset = @as(isize, @intCast(hint)) - offset;
        offset = @as(isize, @intCast(hint)) - previous;
    }

    last_offset += 1;
    while (last_offset < offset) {
        const middle: usize = @intCast(last_offset + @divTrunc(offset - last_offset, 2));
        const index = base + middle;
        const order = try compareV8Sort(runtime, items[index], presence[index], key_root, key_present, context);
        if (order == .lt) last_offset = @intCast(middle + 1) else offset = @intCast(middle);
    }
    return @intCast(offset);
}

pub fn v8GallopRightArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    key: *Value,
    key_present: bool,
    base: usize,
    length: usize,
    hint: usize,
    context: *V8SortContext,
) !usize {
    var key_root = key.*;
    var key_frame = RootFrame{};
    runtime.pushRoots(&key_frame, @ptrCast(&key_root), 1);
    defer runtime.popRoots(&key_frame);

    var last_offset: isize = 0;
    var offset: isize = 1;
    const initial_order = try compareV8Sort(runtime, key_root, key_present, items[base + hint], presence[base + hint], context);
    if (initial_order == .lt) {
        const max_offset: isize = @intCast(hint + 1);
        while (offset < max_offset) {
            const index: usize = base + hint - @as(usize, @intCast(offset));
            const order = try compareV8Sort(runtime, key_root, key_present, items[index], presence[index], context);
            if (order != .lt) break;
            last_offset = offset;
            offset = (offset << 1) + 1;
        }
        if (offset > max_offset) offset = max_offset;
        const previous = last_offset;
        last_offset = @as(isize, @intCast(hint)) - offset;
        offset = @as(isize, @intCast(hint)) - previous;
    } else {
        const max_offset: isize = @intCast(length - hint);
        while (offset < max_offset) {
            const index: usize = base + hint + @as(usize, @intCast(offset));
            const order = try compareV8Sort(runtime, key_root, key_present, items[index], presence[index], context);
            if (order == .lt) break;
            last_offset = offset;
            offset = (offset << 1) + 1;
        }
        if (offset > max_offset) offset = max_offset;
        last_offset += @intCast(hint);
        offset += @intCast(hint);
    }

    last_offset += 1;
    while (last_offset < offset) {
        const middle: usize = @intCast(last_offset + @divTrunc(offset - last_offset, 2));
        const index = base + middle;
        const order = try compareV8Sort(runtime, key_root, key_present, items[index], presence[index], context);
        if (order == .lt) offset = @intCast(middle) else last_offset = @intCast(middle + 1);
    }
    return @intCast(offset);
}

pub fn v8MergeLowArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    base_a: usize,
    length_a_argument: usize,
    base_b: usize,
    length_b_argument: usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    var length_a = length_a_argument;
    var length_b = length_b_argument;
    v8CopyArrayRange(Value, temp, 0, items, base_a, length_a);
    v8CopyArrayRange(bool, temp_presence, 0, presence, base_a, length_a);

    var destination = base_a;
    var cursor_temp: usize = 0;
    var cursor_b = base_b;
    items[destination] = items[cursor_b];
    presence[destination] = presence[cursor_b];
    destination += 1;
    cursor_b += 1;
    length_b -= 1;
    if (length_b == 0) {
        v8CopyArrayRange(Value, items, destination, temp, cursor_temp, length_a);
        v8CopyArrayRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
        return;
    }
    if (length_a == 1) {
        v8CopyArrayRange(Value, items, destination, items, cursor_b, length_b);
        v8CopyArrayRange(bool, presence, destination, presence, cursor_b, length_b);
        items[destination + length_b] = temp[cursor_temp];
        presence[destination + length_b] = temp_presence[cursor_temp];
        return;
    }

    var min_gallop = min_gallop_state.*;
    while (true) {
        var wins_a: usize = 0;
        var wins_b: usize = 0;
        while (true) {
            const order = try compareV8Sort(runtime, items[cursor_b], presence[cursor_b], temp[cursor_temp], temp_presence[cursor_temp], context);
            if (order == .lt) {
                items[destination] = items[cursor_b];
                presence[destination] = presence[cursor_b];
                destination += 1;
                cursor_b += 1;
                length_b -= 1;
                wins_b += 1;
                wins_a = 0;
                if (length_b == 0) {
                    v8CopyArrayRange(Value, items, destination, temp, cursor_temp, length_a);
                    v8CopyArrayRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
                    min_gallop_state.* = min_gallop;
                    return;
                }
                if (wins_b >= min_gallop) break;
            } else {
                items[destination] = temp[cursor_temp];
                presence[destination] = temp_presence[cursor_temp];
                destination += 1;
                cursor_temp += 1;
                length_a -= 1;
                wins_a += 1;
                wins_b = 0;
                if (length_a == 1) {
                    v8CopyArrayRange(Value, items, destination, items, cursor_b, length_b);
                    v8CopyArrayRange(bool, presence, destination, presence, cursor_b, length_b);
                    items[destination + length_b] = temp[cursor_temp];
                    presence[destination + length_b] = temp_presence[cursor_temp];
                    min_gallop_state.* = min_gallop;
                    return;
                }
                if (wins_a >= min_gallop) break;
            }
        }

        min_gallop += 1;
        var first_iteration = true;
        while (wins_a >= v8_timsort_min_gallop or wins_b >= v8_timsort_min_gallop or first_iteration) {
            first_iteration = false;
            min_gallop = @max(@as(usize, 1), min_gallop -| 1);
            min_gallop_state.* = min_gallop;
            wins_a = try v8GallopRightArrayCallback(
                runtime,
                temp,
                temp_presence,
                &items[cursor_b],
                presence[cursor_b],
                cursor_temp,
                length_a,
                0,
                context,
            );
            if (wins_a > 0) {
                v8CopyArrayRange(Value, items, destination, temp, cursor_temp, wins_a);
                v8CopyArrayRange(bool, presence, destination, temp_presence, cursor_temp, wins_a);
                destination += wins_a;
                cursor_temp += wins_a;
                length_a -= wins_a;
                if (length_a == 1) {
                    v8CopyArrayRange(Value, items, destination, items, cursor_b, length_b);
                    v8CopyArrayRange(bool, presence, destination, presence, cursor_b, length_b);
                    items[destination + length_b] = temp[cursor_temp];
                    presence[destination + length_b] = temp_presence[cursor_temp];
                    return;
                }
                if (length_a == 0) return;
            }
            items[destination] = items[cursor_b];
            presence[destination] = presence[cursor_b];
            destination += 1;
            cursor_b += 1;
            length_b -= 1;
            if (length_b == 0) {
                v8CopyArrayRange(Value, items, destination, temp, cursor_temp, length_a);
                v8CopyArrayRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
                return;
            }

            wins_b = try v8GallopLeftArrayCallback(
                runtime,
                items,
                presence,
                &temp[cursor_temp],
                temp_presence[cursor_temp],
                cursor_b,
                length_b,
                0,
                context,
            );
            if (wins_b > 0) {
                v8CopyArrayRange(Value, items, destination, items, cursor_b, wins_b);
                v8CopyArrayRange(bool, presence, destination, presence, cursor_b, wins_b);
                destination += wins_b;
                cursor_b += wins_b;
                length_b -= wins_b;
                if (length_b == 0) {
                    v8CopyArrayRange(Value, items, destination, temp, cursor_temp, length_a);
                    v8CopyArrayRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
                    return;
                }
            }
            items[destination] = temp[cursor_temp];
            presence[destination] = temp_presence[cursor_temp];
            destination += 1;
            cursor_temp += 1;
            length_a -= 1;
            if (length_a == 1) {
                v8CopyArrayRange(Value, items, destination, items, cursor_b, length_b);
                v8CopyArrayRange(bool, presence, destination, presence, cursor_b, length_b);
                items[destination + length_b] = temp[cursor_temp];
                presence[destination + length_b] = temp_presence[cursor_temp];
                return;
            }
        }
        min_gallop += 1;
        min_gallop_state.* = min_gallop;
    }
}

pub fn v8MergeHighArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    base_a: usize,
    length_a_argument: usize,
    base_b: usize,
    length_b_argument: usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    var length_a = length_a_argument;
    var length_b = length_b_argument;
    v8CopyArrayRange(Value, temp, 0, items, base_b, length_b);
    v8CopyArrayRange(bool, temp_presence, 0, presence, base_b, length_b);

    var destination = base_b + length_b - 1;
    var cursor_temp = length_b - 1;
    var cursor_a = base_a + length_a - 1;
    items[destination] = items[cursor_a];
    presence[destination] = presence[cursor_a];
    destination -= 1;
    cursor_a -= 1;
    length_a -= 1;
    if (length_a == 0) {
        v8CopyArrayRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
        v8CopyArrayRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
        return;
    }
    if (length_b == 1) {
        destination -= length_a;
        const source_a = cursor_a - (length_a - 1);
        v8CopyArrayRange(Value, items, destination + 1, items, source_a, length_a);
        v8CopyArrayRange(bool, presence, destination + 1, presence, source_a, length_a);
        items[destination] = temp[cursor_temp];
        presence[destination] = temp_presence[cursor_temp];
        return;
    }

    var min_gallop = min_gallop_state.*;
    while (true) {
        var wins_a: usize = 0;
        var wins_b: usize = 0;
        while (true) {
            const order = try compareV8Sort(runtime, temp[cursor_temp], temp_presence[cursor_temp], items[cursor_a], presence[cursor_a], context);
            if (order == .lt) {
                items[destination] = items[cursor_a];
                presence[destination] = presence[cursor_a];
                destination -= 1;
                length_a -= 1;
                wins_a += 1;
                wins_b = 0;
                if (length_a == 0) {
                    v8CopyArrayRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                    v8CopyArrayRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
                    min_gallop_state.* = min_gallop;
                    return;
                }
                cursor_a -= 1;
                if (wins_a >= min_gallop) break;
            } else {
                items[destination] = temp[cursor_temp];
                presence[destination] = temp_presence[cursor_temp];
                destination -= 1;
                cursor_temp -= 1;
                length_b -= 1;
                wins_b += 1;
                wins_a = 0;
                if (length_b == 1) {
                    destination -= length_a;
                    const source_a = cursor_a - (length_a - 1);
                    v8CopyArrayRange(Value, items, destination + 1, items, source_a, length_a);
                    v8CopyArrayRange(bool, presence, destination + 1, presence, source_a, length_a);
                    items[destination] = temp[cursor_temp];
                    presence[destination] = temp_presence[cursor_temp];
                    min_gallop_state.* = min_gallop;
                    return;
                }
                if (wins_b >= min_gallop) break;
            }
        }

        min_gallop += 1;
        var first_iteration = true;
        while (wins_a >= v8_timsort_min_gallop or wins_b >= v8_timsort_min_gallop or first_iteration) {
            first_iteration = false;
            min_gallop = @max(@as(usize, 1), min_gallop -| 1);
            min_gallop_state.* = min_gallop;
            const gallop_index = try v8GallopRightArrayCallback(
                runtime,
                items,
                presence,
                &temp[cursor_temp],
                temp_presence[cursor_temp],
                base_a,
                length_a,
                length_a - 1,
                context,
            );
            wins_a = length_a - gallop_index;
            if (wins_a > 0) {
                if (wins_a == length_a) {
                    destination -= length_a;
                    const source_a = cursor_a - (length_a - 1);
                    v8CopyArrayRange(Value, items, destination + 1, items, source_a, length_a);
                    v8CopyArrayRange(bool, presence, destination + 1, presence, source_a, length_a);
                    v8CopyArrayRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                    v8CopyArrayRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
                    return;
                }
                destination -= wins_a;
                cursor_a -= wins_a;
                v8CopyArrayRange(Value, items, destination + 1, items, cursor_a + 1, wins_a);
                v8CopyArrayRange(bool, presence, destination + 1, presence, cursor_a + 1, wins_a);
                length_a -= wins_a;
                if (length_a == 0) {
                    v8CopyArrayRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                    v8CopyArrayRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
                    return;
                }
            }
            items[destination] = temp[cursor_temp];
            presence[destination] = temp_presence[cursor_temp];
            destination -= 1;
            cursor_temp -= 1;
            length_b -= 1;
            if (length_b == 1) {
                destination -= length_a;
                const source_a = cursor_a - (length_a - 1);
                v8CopyArrayRange(Value, items, destination + 1, items, source_a, length_a);
                v8CopyArrayRange(bool, presence, destination + 1, presence, source_a, length_a);
                items[destination] = temp[cursor_temp];
                presence[destination] = temp_presence[cursor_temp];
                return;
            }

            const gallop_left = try v8GallopLeftArrayCallback(
                runtime,
                temp,
                temp_presence,
                &items[cursor_a],
                presence[cursor_a],
                0,
                length_b,
                length_b - 1,
                context,
            );
            wins_b = length_b - gallop_left;
            if (wins_b > 0) {
                if (wins_b == length_b) {
                    destination -= length_b;
                    v8CopyArrayRange(Value, items, destination + 1, temp, 0, length_b);
                    v8CopyArrayRange(bool, presence, destination + 1, temp_presence, 0, length_b);
                    return;
                }
                destination -= wins_b;
                cursor_temp -= wins_b;
                v8CopyArrayRange(Value, items, destination + 1, temp, cursor_temp + 1, wins_b);
                v8CopyArrayRange(bool, presence, destination + 1, temp_presence, cursor_temp + 1, wins_b);
                length_b -= wins_b;
                if (length_b == 1) {
                    destination -= length_a;
                    const source_a = cursor_a - (length_a - 1);
                    v8CopyArrayRange(Value, items, destination + 1, items, source_a, length_a);
                    v8CopyArrayRange(bool, presence, destination + 1, presence, source_a, length_a);
                    items[destination] = temp[cursor_temp];
                    presence[destination] = temp_presence[cursor_temp];
                    return;
                }
                if (length_b == 0) {
                    return;
                }
            }
            items[destination] = items[cursor_a];
            presence[destination] = presence[cursor_a];
            destination -= 1;
            length_a -= 1;
            if (length_a == 0) {
                v8CopyArrayRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                v8CopyArrayRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
                return;
            }
            cursor_a -= 1;
        }
        min_gallop += 1;
        min_gallop_state.* = min_gallop;
    }
}

pub fn v8MergeAtArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    runs: []V8ArraySortRun,
    run_count: *usize,
    index: usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    const stack_size = run_count.*;
    var base_a = runs[index].base;
    var length_a = runs[index].length;
    const base_b = runs[index + 1].base;
    var length_b = runs[index + 1].length;
    runs[index].length = length_a + length_b;
    if (stack_size >= 3 and index == stack_size - 3) runs[index + 1] = runs[index + 2];
    run_count.* = stack_size - 1;

    const key_right = try v8GallopRightArrayCallback(
        runtime,
        items,
        presence,
        &items[base_b],
        presence[base_b],
        base_a,
        length_a,
        0,
        context,
    );
    base_a += key_right;
    length_a -= key_right;
    if (length_a == 0) return;
    length_b = try v8GallopLeftArrayCallback(
        runtime,
        items,
        presence,
        &items[base_a + length_a - 1],
        presence[base_a + length_a - 1],
        base_b,
        length_b,
        length_b - 1,
        context,
    );
    if (length_b == 0) return;
    if (length_a <= length_b) {
        try v8MergeLowArrayCallback(runtime, items, presence, temp, temp_presence, base_a, length_a, base_b, length_b, context, min_gallop_state);
    } else {
        try v8MergeHighArrayCallback(runtime, items, presence, temp, temp_presence, base_a, length_a, base_b, length_b, context, min_gallop_state);
    }
}

pub fn v8RunInvariantEstablishedArray(runs: []const V8ArraySortRun, index: usize) bool {
    if (index < 2) return true;
    if (runs[index - 2].length <= runs[index - 1].length) return false;
    return runs[index - 2].length - runs[index - 1].length > runs[index].length;
}

pub fn v8MergeCollapseArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    runs: []V8ArraySortRun,
    run_count: *usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    while (run_count.* > 1) {
        var index = run_count.* - 2;
        if (!v8RunInvariantEstablishedArray(runs, index + 1) or !v8RunInvariantEstablishedArray(runs, index)) {
            if (index > 0 and runs[index - 1].length < runs[index + 1].length) index -= 1;
            try v8MergeAtArrayCallback(runtime, items, presence, temp, temp_presence, runs, run_count, index, context, min_gallop_state);
        } else if (runs[index].length <= runs[index + 1].length) {
            try v8MergeAtArrayCallback(runtime, items, presence, temp, temp_presence, runs, run_count, index, context, min_gallop_state);
        } else {
            break;
        }
    }
}

pub fn v8MergeForceCollapseArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    runs: []V8ArraySortRun,
    run_count: *usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    while (run_count.* > 1) {
        var index = run_count.* - 2;
        if (index > 0 and runs[index - 1].length < runs[index + 1].length) index -= 1;
        try v8MergeAtArrayCallback(runtime, items, presence, temp, temp_presence, runs, run_count, index, context, min_gallop_state);
    }
}

pub fn v8TimSortArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    context: *V8SortContext,
    pivot_root: *Value,
) !void {
    if (items.len < 2) return;
    const min_run_length = v8ComputeMinRunLengthArray(items.len);
    var runs: [v8_timsort_max_pending_runs]V8ArraySortRun = undefined;
    var run_count: usize = 0;
    var low: usize = 0;
    var remaining = items.len;
    var min_gallop = v8_timsort_min_gallop;
    while (remaining != 0) {
        var current_run_length = try v8CountAndMakeRunArrayCallback(runtime, items, presence, low, low + remaining, context);
        if (current_run_length < min_run_length) {
            const forced_run_length = @min(min_run_length, remaining);
            try v8BinaryInsertionSortArrayCallback(runtime, items, presence, low, low + current_run_length, low + forced_run_length, context, pivot_root);
            current_run_length = forced_run_length;
        }
        if (run_count == runs.len) return error.ArrayTooLarge;
        runs[run_count] = .{ .base = low, .length = current_run_length };
        run_count += 1;
        try v8MergeCollapseArrayCallback(runtime, items, presence, temp, temp_presence, &runs, &run_count, context, &min_gallop);
        low += current_run_length;
        remaining -= current_run_length;
    }
    try v8MergeForceCollapseArrayCallback(runtime, items, presence, temp, temp_presence, &runs, &run_count, context, &min_gallop);
}

pub fn compareAotCallback(runtime: *Runtime, callable: Value, left: Value, left_present: bool, right: Value, right_present: bool, result_root: *Value) !std.math.Order {
    if (!left_present) return if (!right_present) .eq else .gt;
    if (!right_present) return .lt;
    if (left.tag == @intFromEnum(Tag.undefined)) return if (right.tag == @intFromEnum(Tag.undefined)) .eq else .gt;
    if (right.tag == @intFromEnum(Tag.undefined)) return .lt;
    var callback_values = [_]Value{ callable, left, right };
    var callback_frame = RootFrame{};
    runtime.pushRoots(&callback_frame, callback_values[0..].ptr, callback_values.len);
    defer runtime.popRoots(&callback_frame);
    result_root.* = try invokeAotCallback(runtime, callback_values[0], @ptrCast(&callback_values[1]), 2);
    const number = try valueToNumberRuntime(runtime, result_root.*);
    if (std.math.isNan(number) or number == 0) return .eq;
    return if (number < 0) .lt else .gt;
}

pub fn invokeAotCallback(runtime: *Runtime, callable: Value, arguments: ?[*]const Value, len: usize) !Value {
    if (callable.tag != @intFromEnum(Tag.function)) return error.NotCallable;
    const object = callable.object() orelse return error.NotCallable;
    if (object.payload != .function) return error.NotCallable;
    var result: Value = .{};
    const start_epoch = runtime.failure_epoch;
    lnako_aot_function_call(&result, &callable, arguments, len);
    if (runtime.has_pending_exception and runtime.failure_epoch != start_epoch) return error.CallbackExecutionFailed;
    return result;
}

pub fn resolveAotCallback(runtime: *Runtime, value: Value) !Value {
    if (value.tag == @intFromEnum(Tag.function)) return value;
    if (!isString(value)) return error.NotCallable;
    const name = try stringUtf8Alloc(runtime, value);
    defer runtime.allocator.free(name);

    var match: ?Value = null;
    for (runtime.named_functions.items) |registered| {
        if (!registeredFunctionMatches(registered.name, name)) continue;
        if (match != null) return error.UnknownFunction;
        match = .{ .tag = @intFromEnum(Tag.function), .payload = @intFromPtr(registered.object) };
    }
    return match orelse error.UnknownFunction;
}

pub fn registeredFunctionMatches(registered_name: []const u8, requested_name: []const u8) bool {
    if (std.mem.eql(u8, registered_name, requested_name)) return true;
    const separator = std.mem.lastIndexOf(u8, registered_name, "__") orelse return false;
    return std.mem.eql(u8, registered_name[separator + 2 ..], requested_name);
}

pub fn stableArraySort(runtime: *Runtime, source: Value, numeric: bool) !Value {
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    const items = &object.payload.array;
    if (items.items.len < 2) return source;

    try runtime.normalizeAotArrayPresence(object);

    // Keep the live array unchanged until the merge completes. The contiguous
    // root storage protects both the source object and every temporary value
    // while ToString/parseFloat allocate and may trigger collection.
    const allocator = runtime.allocator;
    const root_count = std.math.add(usize, items.items.len, 1) catch return error.ArrayTooLarge;
    const root_values = try allocator.alloc(Value, root_count);
    defer allocator.free(root_values);
    root_values[0] = source;
    std.mem.copyForwards(Value, root_values[1..], items.items);
    const temporary_presence = try allocator.dupe(bool, object.array_presence.items);
    defer allocator.free(temporary_presence);
    var roots = RootFrame{};
    runtime.pushRoots(&roots, root_values.ptr, root_values.len);
    defer runtime.popRoots(&roots);
    const temporary = root_values[1..];

    var width: usize = 1;
    var from_source = true;
    while (width < items.items.len) : (width = std.math.mul(usize, width, 2) catch items.items.len) {
        const input = if (from_source) items.items else temporary;
        const output = if (from_source) temporary else items.items;
        const input_presence = if (from_source) object.array_presence.items else temporary_presence;
        const output_presence = if (from_source) temporary_presence else object.array_presence.items;
        var start: usize = 0;
        while (start < input.len) {
            const middle = @min(std.math.add(usize, start, width) catch input.len, input.len);
            const end = @min(std.math.add(usize, middle, width) catch input.len, input.len);
            var left = start;
            var right = middle;
            var destination = start;
            while (left < middle and right < end) {
                const order = try compareArraySortValues(runtime, input[left], input_presence[left], input[right], input_presence[right], numeric);
                if (order == .gt) {
                    output[destination] = input[right];
                    output_presence[destination] = input_presence[right];
                    right += 1;
                } else {
                    output[destination] = input[left];
                    output_presence[destination] = input_presence[left];
                    left += 1;
                }
                destination += 1;
            }
            while (left < middle) : ({
                left += 1;
                destination += 1;
            }) {
                output[destination] = input[left];
                output_presence[destination] = input_presence[left];
            }
            while (right < end) : ({
                right += 1;
                destination += 1;
            }) {
                output[destination] = input[right];
                output_presence[destination] = input_presence[right];
            }
            start = end;
        }
        from_source = !from_source;
    }
    if (!from_source) {
        std.mem.copyForwards(Value, items.items, temporary);
        std.mem.copyForwards(bool, object.array_presence.items, temporary_presence);
    }
    return source;
}

pub fn compareArraySortValues(runtime: *Runtime, left: Value, left_present: bool, right: Value, right_present: bool, numeric: bool) !std.math.Order {
    if (!left_present) return if (!right_present) .eq else .gt;
    if (!right_present) return .lt;
    if (left.tag == @intFromEnum(Tag.undefined)) return if (right.tag == @intFromEnum(Tag.undefined)) .eq else .gt;
    if (right.tag == @intFromEnum(Tag.undefined)) return .lt;
    if (numeric) {
        const left_number = try parseFloatBuiltin(runtime, left);
        const right_number = try parseFloatBuiltin(runtime, right);
        if (std.math.isNan(left_number) or std.math.isNan(right_number)) return .eq;
        return std.math.order(left_number, right_number);
    }

    const left_text = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_text);
    const right_text = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_text);
    return utf16Order(left_text, right_text);
}

pub fn utf16Order(left: []const u16, right: []const u16) std.math.Order {
    return std.mem.order(u16, left, right);
}

const ArrayRange = struct { start: usize, count: usize };

pub fn arrayItems(value: Value) !*std.ArrayList(Value) {
    if (value.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = value.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    return &object.payload.array;
}

/// JavaScript's Array splice uses ToIntegerOrInfinity for the start argument.
/// In particular, strings are converted with Number (not parseInt), NaN and
/// -Infinity become zero, and +Infinity becomes the current array length.
pub fn spliceIndexRuntime(runtime: *Runtime, value: Value, length: usize) !usize {
    return spliceIndexNumber(try valueToNumberRuntime(runtime, value), length);
}

pub fn spliceIndexNumber(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number == -std.math.inf(f64)) return 0;
    if (number == std.math.inf(f64)) return length;
    const integer = @trunc(number);
    if (integer < 0) {
        const magnitude = @min(-integer, @as(f64, @floatFromInt(length)));
        return length - @as(usize, @intFromFloat(magnitude));
    }
    if (integer >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(integer);
}

pub fn spliceCountRuntime(runtime: *Runtime, value: Value, maximum: usize) !usize {
    return spliceCountNumber(try valueToNumberRuntime(runtime, value), maximum);
}

pub fn spliceCountNumber(number: f64, maximum: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (number == std.math.inf(f64)) return maximum;
    return @min(@as(usize, @intFromFloat(@min(@floor(number), @as(f64, @floatFromInt(maximum))))), maximum);
}

pub fn dictionaryOwnProperty(value: Value, key: []const u16) ?Value {
    if (value.tag != @intFromEnum(Tag.dictionary)) return null;
    const object = value.object() orelse return null;
    if (object.payload != .dictionary) return null;
    for (object.payload.dictionary.items) |entry| {
        const matches = switch (@as(Tag, @enumFromInt(entry.key.tag))) {
            .static_utf8_string => blk: {
                var units: [64]u16 = undefined;
                const utf8 = staticUtf8(entry.key);
                if (utf8.len > units.len) break :blk false;
                const converted = std.unicode.utf8ToUtf16Le(&units, utf8) catch break :blk false;
                break :blk std.mem.eql(u16, units[0..converted], key);
            },
            .utf16_string => std.mem.eql(u16, entry.key.object().?.payload.utf16_string, key),
            else => false,
        };
        if (matches) return entry.value;
    }
    return null;
}

pub fn dictionaryPrototypeProperty(value: Value, key: []const u16) ?Value {
    const object = value.object() orelse return null;
    if (object.payload != .dictionary) return null;
    var current = object.prototype;
    var depth: usize = 0;
    while (depth < 256) : (depth += 1) {
        if (current.tag == @intFromEnum(Tag.null_value) or current.tag == @intFromEnum(Tag.undefined)) return null;
        if (current.tag != @intFromEnum(Tag.dictionary)) return null;
        const prototype_object = current.object() orelse return null;
        if (prototype_object.payload != .dictionary) return null;
        if (dictionaryOwnProperty(current, key)) |property| return property;
        current = prototype_object.prototype;
    }
    return null;
}

pub fn dictionaryPrototypeBlocksStandard(value: Value) bool {
    const object = value.object() orelse return false;
    if (object.payload != .dictionary) return false;
    var current = object.prototype;
    var depth: usize = 0;
    while (depth < 256) : (depth += 1) {
        if (current.tag == @intFromEnum(Tag.null_value)) return true;
        if (current.tag == @intFromEnum(Tag.undefined)) return false;
        if (current.tag != @intFromEnum(Tag.dictionary)) return false;
        const prototype_object = current.object() orelse return false;
        if (prototype_object.payload != .dictionary) return false;
        current = prototype_object.prototype;
    }
    return true;
}

pub fn arrayPrototypeProperty(value: Value, key: []const u16) ?Value {
    if (value.tag != @intFromEnum(Tag.array)) return null;
    const object = value.object() orelse return null;
    if (object.payload != .array) return null;
    var current = object.prototype;
    var depth: usize = 0;
    while (depth < 256) : (depth += 1) {
        if (current.tag == @intFromEnum(Tag.null_value) or current.tag == @intFromEnum(Tag.undefined)) return null;
        if (current.tag != @intFromEnum(Tag.dictionary)) return null;
        if (dictionaryOwnProperty(current, key)) |property| return property;
        const prototype_object = current.object() orelse return null;
        if (prototype_object.payload != .dictionary) return null;
        current = prototype_object.prototype;
    }
    return null;
}

pub fn arrayPrototypeBlocksStandard(value: Value) bool {
    if (value.tag != @intFromEnum(Tag.array)) return false;
    const object = value.object() orelse return false;
    if (object.payload != .array) return false;
    var current = object.prototype;
    var depth: usize = 0;
    while (depth < 256) : (depth += 1) {
        if (current.tag == @intFromEnum(Tag.null_value)) return true;
        if (current.tag == @intFromEnum(Tag.undefined)) return false;
        if (current.tag != @intFromEnum(Tag.dictionary)) return false;
        const prototype_object = current.object() orelse return false;
        if (prototype_object.payload != .dictionary) return false;
        current = prototype_object.prototype;
    }
    return true;
}

pub fn dictionaryProperty(value: Value, key: []const u16) Value {
    return dictionaryOwnProperty(value, key) orelse dictionaryPrototypeProperty(value, key) orelse .{};
}

pub fn aotCanonicalArrayIndex(value: Value) ?usize {
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => {
            const number: f64 = @bitCast(value.payload);
            if (!std.math.isFinite(number) or number < 0 or number > 4_294_967_294 or @trunc(number) != number) return null;
            const index: usize = @intFromFloat(number);
            return if (index <= 4_294_967_294) index else null;
        },
        .bigint => {
            const integer = value.object().?.payload.bigint.toI64() catch return null;
            if (integer < 0) return null;
            const index = std.math.cast(usize, integer) orelse return null;
            return if (index <= 4_294_967_294) index else null;
        },
        else => {},
    }
    const units: []const u16 = switch (@as(Tag, @enumFromInt(value.tag))) {
        .static_utf8_string => {
            const text = staticUtf8(value);
            if (text.len == 0 or (text.len > 1 and text[0] == '0')) return null;
            var number: usize = 0;
            for (text) |unit| {
                if (unit < '0' or unit > '9') return null;
                number = std.math.mul(usize, number, 10) catch return null;
                number = std.math.add(usize, number, unit - '0') catch return null;
            }
            return if (number <= 4_294_967_294) number else null;
        },
        .utf16_string => value.object().?.payload.utf16_string,
        else => return null,
    };
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var number: usize = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        number = std.math.mul(usize, number, 10) catch return null;
        number = std.math.add(usize, number, unit - '0') catch return null;
    }
    return if (number <= 4_294_967_294) number else null;
}

pub fn aotDictionaryOrder(runtime: *Runtime, entries: []const DictionaryEntry) ![]usize {
    const order = try runtime.allocator.alloc(usize, entries.len);
    for (order, 0..) |*entry, index| entry.* = index;
    std.sort.pdq(usize, order, entries, aotDictionaryOrderBefore);
    return order;
}

pub fn aotDictionaryOrderBefore(entries: []const DictionaryEntry, left_index: usize, right_index: usize) bool {
    const left = aotCanonicalArrayIndex(entries[left_index].key);
    const right = aotCanonicalArrayIndex(entries[right_index].key);
    return if (left) |left_number| if (right) |right_number| left_number < right_number else true else if (right != null) false else left_index < right_index;
}

const AotEnumerableDictionaryEntry = struct {
    key: Value,
    value: Value,
};

pub fn aotPropertyKeysEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    const left_units = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_units);
    const right_units = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_units);
    return std.mem.eql(u16, left_units, right_units);
}

pub fn aotEnumerableKeyWasYielded(runtime: *Runtime, yielded: []const Value, key: Value) !bool {
    for (yielded) |candidate| if (try aotPropertyKeysEqual(runtime, candidate, key)) return true;
    return false;
}

/// Collect a dictionary's enumerable own keys and custom prototype keys in
/// ECMAScript `for...in` order.  Standard prototype methods are non-enumerable
/// and are synthesized only by property lookup, not by this command.
pub fn aotEnumerableDictionaryEntries(runtime: *Runtime, source: Value) ![]AotEnumerableDictionaryEntry {
    var entries: std.ArrayList(AotEnumerableDictionaryEntry) = .empty;
    errdefer entries.deinit(runtime.allocator);
    var yielded: std.ArrayList(Value) = .empty;
    defer yielded.deinit(runtime.allocator);

    var current = source;
    var depth: usize = 0;
    while (depth < 256) : (depth += 1) {
        const object = current.object() orelse break;
        if (object.payload != .dictionary) break;
        const dictionary = object.payload.dictionary.items;
        const order = try aotDictionaryOrder(runtime, dictionary);
        defer runtime.allocator.free(order);
        for (order) |index| {
            const entry = dictionary[index];
            if (try aotEnumerableKeyWasYielded(runtime, yielded.items, entry.key)) continue;
            try yielded.append(runtime.allocator, entry.key);
            try entries.append(runtime.allocator, .{ .key = entry.key, .value = entry.value });
        }
        current = object.prototype;
    }
    return entries.toOwnedSlice(runtime.allocator);
}

pub fn aotPropertyKeyEqual(runtime: *Runtime, key: Value, units: []const u16) !bool {
    const key_units = try valueUtf16Alloc(runtime, key);
    defer runtime.allocator.free(key_units);
    return std.mem.eql(u16, key_units, units);
}

pub fn dictionaryKeysBuiltin(runtime: *Runtime, source: Value) !Value {
    var roots = [_]Value{ source, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    const result = &roots[1].object().?.payload.array;
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const entries = try aotEnumerableDictionaryEntries(runtime, roots[0]);
            defer runtime.allocator.free(entries);
            for (entries) |entry| {
                const units = try valueUtf16Alloc(runtime, entry.key);
                defer runtime.allocator.free(units);
                var key = try runtime.createString(units);
                var key_frame = RootFrame{};
                runtime.pushRoots(&key_frame, @ptrCast(&key), 1);
                defer runtime.popRoots(&key_frame);
                try result.append(runtime.allocator, key);
            }
        },
        .array => {
            const object = roots[0].object().?;
            const items = object.payload.array.items;
            for (items, 0..) |_, index| {
                if (!runtime.aotArrayIsPresent(object, index)) continue;
                var text: [32]u8 = undefined;
                const encoded = std.fmt.bufPrint(&text, "{d}", .{index}) catch return error.ArrayTooLarge;
                var units: [32]u16 = undefined;
                const unit_len = std.unicode.utf8ToUtf16Le(&units, encoded) catch return error.ArrayTooLarge;
                const key = try runtime.createString(units[0..unit_len]);
                try result.append(runtime.allocator, key);
            }
            for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.key);
        },
        .byte_buffer => {
            const buffer = roots[0].object().?.payload.byte_buffer;
            if (buffer.kind != .array_buffer) for (0..buffer.bytes.len) |index| {
                var text: [32]u8 = undefined;
                const encoded = std.fmt.bufPrint(&text, "{d}", .{index}) catch return error.ArrayTooLarge;
                var units: [32]u16 = undefined;
                const unit_len = std.unicode.utf8ToUtf16Le(&units, encoded) catch return error.ArrayTooLarge;
                const key = try runtime.createString(units[0..unit_len]);
                try result.append(runtime.allocator, key);
            };
            for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.key);
            if (buffer.kind == .buffer) for (table_byte_buffer_buffer_enumerable_property_names) |name| {
                var units: [128]u16 = undefined;
                const unit_len = std.unicode.utf8ToUtf16Le(&units, name) catch return error.InvalidUtf8;
                var key = try runtime.createString(units[0..unit_len]);
                var key_frame = RootFrame{};
                runtime.pushRoots(&key_frame, @ptrCast(&key), 1);
                defer runtime.popRoots(&key_frame);
                try result.append(runtime.allocator, key);
            };
        },
        .function => for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.key),
        .promise => for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.key),
        else => return error.DictionaryKeysReceiver,
    }
    return roots[1];
}

pub fn dictionaryValuesBuiltin(runtime: *Runtime, source: Value) !Value {
    var roots = [_]Value{ source, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    const result = &roots[1].object().?.payload.array;
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const entries = try aotEnumerableDictionaryEntries(runtime, roots[0]);
            defer runtime.allocator.free(entries);
            for (entries) |entry| try result.append(runtime.allocator, entry.value);
        },
        .array => {
            const object = roots[0].object().?;
            for (object.payload.array.items, 0..) |item, index| {
                if (runtime.aotArrayIsPresent(object, index)) try result.append(runtime.allocator, item);
            }
            for (object.array_properties.items) |property| try result.append(runtime.allocator, property.value);
        },
        .byte_buffer => {
            const buffer = roots[0].object().?.payload.byte_buffer;
            if (buffer.kind != .array_buffer) for (buffer.bytes) |byte| try result.append(runtime.allocator, numberValue(@floatFromInt(byte)));
            for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.value);
            if (buffer.kind == .buffer) for (table_byte_buffer_buffer_enumerable_property_names) |name| {
                var property: Value = undefined;
                if (std.mem.eql(u8, name, "parent")) {
                    property = try runtime.createByteBufferBackingBuffer(buffer);
                } else if (std.mem.eql(u8, name, "offset")) {
                    property = numberValue(@floatFromInt(buffer.byte_offset));
                } else {
                    var units: [128]u16 = undefined;
                    const unit_len = std.unicode.utf8ToUtf16Le(&units, name) catch return error.InvalidUtf8;
                    property = (try tableInheritedProperty(runtime, roots[0], .byte_buffer, units[0..unit_len])) orelse .{};
                }
                var property_frame = RootFrame{};
                runtime.pushRoots(&property_frame, @ptrCast(&property), 1);
                defer runtime.popRoots(&property_frame);
                try result.append(runtime.allocator, property);
            };
        },
        .function => for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.value),
        .promise => for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.value),
        else => return error.DictionaryValuesReceiver,
    }
    return roots[1];
}

pub fn dictionaryRemoveBuiltin(runtime: *Runtime, source: Value, key: Value) !Value {
    var roots = [_]Value{ source, key };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const entries = &roots[0].object().?.payload.dictionary;
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            for (entries.items, 0..) |entry, index| if (try aotPropertyKeyEqual(runtime, entry.key, key_units)) {
                _ = entries.orderedRemove(index);
                break;
            };
            return roots[0];
        },
        .array => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthDelete;
            if (runtime.aotCanonicalArrayIndexUnits(key_units)) |index| {
                _ = try runtime.aotArrayDeleteIndex(roots[0].object().?, index);
            } else {
                const properties = &roots[0].object().?.array_properties;
                for (properties.items, 0..) |property, index| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) {
                    _ = properties.orderedRemove(index);
                    break;
                };
            }
            return roots[0];
        },
        .byte_buffer => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            const buffer = roots[0].object().?.payload.byte_buffer;
            if (buffer.kind != .array_buffer) if (runtime.aotCanonicalArrayIndexUnits(key_units)) |index| {
                if (index < buffer.bytes.len) {
                    try byteBufferIndexDeleteFailure(runtime, key_units);
                    return error.ByteBufferIndexDelete;
                }
            };
            const properties = &roots[0].object().?.array_properties;
            for (properties.items, 0..) |property, index| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) {
                _ = properties.orderedRemove(index);
                break;
            };
            return roots[0];
        },
        .function => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or std.mem.eql(u16, key_units, &.{ 'n', 'a', 'm', 'e' })) return roots[0];
            const properties = &roots[0].object().?.array_properties;
            for (properties.items, 0..) |property, index| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) {
                _ = properties.orderedRemove(index);
                break;
            };
            return roots[0];
        },
        .promise => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            const properties = &roots[0].object().?.array_properties;
            for (properties.items, 0..) |property, index| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) {
                _ = properties.orderedRemove(index);
                break;
            };
            return roots[0];
        },
        else => return error.DictionaryRemoveReceiver,
    }
}

pub fn byteBufferIndexDeleteFailure(runtime: *Runtime, key_units: []const u16) !void {
    const key_utf8 = try utf16FailureMessageUtf8Alloc(runtime.allocator, key_units);
    defer runtime.allocator.free(key_utf8);
    const message = try std.fmt.allocPrint(runtime.allocator, "Cannot delete property '{s}' of [object Uint8Array]", .{key_utf8});
    defer runtime.allocator.free(message);
    runtime.setFailureText(message);
}

pub fn dictionaryHasBuiltin(runtime: *Runtime, source: Value, key: Value) !bool {
    var roots = [_]Value{ source, key };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            for (roots[0].object().?.payload.dictionary.items) |entry| if (try aotPropertyKeyEqual(runtime, entry.key, key_units)) return true;
            return (try tableInheritedProperty(runtime, roots[0], .dictionary, key_units)) != null;
        },
        .array => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return true;
            if (runtime.aotCanonicalArrayIndexUnits(key_units)) |index| {
                return runtime.aotArrayIsPresent(roots[0].object().?, index);
            }
            for (roots[0].object().?.array_properties.items) |property| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) return true;
            return (try tableInheritedProperty(runtime, roots[0], .array, key_units)) != null;
        },
        .function => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            for (roots[0].object().?.array_properties.items) |property| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) return true;
            if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or std.mem.eql(u16, key_units, &.{ 'n', 'a', 'm', 'e' })) return true;
            return (try tableInheritedProperty(runtime, roots[0], .function, key_units)) != null;
        },
        .byte_buffer => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            const object = roots[0].object() orelse return error.InvalidByteBuffer;
            const buffer = object.payload.byte_buffer;
            for (object.array_properties.items) |property| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) return true;
            if (buffer.kind != .array_buffer) {
                if (aotByteBufferAllowsStandardPrototype(roots[0]) and std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return true;
                if (runtime.aotCanonicalArrayIndexUnits(key_units)) |index| return index < buffer.bytes.len;
            }
            return (try tableInheritedProperty(runtime, roots[0], .byte_buffer, key_units)) != null;
        },
        .promise => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            for (roots[0].object().?.array_properties.items) |property| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) return true;
            return false;
        },
        else => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            const receiver_units = try valueUtf16Alloc(runtime, roots[0]);
            defer runtime.allocator.free(receiver_units);
            const key_utf8 = try utf16FailureMessageUtf8Alloc(runtime.allocator, key_units);
            defer runtime.allocator.free(key_utf8);
            const receiver_utf8 = try utf16FailureMessageUtf8Alloc(runtime.allocator, receiver_units);
            defer runtime.allocator.free(receiver_utf8);
            const message = try std.fmt.allocPrint(runtime.allocator, "Cannot use 'in' operator to search for '{s}' in {s}", .{ key_utf8, receiver_utf8 });
            defer runtime.allocator.free(message);
            runtime.setFailureText(message);
            return error.DictionaryHasReceiver;
        },
    }
}

pub fn stringValuesEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    if (!isString(left) or !isString(right)) return false;
    return stringEqual(runtime, left, right);
}

pub fn arrayRange(runtime: *Runtime, index: Value, length: usize) !?ArrayRange {
    // The official implementation checks `typeof i === 'object'` before
    // reading i['先頭'].  Accessing a null value therefore throws, while an
    // array or dictionary without a numeric 先頭 simply falls through to the
    // null return value.
    if (index.tag == @intFromEnum(Tag.null_value)) return error.ArrayCutNullIndex;
    const tag: Tag = @enumFromInt(index.tag);
    if (tag != .array and tag != .dictionary) return null;
    const first_value = dictionaryProperty(index, &.{ 0x5148, 0x982d });
    if (first_value.tag != @intFromEnum(Tag.number)) return null;
    const first_number: f64 = @bitCast(first_value.payload);
    const last_value = dictionaryProperty(index, &.{ 0x672b, 0x5c3e });
    // `last - first + 1` is a JavaScript subtraction expression.  A BigInt
    // on either side would throw instead of silently converting to f64.
    if (last_value.tag == @intFromEnum(Tag.bigint)) return error.CannotMixBigIntAndNumber;
    const last_number = try valueToNumberRuntime(runtime, last_value);
    const count_number = last_number - first_number + 1;
    return .{
        .start = spliceIndexNumber(first_number, length),
        .count = spliceCountNumber(count_number, length - spliceIndexNumber(first_number, length)),
    };
}

pub fn spliceArrayBuiltin(runtime: *Runtime, source: Value, start: usize, count: usize) !Value {
    var roots = [_]Value{ source, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const items = try arrayItems(roots[0]);
    const source_object = roots[0].object() orelse return error.InvalidArray;
    try runtime.normalizeAotArrayPresence(source_object);
    const old_length = items.items.len;
    const actual = @min(count, old_length - start);
    roots[1] = try runtime.createArray(&.{});
    const result_object = roots[1].object() orelse return error.InvalidArray;
    const removed = try arrayItems(roots[1]);
    try removed.ensureTotalCapacity(runtime.allocator, actual);
    removed.items.len = actual;
    try result_object.array_presence.ensureTotalCapacity(runtime.allocator, actual);
    result_object.array_presence.items.len = actual;
    if (actual > 0) {
        @memcpy(removed.items, items.items[start .. start + actual]);
        @memcpy(result_object.array_presence.items, source_object.array_presence.items[start .. start + actual]);
    }
    if (actual > 0) {
        @memmove(items.items[start .. old_length - actual], items.items[start + actual .. old_length]);
        @memmove(source_object.array_presence.items[start .. old_length - actual], source_object.array_presence.items[start + actual .. old_length]);
        items.items.len = old_length - actual;
        source_object.array_presence.items.len = old_length - actual;
    }
    return roots[1];
}

pub fn insertValuesAssumeCapacity(items: *std.ArrayList(Value), start: usize, values: []const Value) void {
    const old_length = items.items.len;
    _ = items.addManyAtAssumeCapacity(start, values.len);
    @memcpy(items.items[start .. start + values.len], values);
    // Keep this assertion next to the low-level mutation: all callers reserve
    // capacity before entering this function, so OOM cannot leave a partial
    // array update behind.
    std.debug.assert(items.items.len == old_length + values.len);
}

pub fn insertPresenceAssumeCapacity(presence: *std.ArrayList(bool), start: usize, count: usize) void {
    const old_length = presence.items.len;
    _ = presence.addManyAtAssumeCapacity(start, count);
    @memset(presence.items[start .. start + count], true);
    std.debug.assert(presence.items.len == old_length + count);
}

pub fn arrayInsertBuiltin(runtime: *Runtime, source: Value, index: Value, item: Value) !Value {
    var roots = [_]Value{ source, index, item, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array)) return error.ArrayInsertReceiver;
    const object = roots[0].object() orelse return error.InvalidArray;
    try runtime.normalizeAotArrayPresence(object);
    const items = try arrayItems(roots[0]);
    const start = try spliceIndexRuntime(runtime, roots[1], items.items.len);
    roots[3] = try runtime.createArray(&.{});
    const old_length = items.items.len;
    try items.ensureTotalCapacity(runtime.allocator, std.math.add(usize, old_length, 1) catch return error.ArrayTooLarge);
    try object.array_presence.ensureTotalCapacity(runtime.allocator, std.math.add(usize, old_length, 1) catch return error.ArrayTooLarge);
    insertValuesAssumeCapacity(items, start, roots[2..3]);
    insertPresenceAssumeCapacity(&object.array_presence, start, 1);
    return roots[3];
}

pub fn arrayInsertManyBuiltin(runtime: *Runtime, source: Value, index: Value, values: Value) !Value {
    var roots = [_]Value{ source, index, values, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array) or roots[2].tag != @intFromEnum(Tag.array)) return error.ArrayInsertManyReceiver;
    const target_object = roots[0].object() orelse return error.InvalidArray;
    try runtime.normalizeAotArrayPresence(target_object);
    const target = try arrayItems(roots[0]);
    const insertion = try arrayItems(roots[2]);
    // The official loop reads b[j] while mutating a.  Copying first is
    // intentional here: for a === b the upstream loop grows forever.  AOT
    // keeps the useful, finite value semantics and documents this safety
    // boundary in COMPATIBILITY_QUIRKS.md.
    const copy = try runtime.allocator.dupe(Value, insertion.items);
    defer runtime.allocator.free(copy);
    const positions = try runtime.allocator.alloc(usize, copy.len);
    defer runtime.allocator.free(positions);
    const old_length = target.items.len;
    for (copy, 0..) |_, offset| {
        // `i + j` is evaluated before splice.  This deliberately preserves
        // JavaScript's string concatenation and BigInt mixed-type errors.
        roots[3] = try jsAdd(runtime, roots[1], numberValue(@floatFromInt(offset)));
        positions[offset] = try spliceIndexRuntime(runtime, roots[3], std.math.add(usize, old_length, offset) catch return error.ArrayTooLarge);
    }
    const final_length = std.math.add(usize, old_length, copy.len) catch return error.ArrayTooLarge;
    try target.ensureTotalCapacity(runtime.allocator, final_length);
    try target_object.array_presence.ensureTotalCapacity(runtime.allocator, final_length);
    for (positions, 0..) |start, offset| {
        insertValuesAssumeCapacity(target, start, copy[offset .. offset + 1]);
        insertPresenceAssumeCapacity(&target_object.array_presence, start, 1);
    }
    return roots[0];
}

pub fn arrayCutBuiltin(runtime: *Runtime, source: Value, index: Value) !Value {
    var roots = [_]Value{ source, index, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag == @intFromEnum(Tag.array)) {
        const items = try arrayItems(roots[0]);
        if (roots[1].tag == @intFromEnum(Tag.number)) {
            const start = try spliceIndexRuntime(runtime, roots[1], items.items.len);
            roots[2] = try spliceArrayBuiltin(runtime, roots[0], start, 1);
            const removed = try arrayItems(roots[2]);
            return if (removed.items.len == 0) .{} else removed.items[0];
        }
        if (try arrayRange(runtime, roots[1], items.items.len)) |range| {
            return spliceArrayBuiltin(runtime, roots[0], range.start, range.count);
        }
        return .{ .tag = @intFromEnum(Tag.null_value) };
    }
    if (roots[0].tag == @intFromEnum(Tag.dictionary) and isString(roots[1])) {
        const object = roots[0].object() orelse return error.InvalidDictionary;
        if (object.payload != .dictionary) return error.InvalidDictionary;
        const key_units = try valueUtf16Alloc(runtime, roots[1]);
        defer runtime.allocator.free(key_units);
        const entries = &object.payload.dictionary;
        var own_index: ?usize = null;
        for (entries.items, 0..) |entry, entry_index| {
            if (try aotPropertyKeyEqual(runtime, entry.key, key_units)) {
                own_index = entry_index;
                break;
            }
        }
        if (own_index) |entry_index| {
            const old = entries.items[entry_index].value;
            if (!valueTruthy(old)) return .{};
            const removed = entries.orderedRemove(entry_index);
            return removed.value;
        }
        roots[2] = (try tableInheritedProperty(runtime, roots[0], .dictionary, key_units)) orelse return .{};
        if (!valueTruthy(roots[2])) return .{};
        return roots[2];
    }
    return error.ArrayCutReceiver;
}

pub fn arrayTakeBuiltin(runtime: *Runtime, source: Value, index: Value, count: Value) !Value {
    var roots = [_]Value{ source, index, count };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array)) return error.ArrayTakeReceiver;
    const items = try arrayItems(roots[0]);
    const start = try spliceIndexRuntime(runtime, roots[1], items.items.len);
    const delete_count = try spliceCountRuntime(runtime, roots[2], items.items.len - start);
    return spliceArrayBuiltin(runtime, roots[0], start, delete_count);
}

pub fn arrayPopBuiltin(_: *Runtime, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayPopReceiver;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    const length = object.payload.array.items.len;
    if (length == 0) return .{};
    const result = object.payload.array.items[length - 1];
    _ = object.payload.array.pop();
    if (object.array_presence.items.len >= length) _ = object.array_presence.pop();
    return result;
}

pub fn arrayPushBuiltin(runtime: *Runtime, source: Value, item: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayPushReceiver;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    try runtime.aotArrayAppend(object, item);
    return source;
}

pub fn arrayMutationBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const source: Value = if (arguments.len > 0) arguments[0] else .{};
    const index: Value = if (arguments.len > 1) arguments[1] else .{};
    const item: Value = if (arguments.len > 2) arguments[2] else .{};
    return switch (command) {
        .array_insert => arrayInsertBuiltin(runtime, source, index, item),
        .array_insert_many => arrayInsertManyBuiltin(runtime, source, index, item),
        .array_cut => arrayCutBuiltin(runtime, source, index),
        .array_take => arrayTakeBuiltin(runtime, source, index, if (arguments.len > 2) arguments[2] else .{}),
        .array_pop => arrayPopBuiltin(runtime, source),
        .array_push => arrayPushBuiltin(runtime, source, index),
        .array_clone => deepCloneBuiltin(runtime, source),
        .array_range_copy => arrayRangeCopyBuiltin(runtime, source, index),
        .reference => referenceBuiltin(runtime, source, index),
        .array_add => arrayAddBuiltin(runtime, source, index),
        .array_maximum => arrayExtremumBuiltin(runtime, source, true),
        .array_minimum => arrayExtremumBuiltin(runtime, source, false),
        .array_sum => arraySumBuiltin(runtime, source),
        .array_swap => arraySwapBuiltin(runtime, source, index, item),
        .array_sequence => arraySequenceBuiltin(runtime, source, index),
        .array_fill => arrayFillBuiltin(runtime, source, index),
        else => error.UnknownCommand,
    };
}

const table_length_key = [_]u16{ 'l', 'e', 'n', 'g', 't', 'h' };

const table_standard_property_cache_object: u8 = 1;
const table_standard_property_cache_function: u8 = 2;
const table_standard_property_cache_array: u8 = 3;
const table_standard_property_cache_string: u8 = 4;
const table_standard_property_cache_constructor: u8 = 5;
const table_standard_property_cache_buffer: u8 = 6;
const table_standard_property_cache_uint8_array: u8 = 7;
const table_standard_property_cache_array_buffer: u8 = 8;
const table_standard_property_cache_number: u8 = 9;
const table_standard_property_cache_boolean: u8 = 10;
const table_standard_property_cache_bigint: u8 = 11;

const table_object_prototype_method_names = [_][]const u8{
    "__defineGetter__",
    "__defineSetter__",
    "hasOwnProperty",
    "__lookupGetter__",
    "__lookupSetter__",
    "isPrototypeOf",
    "propertyIsEnumerable",
    "toLocaleString",
    "toString",
    "valueOf",
};

const table_function_prototype_method_names = [_][]const u8{ "apply", "bind", "call", "toString" };

const table_array_prototype_method_names = [_][]const u8{
    "at",
    "concat",
    "copyWithin",
    "entries",
    "every",
    "fill",
    "filter",
    "find",
    "findIndex",
    "findLast",
    "findLastIndex",
    "flat",
    "flatMap",
    "forEach",
    "includes",
    "indexOf",
    "join",
    "keys",
    "lastIndexOf",
    "map",
    "pop",
    "push",
    "reduce",
    "reduceRight",
    "reverse",
    "shift",
    "slice",
    "some",
    "sort",
    "splice",
    "toLocaleString",
    "toString",
    "unshift",
    "values",
    "with",
};

const table_string_prototype_method_names = [_][]const u8{
    "anchor",
    "at",
    "big",
    "blink",
    "bold",
    "charAt",
    "charCodeAt",
    "codePointAt",
    "concat",
    "endsWith",
    "fixed",
    "fontcolor",
    "fontsize",
    "includes",
    "indexOf",
    "isWellFormed",
    "italics",
    "lastIndexOf",
    "link",
    "localeCompare",
    "match",
    "matchAll",
    "normalize",
    "padEnd",
    "padStart",
    "repeat",
    "replace",
    "replaceAll",
    "search",
    "slice",
    "small",
    "split",
    "startsWith",
    "strike",
    "sub",
    "substr",
    "substring",
    "toLocaleLowerCase",
    "toLocaleUpperCase",
    "toLowerCase",
    "toUpperCase",
    "toWellFormed",
    "toString",
    "valueOf",
    "trim",
    "trimEnd",
    "trimLeft",
    "trimRight",
    "trimStart",
};

const table_number_prototype_method_names = [_][]const u8{
    "toExponential",
    "toFixed",
    "toLocaleString",
    "toPrecision",
    "toString",
    "valueOf",
};

const table_boolean_prototype_method_names = [_][]const u8{ "toString", "valueOf" };

const table_bigint_prototype_method_names = [_][]const u8{ "toLocaleString", "toString", "valueOf" };

const table_byte_buffer_typed_array_method_names = [_][]const u8{
    "at",
    "copyWithin",
    "entries",
    "every",
    "fill",
    "filter",
    "find",
    "findIndex",
    "findLast",
    "findLastIndex",
    "forEach",
    "includes",
    "indexOf",
    "join",
    "keys",
    "lastIndexOf",
    "map",
    "reverse",
    "reduce",
    "reduceRight",
    "set",
    "slice",
    "some",
    "sort",
    "subarray",
    "toReversed",
    "toSorted",
    "values",
    "with",
};

pub const table_byte_buffer_buffer_enumerable_property_names = [_][]const u8{
    "readBigUInt64LE",
    "readBigUInt64BE",
    "readBigUint64LE",
    "readBigUint64BE",
    "readBigInt64LE",
    "readBigInt64BE",
    "writeBigUInt64LE",
    "writeBigUInt64BE",
    "writeBigUint64LE",
    "writeBigUint64BE",
    "writeBigInt64LE",
    "writeBigInt64BE",
    "readUIntLE",
    "readUInt32LE",
    "readUInt16LE",
    "readUInt8",
    "readUIntBE",
    "readUInt32BE",
    "readUInt16BE",
    "readUintLE",
    "readUint32LE",
    "readUint16LE",
    "readUint8",
    "readUintBE",
    "readUint32BE",
    "readUint16BE",
    "readIntLE",
    "readInt32LE",
    "readInt16LE",
    "readInt8",
    "readIntBE",
    "readInt32BE",
    "readInt16BE",
    "writeUIntLE",
    "writeUInt32LE",
    "writeUInt16LE",
    "writeUInt8",
    "writeUIntBE",
    "writeUInt32BE",
    "writeUInt16BE",
    "writeUintLE",
    "writeUint32LE",
    "writeUint16LE",
    "writeUint8",
    "writeUintBE",
    "writeUint32BE",
    "writeUint16BE",
    "writeIntLE",
    "writeInt32LE",
    "writeInt16LE",
    "writeInt8",
    "writeIntBE",
    "writeInt32BE",
    "writeInt16BE",
    "readFloatLE",
    "readFloatBE",
    "readDoubleLE",
    "readDoubleBE",
    "writeFloatLE",
    "writeFloatBE",
    "writeDoubleLE",
    "writeDoubleBE",
    "asciiSlice",
    "base64Slice",
    "base64urlSlice",
    "latin1Slice",
    "hexSlice",
    "ucs2Slice",
    "utf8Slice",
    "asciiWrite",
    "base64Write",
    "base64urlWrite",
    "latin1Write",
    "hexWrite",
    "ucs2Write",
    "utf8Write",
    "parent",
    "offset",
    "copy",
    "toString",
    "equals",
    "inspect",
    "compare",
    "indexOf",
    "lastIndexOf",
    "includes",
    "fill",
    "write",
    "toJSON",
    "subarray",
    "slice",
    "swap16",
    "swap32",
    "swap64",
    "toLocaleString",
};

const table_byte_buffer_empty_function_names = [_][]const u8{
    "readUInt32LE",
    "readUInt16LE",
    "readUInt8",
    "readUInt32BE",
    "readUInt16BE",
    "readUint32LE",
    "readUint16LE",
    "readUint8",
    "readUint32BE",
    "readUint16BE",
    "readInt32LE",
    "readInt16LE",
    "readInt8",
    "readInt32BE",
    "readInt16BE",
    "asciiSlice",
    "base64Slice",
    "base64urlSlice",
    "latin1Slice",
    "hexSlice",
    "ucs2Slice",
    "utf8Slice",
    "asciiWrite",
    "base64Write",
    "base64urlWrite",
    "latin1Write",
    "hexWrite",
    "ucs2Write",
    "utf8Write",
};

const table_byte_buffer_array_buffer_method_names = [_][]const u8{
    "slice",
    "resize",
    "transfer",
    "transferToFixedLength",
};

pub fn tableAsciiUnitsEqual(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |unit, byte| if (unit != byte) return false;
    return true;
}

pub fn tableInheritedMethodName(units: []const u16, names: []const []const u8) ?[]const u8 {
    for (names) |name| if (tableAsciiUnitsEqual(units, name)) return name;
    return null;
}

pub fn tableBufferEnumerableFunctionName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "readBigUint64LE")) return "readBigUInt64LE";
    if (std.mem.eql(u8, name, "readBigUint64BE")) return "readBigUInt64BE";
    if (std.mem.eql(u8, name, "writeBigUint64LE")) return "writeBigUInt64LE";
    if (std.mem.eql(u8, name, "writeBigUint64BE")) return "writeBigUInt64BE";
    if (std.mem.eql(u8, name, "readUintLE")) return "readUIntLE";
    if (std.mem.eql(u8, name, "readUint32LE")) return "readUInt32LE";
    if (std.mem.eql(u8, name, "readUint16LE")) return "readUInt16LE";
    if (std.mem.eql(u8, name, "readUint8")) return "readUInt8";
    if (std.mem.eql(u8, name, "readUintBE")) return "readUIntBE";
    if (std.mem.eql(u8, name, "readUint32BE")) return "readUInt32BE";
    if (std.mem.eql(u8, name, "readUint16BE")) return "readUInt16BE";
    if (std.mem.eql(u8, name, "writeUintLE")) return "writeUIntLE";
    if (std.mem.eql(u8, name, "writeUint32LE")) return "writeUInt32LE";
    if (std.mem.eql(u8, name, "writeUint16LE")) return "writeUInt16LE";
    if (std.mem.eql(u8, name, "writeUint8")) return "writeUInt8";
    if (std.mem.eql(u8, name, "writeUintBE")) return "writeUIntBE";
    if (std.mem.eql(u8, name, "writeUint32BE")) return "writeUInt32BE";
    if (std.mem.eql(u8, name, "writeUint16BE")) return "writeUInt16BE";
    if (std.mem.eql(u8, name, "readFloatLE")) return "readFloatForwards";
    if (std.mem.eql(u8, name, "readFloatBE")) return "readFloatBackwards";
    if (std.mem.eql(u8, name, "readDoubleLE")) return "readDoubleForwards";
    if (std.mem.eql(u8, name, "readDoubleBE")) return "readDoubleBackwards";
    if (std.mem.eql(u8, name, "writeFloatLE")) return "writeFloatForwards";
    if (std.mem.eql(u8, name, "writeFloatBE")) return "writeFloatBackwards";
    if (std.mem.eql(u8, name, "writeDoubleLE")) return "writeDoubleForwards";
    if (std.mem.eql(u8, name, "writeDoubleBE")) return "writeDoubleBackwards";
    for (table_byte_buffer_empty_function_names) |empty_name| if (std.mem.eql(u8, name, empty_name)) return "";
    return name;
}

pub fn tableInheritedFunctionWithCallback(
    runtime: *Runtime,
    cache_kind: u8,
    cache_name: []const u8,
    function_name: []const u8,
    callback: FunctionCallback,
) !Value {
    if (runtime.cachedStandardProperty(cache_kind, cache_name)) |value| return value;
    const result = try runtime.createMethodFunction(callback, 0, function_name, &.{});
    try runtime.cacheStandardProperty(cache_kind, cache_name, result);
    return result;
}

pub fn tableInheritedFunction(runtime: *Runtime, cache_kind: u8, name: []const u8) !Value {
    return tableInheritedFunctionWithCallback(runtime, cache_kind, name, name, promiseSentinel);
}

pub fn tableInheritedByteBufferMethod(runtime: *Runtime, receiver: Value, name: []const u8) !Value {
    const cache_kind: u8 = switch (receiver.object().?.payload.byte_buffer.kind) {
        .buffer => table_standard_property_cache_buffer,
        .uint8_array => table_standard_property_cache_uint8_array,
        .array_buffer => table_standard_property_cache_array_buffer,
    };
    if (@as(Tag, @enumFromInt(receiver.tag)) == .byte_buffer and receiver.object().?.payload.byte_buffer.kind == .buffer and std.mem.eql(u8, name, "slice")) {
        return tableInheritedFunctionWithCallback(runtime, cache_kind, name, name, byteBufferUnboundSliceCallback);
    }
    return tableInheritedFunction(runtime, cache_kind, name);
}

pub fn tableInheritedProperty(runtime: *Runtime, row: Value, row_tag: Tag, units: []const u16) !?Value {
    if (row_tag == .dictionary and row.object().?.prototype.tag != @intFromEnum(Tag.undefined)) {
        if (tableAsciiUnitsEqual(units, "__proto__")) return row.object().?.prototype;
        if (dictionaryPrototypeProperty(row, units)) |value| return value;
        if (dictionaryPrototypeBlocksStandard(row)) return null;
    }
    if (row_tag == .array and row.object().?.prototype.tag != @intFromEnum(Tag.undefined)) {
        if (tableAsciiUnitsEqual(units, "__proto__")) return if (row.object().?.prototype.tag == @intFromEnum(Tag.null_value)) .{} else row.object().?.prototype;
        if (arrayPrototypeProperty(row, units)) |value| return value;
        if (arrayPrototypeBlocksStandard(row)) return null;
    }
    if (row_tag == .byte_buffer and row.object().?.prototype.tag != @intFromEnum(Tag.undefined)) {
        if (tableAsciiUnitsEqual(units, "__proto__")) return if (row.object().?.prototype.tag == @intFromEnum(Tag.null_value)) null else row.object().?.prototype;
        if (row.object().?.prototype.tag == @intFromEnum(Tag.dictionary)) {
            if (dictionaryOwnProperty(row.object().?.prototype, units)) |value| return value;
            if (dictionaryPrototypeProperty(row.object().?.prototype, units)) |value| return value;
            if (dictionaryPrototypeBlocksStandard(row.object().?.prototype)) return null;
        }
        if (row.object().?.prototype.tag == @intFromEnum(Tag.null_value)) return null;
    }

    if (tableAsciiUnitsEqual(units, "__proto__")) {
        return switch (row_tag) {
            .dictionary => blk: {
                if (runtime.cachedStandardProperty(table_standard_property_cache_object, "__proto__")) |value| break :blk @as(?Value, value);
                const value = try runtime.createDictionary(&.{});
                try runtime.cacheStandardProperty(table_standard_property_cache_object, "__proto__", value);
                break :blk @as(?Value, value);
            },
            .array => blk: {
                if (runtime.cachedStandardProperty(table_standard_property_cache_array, "__proto__")) |value| break :blk @as(?Value, value);
                const value = try runtime.createArray(&.{});
                try runtime.cacheStandardProperty(table_standard_property_cache_array, "__proto__", value);
                break :blk @as(?Value, value);
            },
            .static_utf8_string, .utf16_string => blk: {
                if (runtime.cachedStandardProperty(table_standard_property_cache_string, "__proto__")) |value| break :blk @as(?Value, value);
                const value = try runtime.createString(&.{});
                try runtime.cacheStandardProperty(table_standard_property_cache_string, "__proto__", value);
                break :blk @as(?Value, value);
            },
            .function => @as(?Value, try tableInheritedFunctionWithCallback(runtime, table_standard_property_cache_function, "__proto__", "", promiseSentinel)),
            else => null,
        };
    }

    if (tableAsciiUnitsEqual(units, "prototype") and row_tag == .function) {
        if (row.object().?.payload.function.prototype.tag != @intFromEnum(Tag.undefined)) return @as(?Value, row.object().?.payload.function.prototype);
        const prototype = try runtime.createDictionary(&.{ staticStringValue("constructor"), row });
        row.object().?.payload.function.prototype = prototype;
        return @as(?Value, prototype);
    }

    const constructor_name: ?[]const u8 = switch (row_tag) {
        .dictionary => "Object",
        .array => "Array",
        .static_utf8_string, .utf16_string => "String",
        .function => "Function",
        .number => "Number",
        .boolean => "Boolean",
        .bigint => "BigInt",
        .byte_buffer => switch (row.object().?.payload.byte_buffer.kind) {
            .buffer => "Buffer",
            .uint8_array => "Uint8Array",
            .array_buffer => "ArrayBuffer",
        },
        else => null,
    };
    if (constructor_name) |name| if (tableAsciiUnitsEqual(units, "constructor")) return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_constructor, name));

    if (row_tag == .byte_buffer) {
        const buffer = row.object().?.payload.byte_buffer;
        if (tableAsciiUnitsEqual(units, "byteLength")) return @as(?Value, numberValue(@floatFromInt(buffer.bytes.len)));
        if (tableAsciiUnitsEqual(units, "byteOffset")) {
            if (buffer.kind == .array_buffer) return null;
            return @as(?Value, numberValue(@floatFromInt(buffer.byte_offset)));
        }
        if (tableAsciiUnitsEqual(units, "BYTES_PER_ELEMENT")) {
            if (buffer.kind == .array_buffer) return null;
            return @as(?Value, numberValue(1));
        }
        if (tableAsciiUnitsEqual(units, "buffer")) {
            if (buffer.kind == .array_buffer) return null;
            return @as(?Value, try runtime.createByteBufferBackingBuffer(buffer));
        }
        if (buffer.kind == .array_buffer) {
            if (tableAsciiUnitsEqual(units, "maxByteLength")) return @as(?Value, numberValue(@floatFromInt(buffer.bytes.len)));
            if (tableAsciiUnitsEqual(units, "resizable") or tableAsciiUnitsEqual(units, "detached")) {
                return @as(?Value, .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 });
            }
            if (tableInheritedMethodName(units, &table_byte_buffer_array_buffer_method_names)) |name| return @as(?Value, try tableInheritedByteBufferMethod(runtime, row, name));
        } else {
            if (buffer.kind == .buffer and tableAsciiUnitsEqual(units, "parent")) {
                return @as(?Value, try runtime.createByteBufferBackingBuffer(buffer));
            }
            if (buffer.kind == .buffer and tableAsciiUnitsEqual(units, "offset")) {
                return @as(?Value, numberValue(@floatFromInt(buffer.byte_offset)));
            }
            if (buffer.kind == .buffer and tableAsciiUnitsEqual(units, "toLocaleString")) {
                return @as(?Value, try tableInheritedByteBufferMethod(runtime, row, "toString"));
            }
            if (tableInheritedMethodName(units, &table_byte_buffer_typed_array_method_names)) |name| return @as(?Value, try tableInheritedByteBufferMethod(runtime, row, name));
            if (buffer.kind == .buffer) {
                if (tableInheritedMethodName(units, &table_byte_buffer_buffer_enumerable_property_names)) |name| {
                    if (!tableAsciiUnitsEqual(units, "parent") and !tableAsciiUnitsEqual(units, "offset")) {
                        return @as(?Value, try tableInheritedByteBufferMethod(runtime, row, tableBufferEnumerableFunctionName(name)));
                    }
                }
            }
        }
    }

    const supports_object_prototype = row_tag == .dictionary or row_tag == .array or row_tag == .static_utf8_string or
        row_tag == .utf16_string or row_tag == .function or row_tag == .number or row_tag == .boolean or row_tag == .bigint or row_tag == .byte_buffer;
    if (row_tag == .array) {
        if (tableInheritedMethodName(units, &table_array_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_array, name));
    }
    if (row_tag == .static_utf8_string or row_tag == .utf16_string) {
        if (tableInheritedMethodName(units, &table_string_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_string, name));
    }
    if (row_tag == .function) {
        if (tableInheritedMethodName(units, &table_function_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_function, name));
    }
    if (row_tag == .number) {
        if (tableInheritedMethodName(units, &table_number_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_number, name));
    }
    if (row_tag == .boolean) {
        if (tableInheritedMethodName(units, &table_boolean_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_boolean, name));
    }
    if (row_tag == .bigint) {
        if (tableInheritedMethodName(units, &table_bigint_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_bigint, name));
    }
    if (supports_object_prototype) {
        if (tableInheritedMethodName(units, &table_object_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_object, name));
    }
    return null;
}

/// Read a row property using the same useful subset of JavaScript's
/// `row[column]` semantics used by the official table commands.  In
/// particular, strings expose UTF-16 code units and dictionaries only expose
/// own properties.  Accessing a missing row is deliberately an error: the
/// upstream implementation evaluates `a[i][col]`, so null/undefined rows do
/// not silently produce undefined.
pub fn tableRowProperty(runtime: *Runtime, row: Value, column: Value) !Value {
    const row_tag: Tag = @enumFromInt(row.tag);
    if (row_tag == .undefined or row_tag == .null_value) {
        try setTableRowPropertyFailure(runtime, row, column);
        return error.TableRowMissing;
    }
    const key_units = try valueUtf16Alloc(runtime, column);
    defer runtime.allocator.free(key_units);
    if (row_tag == .array) {
        const object = row.object() orelse return error.InvalidArray;
        if (object.payload != .array) return error.InvalidArray;
        if (std.mem.eql(u16, key_units, &table_length_key)) return numberValue(@floatFromInt(object.payload.array.items.len));
        if (runtime.aotArrayOwnPropertyGetUnits(object, key_units)) |value| return value;
        if (try tableInheritedProperty(runtime, row, row_tag, key_units)) |value| return value;
        return .{};
    }
    if (row_tag == .dictionary) {
        const object = row.object() orelse return error.InvalidDictionary;
        if (object.payload != .dictionary) return error.InvalidDictionary;
        for (object.payload.dictionary.items) |entry| {
            if (try tablePropertyKeyEqual(runtime, entry.key, key_units)) return entry.value;
        }
        if (try tableInheritedProperty(runtime, row, row_tag, key_units)) |value| return value;
        return .{};
    }
    if (row_tag == .byte_buffer) {
        const object = row.object() orelse return error.InvalidByteBuffer;
        if (object.payload != .byte_buffer) return error.InvalidByteBuffer;
        const allows_standard_prototype = aotByteBufferAllowsStandardPrototype(row);
        if (runtime.aotObjectOwnPropertyGetUnits(object, key_units)) |value| return value;
        if (tablePropertyIndex(key_units) == null) {
            if (try tableInheritedProperty(runtime, row, row_tag, key_units)) |value| return value;
        }
        if (allows_standard_prototype and std.mem.eql(u16, key_units, &table_length_key)) {
            return if (object.payload.byte_buffer.kind == .array_buffer)
                .{}
            else
                numberValue(@floatFromInt(object.payload.byte_buffer.bytes.len));
        }
        if (object.payload.byte_buffer.kind != .array_buffer) if (tablePropertyIndex(key_units)) |index| {
            return if (index < object.payload.byte_buffer.bytes.len)
                numberValue(@floatFromInt(object.payload.byte_buffer.bytes[index]))
            else
                .{};
        };
        return .{};
    }
    if (isString(row)) {
        const units = try valueUtf16Alloc(runtime, row);
        defer runtime.allocator.free(units);
        if (std.mem.eql(u16, key_units, &table_length_key)) return numberValue(@floatFromInt(units.len));
        const index = tablePropertyIndex(key_units) orelse {
            if (try tableInheritedProperty(runtime, row, row_tag, key_units)) |value| return value;
            return .{};
        };
        if (index >= units.len) return .{};
        return try runtime.createString(&.{units[index]});
    }
    if (row_tag == .function) {
        const object = row.object() orelse return error.InvalidFunction;
        if (object.payload != .function) return error.InvalidFunction;
        if (runtime.aotObjectOwnPropertyGetUnits(object, key_units)) |value| return value;
        if (std.mem.eql(u16, key_units, &table_length_key)) {
            // The official compiler exposes Nadesiko functions through a
            // rest-argument wrapper, so Function.length is zero regardless of
            // the language-level arity used by lnako's call dispatcher.
            return numberValue(0);
        }
        if (std.mem.eql(u16, key_units, &.{ 'n', 'a', 'm', 'e' })) {
            // Lowering gives anonymous functions an internal __lambda$ name,
            // while JavaScript Function.name remains the empty string.
            const name = if (std.mem.indexOf(u8, object.payload.function.name, "__lambda$") != null)
                &.{}
            else
                object.payload.function.name;
            const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, name);
            defer runtime.allocator.free(units);
            return runtime.createString(units);
        }
    }
    if (row_tag == .promise) {
        const object = row.object() orelse return error.InvalidContainer;
        if (object.payload != .promise) return error.InvalidContainer;
        if (runtime.aotObjectOwnPropertyGetUnits(object, key_units)) |value| return value;
        return .{};
    }
    if (try tableInheritedProperty(runtime, row, row_tag, key_units)) |value| return value;
    // Number, boolean, bigint, etc. have no relevant own indexed properties
    // in this runtime; JavaScript returns undefined here.
    return .{};
}

pub fn setTableRowPropertyFailure(runtime: *Runtime, row: Value, column: Value) !void {
    var rooted = [_]Value{ row, column };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    const column_units = try valueUtf16Alloc(runtime, rooted[1]);
    defer runtime.allocator.free(column_units);
    const column_utf8 = try utf16FailureMessageUtf8Alloc(runtime.allocator, column_units);
    defer runtime.allocator.free(column_utf8);
    const receiver = if (rooted[0].tag == @intFromEnum(Tag.null_value)) "null" else "undefined";
    const message = try std.fmt.allocPrint(runtime.allocator, "Cannot read properties of {s} (reading '{s}')", .{ receiver, column_utf8 });
    defer runtime.allocator.free(message);
    runtime.setFailureText(message);
}

pub fn tablePropertyKeyEqual(runtime: *Runtime, key: Value, units: []const u16) !bool {
    const key_units = try valueUtf16Alloc(runtime, key);
    defer runtime.allocator.free(key_units);
    return std.mem.eql(u16, key_units, units);
}

/// Parse only canonical array-index property names.  Number("01") is 1, but
/// JavaScript's property key "01" is not an array index, so using Number here
/// would incorrectly read row[1].
pub fn tablePropertyIndex(units: []const u16) ?usize {
    if (units.len == 0) return null;
    if (units.len > 1 and units[0] == '0') return null;
    var result: usize = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        const digit: usize = unit - '0';
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, digit) catch return null;
    }
    // Keep the ECMAScript array-index boundary exact: 2^32 - 1 is not an
    // array index (it is distinct from the length property).
    const max_array_index: usize = @as(usize, std.math.maxInt(u32)) - 1;
    if (result > max_array_index) return null;
    return result;
}

pub fn tableColumnCountBuiltin(runtime: *Runtime, source: Value) !Value {
    var roots = [_]Value{ source, numberValue(1) };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    for (rows.items) |row| {
        const length = try tableRowProperty(runtime, row, staticStringValue("length"));
        if (try compareValues(runtime, .greater, length, roots[1])) roots[1] = length;
    }
    return roots[1];
}

pub fn tableSearchBuiltin(runtime: *Runtime, source: Value, column: Value, row_value: Value, needle: Value) !Value {
    var roots = [_]Value{ source, column, row_value, needle, row_value, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    while (try compareValues(runtime, .less, roots[4], numberValue(@floatFromInt(rows.items.len)))) {
        roots[5] = try tableRowProperty(runtime, roots[0], roots[4]);
        const cell = try tableRowProperty(runtime, roots[5], roots[1]);
        if (try strictEqual(runtime, cell, roots[3])) return roots[4];
        roots[4] = try incrementTableSearchRow(runtime, roots[4]);
    }
    return numberValue(-1);
}

pub fn tableColumnIterationCount(runtime: *Runtime, value: Value) !usize {
    const number = if (value.tag == @intFromEnum(Tag.bigint))
        value.object().?.payload.bigint.toF64()
    else
        try valueToNumberRuntime(runtime, value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > @as(f64, @floatFromInt(safe_array_element_limit))) return error.ArraySizeLimitExceeded;
    return @intFromFloat(@ceil(number));
}

pub fn tableTransposeBuiltin(runtime: *Runtime, source: Value, rotate: bool) !Value {
    var roots = [_]Value{ source, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[1] = try tableColumnCountBuiltin(runtime, roots[0]);
    const columns = try tableColumnIterationCount(runtime, roots[1]);
    const cells = std.math.mul(usize, columns, rows.items.len) catch return error.ArraySizeLimitExceeded;
    if (cells > safe_array_element_limit) return error.ArraySizeLimitExceeded;
    roots[2] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[2]);
    try result.ensureTotalCapacity(runtime.allocator, columns);
    for (0..columns) |column| {
        roots[3] = try runtime.createArray(&.{});
        const row_result = try arrayItems(roots[3]);
        try row_result.ensureTotalCapacity(runtime.allocator, rows.items.len);
        for (0..rows.items.len) |offset| {
            const row_index = if (rotate) rows.items.len - offset - 1 else offset;
            roots[4] = try tableRowProperty(runtime, rows.items[row_index], numberValue(@floatFromInt(column)));
            if (!rotate and roots[4].tag == @intFromEnum(Tag.undefined)) roots[4] = staticStringValue("");
            try row_result.append(runtime.allocator, roots[4]);
        }
        try result.append(runtime.allocator, roots[3]);
    }
    return roots[2];
}

pub fn tableDictionaryHasKey(runtime: *Runtime, dictionary: Value, key: Value) !bool {
    const entries = &dictionary.object().?.payload.dictionary;
    for (entries.items) |entry| if (try strictEqual(runtime, entry.key, key)) return true;
    return false;
}

pub fn tableIsObjectPrototypeKey(units: []const u16) bool {
    const keys = [_][]const u8{
        "constructor",
        "__defineGetter__",
        "__defineSetter__",
        "hasOwnProperty",
        "__lookupGetter__",
        "__lookupSetter__",
        "isPrototypeOf",
        "propertyIsEnumerable",
        "toString",
        "valueOf",
        "__proto__",
        "toLocaleString",
    };
    for (keys) |key| {
        if (units.len != key.len) continue;
        var matches = true;
        for (units, key) |unit, byte| if (unit != byte) {
            matches = false;
            break;
        };
        if (matches) return true;
    }
    return false;
}

pub fn tableUniqueBuiltin(runtime: *Runtime, source: Value, column: Value) !Value {
    var roots = [_]Value{ source, column, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[2] = try runtime.createArray(&.{});
    roots[3] = try runtime.createDictionary(&.{});
    const result = try arrayItems(roots[2]);
    for (rows.items) |row| {
        roots[4] = try tableRowProperty(runtime, row, roots[1]);
        const units = try valueUtf16Alloc(runtime, roots[4]);
        defer runtime.allocator.free(units);
        if (tableIsObjectPrototypeKey(units)) continue;
        roots[5] = try runtime.createString(units);
        if (try tableDictionaryHasKey(runtime, roots[3], roots[5])) continue;
        try roots[3].object().?.payload.dictionary.append(runtime.allocator, .{ .key = roots[5], .value = numberValue(1) });
        try result.append(runtime.allocator, row);
    }
    return roots[2];
}

pub fn tableInsertColumnBuiltin(runtime: *Runtime, source: Value, column: Value, values: Value) !Value {
    var roots = [_]Value{ source, column, values, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[3] = try runtime.createArray(&.{});
    if (rows.items.len == 0) return roots[3];
    const source_object = roots[0].object().?;
    try runtime.normalizeAotArrayPresence(source_object);
    const result = try arrayItems(roots[3]);
    const positive = try compareValues(runtime, .greater, roots[1], numberValue(0));
    for (rows.items, 0..) |row, row_index| {
        // Array.prototype.forEach skips holes in the outer table.
        if (!runtime.aotArrayIsPresent(source_object, row_index)) continue;
        roots[4] = try runtime.createArray(&.{});
        const new_row = try arrayItems(roots[4]);
        const row_tag = @as(Tag, @enumFromInt(row.tag));
        if (row_tag == .array) {
            const row_object = row.object().?;
            try runtime.normalizeAotArrayPresence(row_object);
            const row_items = try arrayItems(row);
            const total = std.math.add(usize, row_items.items.len, 1) catch return error.ArraySizeLimitExceeded;
            if (total > safe_array_element_limit) return error.ArraySizeLimitExceeded;
            try new_row.ensureTotalCapacity(runtime.allocator, total);
            if (positive) {
                const prefix = try spliceIndexRuntime(runtime, roots[1], row_items.items.len);
                for (row_items.items[0..prefix], 0..) |item, index| try appendAotArraySlot(runtime, roots[4].object().?, item, runtime.aotArrayIsPresent(row_object, index));
            }
        } else if (isString(row)) {
            const row_units = try valueUtf16Alloc(runtime, row);
            defer runtime.allocator.free(row_units);
            try new_row.ensureTotalCapacity(runtime.allocator, 3);
            if (positive) {
                const prefix = try spliceIndexRuntime(runtime, roots[1], row_units.len);
                roots[5] = try runtime.createString(row_units[0..prefix]);
                try new_row.append(runtime.allocator, roots[5]);
            }
        } else if (row_tag == .byte_buffer) {
            const buffer = row.object().?.payload.byte_buffer;
            try new_row.ensureTotalCapacity(runtime.allocator, 3);
            if (positive) {
                const prefix = try spliceIndexRuntime(runtime, roots[1], buffer.bytes.len);
                roots[5] = try aotByteBufferSlice(runtime, buffer, 0, prefix);
                try new_row.append(runtime.allocator, roots[5]);
            }
        } else return error.ArrayExpected;
        if (roots[2].tag == @intFromEnum(Tag.array)) {
            const value_items = try arrayItems(roots[2]);
            roots[6] = if (row_index < value_items.items.len) value_items.items[row_index] else .{};
        } else {
            roots[6] = try tableRowProperty(runtime, roots[2], numberValue(@floatFromInt(row_index)));
        }
        try new_row.append(runtime.allocator, roots[6]);
        if (row_tag == .array) {
            const row_items = try arrayItems(row);
            const suffix = try spliceIndexRuntime(runtime, roots[1], row_items.items.len);
            const row_object = row.object().?;
            for (row_items.items[suffix..], suffix..) |item, index| try appendAotArraySlot(runtime, roots[4].object().?, item, runtime.aotArrayIsPresent(row_object, index));
        } else if (isString(row)) {
            const row_units = try valueUtf16Alloc(runtime, row);
            defer runtime.allocator.free(row_units);
            const suffix = try spliceIndexRuntime(runtime, roots[1], row_units.len);
            roots[5] = try runtime.createString(row_units[suffix..]);
            try new_row.append(runtime.allocator, roots[5]);
        } else {
            const buffer = row.object().?.payload.byte_buffer;
            const suffix = try spliceIndexRuntime(runtime, roots[1], buffer.bytes.len);
            roots[5] = try aotByteBufferSlice(runtime, buffer, suffix, buffer.bytes.len);
            try new_row.append(runtime.allocator, roots[5]);
        }
        try result.append(runtime.allocator, roots[4]);
    }
    return roots[3];
}

pub fn aotByteBufferSlice(runtime: *Runtime, buffer: ByteBuffer, start: usize, end: usize) !Value {
    const bytes = buffer.bytes[start..end];
    return switch (buffer.kind) {
        .buffer => runtime.createByteBufferView(buffer, start, end),
        .uint8_array => runtime.createUint8Array(bytes),
        .array_buffer => runtime.createArrayBuffer(bytes),
    };
}

pub fn tableDeleteColumnBuiltin(runtime: *Runtime, source: Value, column: Value) !Value {
    var roots = [_]Value{ source, column, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[2] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[2]);
    const source_object = roots[0].object().?;
    try runtime.normalizeAotArrayPresence(source_object);
    for (rows.items, 0..) |row, row_index| {
        if (!runtime.aotArrayIsPresent(source_object, row_index)) continue;
        const row_items = try arrayItems(row);
        const row_object = row.object().?;
        try runtime.normalizeAotArrayPresence(row_object);
        const index = try spliceIndexRuntime(runtime, roots[1], row_items.items.len);
        roots[3] = try runtime.createArray(&.{});
        const new_row = try arrayItems(roots[3]);
        try new_row.ensureTotalCapacity(runtime.allocator, row_items.items.len - @intFromBool(index < row_items.items.len));
        for (row_items.items, 0..) |item, item_index| if (item_index != index) try appendAotArraySlot(runtime, roots[3].object().?, item, runtime.aotArrayIsPresent(row_object, item_index));
        try result.append(runtime.allocator, roots[3]);
    }
    return roots[2];
}

pub fn tableColumnSumBuiltin(runtime: *Runtime, source: Value, column: Value) !Value {
    var roots = [_]Value{ source, column, numberValue(0), .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const source_object = roots[0].object().?;
    try runtime.normalizeAotArrayPresence(source_object);
    for (source_object.payload.array.items, 0..) |row, index| {
        if (!runtime.aotArrayIsPresent(source_object, index)) continue;
        roots[3] = try tableRowProperty(runtime, row, roots[1]);
        roots[2] = try jsAdd(runtime, roots[2], roots[3]);
    }
    return roots[2];
}

/// The table regex commands use `new RegExp(s)`, unlike the general regexp
/// commands whose `/pattern/flags` notation is part of their public API.
/// Keep this validation outside the row loop so an invalid pattern fails even
/// for an empty table or an already-out-of-range start row.
pub fn tableRegexpPatternUnitsAlloc(runtime: *Runtime, pattern: Value) ![]u16 {
    if (pattern.tag == @intFromEnum(Tag.undefined)) return runtime.allocator.alloc(u16, 0);
    return valueUtf16Alloc(runtime, pattern);
}

pub fn tableRegexpSearchBuiltin(runtime: *Runtime, source: Value, row_value: Value, column: Value, pattern: Value) !Value {
    var roots = [_]Value{ source, column, row_value, pattern, row_value, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const pattern_units = try tableRegexpPatternUnitsAlloc(runtime, roots[3]);
    defer runtime.allocator.free(pattern_units);
    var compiled = regexp.RawPattern.init(runtime.allocator, pattern_units, false) catch |failure| {
        try setRegexpCompileFailureMessage(runtime, pattern_units, false, failure);
        return failure;
    };
    defer compiled.deinit();
    const rows = try arrayItems(roots[0]);
    while (try compareValues(runtime, .less, roots[4], numberValue(@floatFromInt(rows.items.len)))) {
        roots[5] = try tableRowProperty(runtime, roots[0], roots[4]);
        roots[6] = try tableRowProperty(runtime, roots[5], roots[1]);
        const source_units = try valueUtf16Alloc(runtime, roots[6]);
        defer runtime.allocator.free(source_units);
        if (try compiled.matches(source_units)) return roots[4];
        roots[4] = try incrementTableSearchRow(runtime, roots[4]);
    }
    return numberValue(-1);
}

pub fn tableRegexpPickupBuiltin(runtime: *Runtime, source: Value, column: Value, pattern: Value) !Value {
    var roots = [_]Value{ source, column, pattern, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const pattern_units = try tableRegexpPatternUnitsAlloc(runtime, roots[2]);
    defer runtime.allocator.free(pattern_units);
    var compiled = regexp.RawPattern.init(runtime.allocator, pattern_units, false) catch |failure| {
        try setRegexpCompileFailureMessage(runtime, pattern_units, false, failure);
        return failure;
    };
    defer compiled.deinit();
    roots[3] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[3]);
    for ((try arrayItems(roots[0])).items) |row| {
        roots[4] = try tableRowProperty(runtime, row, roots[1]);
        const source_units = try valueUtf16Alloc(runtime, roots[4]);
        defer runtime.allocator.free(source_units);
        if (!(try compiled.matches(source_units))) continue;
        // Upstream uses row.slice(0): create a new shallow array and retain
        // each element's identity. String.slice(0) returns the same immutable
        // string value; rows without slice fail only after they match.
        if (row.tag == @intFromEnum(Tag.array)) {
            roots[5] = try runtime.createArray(&.{});
            const copy = try arrayItems(roots[5]);
            const row_object = row.object().?;
            try runtime.normalizeAotArrayPresence(row_object);
            const row_items = try arrayItems(row);
            try copy.ensureTotalCapacity(runtime.allocator, row_items.items.len);
            for (row_items.items, 0..) |item, index| {
                try appendAotArraySlot(runtime, roots[5].object().?, item, runtime.aotArrayIsPresent(row_object, index));
            }
        } else if (isString(row)) {
            roots[5] = row;
        } else if (row.tag == @intFromEnum(Tag.byte_buffer)) {
            const buffer = row.object().?.payload.byte_buffer;
            roots[5] = switch (buffer.kind) {
                .buffer => try runtime.createByteBufferView(buffer, 0, buffer.bytes.len),
                .uint8_array => try runtime.createUint8Array(buffer.bytes),
                .array_buffer => try runtime.createArrayBuffer(buffer.bytes),
            };
        } else return error.ArrayExpected;
        try result.append(runtime.allocator, roots[5]);
    }
    return roots[3];
}

pub fn incrementTableSearchRow(runtime: *Runtime, row: Value) !Value {
    if (row.tag == @intFromEnum(Tag.bigint)) {
        var one = try BigInt.init(runtime.allocator, 1);
        defer one.deinit();
        return runtime.ownBigInt(try row.object().?.payload.bigint.add(runtime.allocator, one));
    }
    return numberValue(try valueToNumberRuntime(runtime, row) + 1);
}

pub fn compareTableRowsBuiltin(
    runtime: *Runtime,
    left: Value,
    left_present: bool,
    right: Value,
    right_present: bool,
    column: Value,
    numeric: bool,
    left_cell: *Value,
    right_cell: *Value,
) !std.math.Order {
    if (!left_present) return if (!right_present) .eq else .gt;
    if (!right_present) return .lt;
    if (left.tag == @intFromEnum(Tag.undefined)) return if (right.tag == @intFromEnum(Tag.undefined)) .eq else .gt;
    if (right.tag == @intFromEnum(Tag.undefined)) return .lt;
    left_cell.* = try tableRowProperty(runtime, left, column);
    right_cell.* = try tableRowProperty(runtime, right, column);
    // The official comparator returns before relational conversion when the
    // two selected cells are JavaScript-strictly equal. This is observable
    // for repeated object cells with a custom valueOf/toString method.
    if (!numeric and try strictEqual(runtime, left_cell.*, right_cell.*)) return .eq;
    if (numeric) {
        // Match the official `ns - ms` comparator.  Arithmetic performs
        // ToNumeric first, so mixed BigInt/Number cells reject with the
        // JavaScript mixing error and a BigInt result is rejected when the
        // sort algorithm converts the comparator result to Number.
        const difference = try arithmetic(runtime, .subtract, left_cell.*, right_cell.*);
        const number = try valueToNumberRuntime(runtime, difference);
        return if (std.math.isNan(number)) .eq else std.math.order(number, 0);
    }
    // The official table comparator returns `1` whenever `ns < ms` is false
    // after its strict-equality fast path.  This includes NaN and undefined
    // cells, whose non-antisymmetric result must not be collapsed to equal.
    return (try relationalOrder(runtime, left_cell.*, right_cell.*)) orelse .gt;
}

pub fn tableSortBuiltin(runtime: *Runtime, source: Value, column: Value, numeric: bool) !Value {
    // The official commands mutate and return the original table.  Keep the
    // current row and both compared cells rooted because property lookup and
    // ToPrimitive/Number conversion may allocate and trigger collection.
    var roots = [_]Value{ source, column, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const object = roots[0].object().?;
    try runtime.normalizeAotArrayPresence(object);
    const rows = &object.payload.array;
    const original_length = rows.items.len;
    if (original_length < v8_small_callback_sort_limit) {
        // Array.prototype.sort collects the indexed rows before it invokes
        // the comparator. Keep the small-table path detached so a cell's
        // valueOf/toString side effect cannot invalidate the values that the
        // official sort already collected.
        const temporary = try runtime.allocator.dupe(Value, rows.items);
        defer runtime.allocator.free(temporary);
        const temporary_presence = try runtime.allocator.dupe(bool, object.array_presence.items);
        defer runtime.allocator.free(temporary_presence);
        const root_count = std.math.add(usize, 5, original_length) catch return error.ArrayTooLarge;
        const root_values = try runtime.allocator.alloc(Value, root_count);
        defer runtime.allocator.free(root_values);
        root_values[0] = source;
        root_values[1] = column;
        root_values[2] = .{};
        root_values[3] = .{};
        root_values[4] = .{};
        std.mem.copyForwards(Value, root_values[5..], temporary);
        var detached_roots = RootFrame{};
        runtime.pushRoots(&detached_roots, root_values.ptr, root_values.len);
        defer runtime.popRoots(&detached_roots);
        try v8SmallTableSortBuiltin(
            runtime,
            temporary,
            temporary_presence,
            &root_values[1],
            numeric,
            &root_values[2],
            &root_values[3],
            &root_values[4],
        );
        if (rows.items.len < original_length) {
            const old_length = rows.items.len;
            try rows.resize(runtime.allocator, original_length);
            @memset(rows.items[old_length..], .{});
            try object.array_presence.resize(runtime.allocator, original_length);
            @memset(object.array_presence.items[old_length..], false);
        }
        std.mem.copyForwards(Value, rows.items[0..original_length], temporary);
        std.mem.copyForwards(bool, object.array_presence.items[0..original_length], temporary_presence);
        return root_values[0];
    }
    // The large path uses the same V8 TimSort as Array.prototype.sort. Keep
    // the collected rows and both merge buffers detached from the live table
    // while property lookup and numeric conversion can allocate or mutate it.
    const temporary = try runtime.allocator.dupe(Value, rows.items);
    defer runtime.allocator.free(temporary);
    const temporary_second = try runtime.allocator.dupe(Value, temporary);
    defer runtime.allocator.free(temporary_second);
    const temporary_presence = try runtime.allocator.dupe(bool, object.array_presence.items);
    defer runtime.allocator.free(temporary_presence);
    const temporary_second_presence = try runtime.allocator.dupe(bool, temporary_presence);
    defer runtime.allocator.free(temporary_second_presence);
    const root_count = std.math.add(usize, 5, std.math.mul(usize, original_length, 2) catch return error.ArrayTooLarge) catch return error.ArrayTooLarge;
    const root_values = try runtime.allocator.alloc(Value, root_count);
    defer runtime.allocator.free(root_values);
    root_values[0] = source;
    root_values[1] = column;
    root_values[2] = .{};
    root_values[3] = .{};
    root_values[4] = .{};
    std.mem.copyForwards(Value, root_values[5 .. 5 + original_length], temporary);
    std.mem.copyForwards(Value, root_values[5 + original_length ..], temporary_second);
    var detached_roots = RootFrame{};
    runtime.pushRoots(&detached_roots, root_values.ptr, root_values.len);
    defer runtime.popRoots(&detached_roots);
    var sort_context = V8SortContext{ .table = .{
        .column_root = &root_values[1],
        .numeric = numeric,
        .left_cell_root = &root_values[3],
        .right_cell_root = &root_values[4],
    } };
    try v8TimSortArrayCallback(
        runtime,
        temporary,
        temporary_presence,
        temporary_second,
        temporary_second_presence,
        &sort_context,
        &root_values[2],
    );
    if (rows.items.len < original_length) {
        const old_length = rows.items.len;
        try rows.resize(runtime.allocator, original_length);
        @memset(rows.items[old_length..], .{});
        try object.array_presence.resize(runtime.allocator, original_length);
        @memset(object.array_presence.items[old_length..], false);
    }
    std.mem.copyForwards(Value, rows.items[0..original_length], temporary);
    std.mem.copyForwards(bool, object.array_presence.items[0..original_length], temporary_presence);
    return root_values[0];
}

pub fn v8SmallTableSortBuiltin(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    column_root: *Value,
    numeric: bool,
    pivot_root: *Value,
    left_cell_root: *Value,
    right_cell_root: *Value,
) !void {
    // V8 uses CountAndMakeRun followed by BinaryInsertionSort for arrays
    // shorter than 64 elements. Table sort delegates to Array.sort too, so
    // the observable property conversion order follows the same path.
    if (items.len < 2) return;

    var run_length: usize = 2;
    const first_order = try compareTableRowsBuiltin(
        runtime,
        items[1],
        presence[1],
        items[0],
        presence[0],
        column_root.*,
        numeric,
        left_cell_root,
        right_cell_root,
    );
    if (first_order == .lt) {
        while (run_length < items.len) : (run_length += 1) {
            const order = try compareTableRowsBuiltin(
                runtime,
                items[run_length],
                presence[run_length],
                items[run_length - 1],
                presence[run_length - 1],
                column_root.*,
                numeric,
                left_cell_root,
                right_cell_root,
            );
            if (order != .lt) break;
        }
        var left: usize = 0;
        var right: usize = run_length - 1;
        while (left < right) : ({
            left += 1;
            right -= 1;
        }) {
            std.mem.swap(Value, &items[left], &items[right]);
            std.mem.swap(bool, &presence[left], &presence[right]);
        }
    } else {
        while (run_length < items.len) : (run_length += 1) {
            const order = try compareTableRowsBuiltin(
                runtime,
                items[run_length],
                presence[run_length],
                items[run_length - 1],
                presence[run_length - 1],
                column_root.*,
                numeric,
                left_cell_root,
                right_cell_root,
            );
            if (order == .lt) break;
        }
    }

    var start = run_length;
    while (start < items.len) : (start += 1) {
        pivot_root.* = items[start];
        const pivot_presence = presence[start];
        var left: usize = 0;
        var right: usize = start;
        while (left < right) {
            const middle = left + (right - left) / 2;
            const order = try compareTableRowsBuiltin(
                runtime,
                pivot_root.*,
                pivot_presence,
                items[middle],
                presence[middle],
                column_root.*,
                numeric,
                left_cell_root,
                right_cell_root,
            );
            if (order == .lt) right = middle else left = middle + 1;
        }
        var cursor = start;
        while (cursor > left) : (cursor -= 1) {
            items[cursor] = items[cursor - 1];
            presence[cursor] = presence[cursor - 1];
        }
        items[left] = pivot_root.*;
        presence[left] = pivot_presence;
    }
}

pub fn tableBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const source: Value = if (arguments.len > 0) arguments[0] else .{};
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    switch (command) {
        .table_sort, .table_numeric_sort => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            return tableSortBuiltin(runtime, source, arguments[1], command == .table_numeric_sort);
        },
        .table_row_count => return numberValue(@floatFromInt((try arrayItems(source)).items.len)),
        .table_column_count => return tableColumnCountBuiltin(runtime, source),
        .table_column => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            var roots = [_]Value{ source, arguments[1], .{}, .{} };
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            roots[2] = try runtime.createArray(&.{});
            const source_object = roots[0].object().?;
            try runtime.normalizeAotArrayPresence(source_object);
            const result_object = roots[2].object().?;
            for (source_object.payload.array.items, 0..) |row, index| {
                if (!runtime.aotArrayIsPresent(source_object, index)) {
                    try appendAotArraySlot(runtime, result_object, .{}, false);
                    continue;
                }
                roots[3] = try tableRowProperty(runtime, row, roots[1]);
                try appendAotArraySlot(runtime, result_object, roots[3], true);
            }
            return roots[2];
        },
        .table_pickup, .table_exact_pickup => {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            var roots = [_]Value{ source, arguments[1], arguments[2], .{}, .{} };
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            roots[3] = try runtime.createArray(&.{});
            const result = try arrayItems(roots[3]);
            const source_object = roots[0].object().?;
            try runtime.normalizeAotArrayPresence(source_object);
            for (source_object.payload.array.items, 0..) |row, index| {
                // Array.prototype.filter skips holes but still invokes its
                // callback for an explicit undefined row.
                if (!runtime.aotArrayIsPresent(source_object, index)) continue;
                roots[4] = try tableRowProperty(runtime, row, roots[1]);
                const matches = if (command == .table_exact_pickup)
                    try strictEqual(runtime, roots[4], roots[2])
                else blk: {
                    const cell_units = try valueUtf16Alloc(runtime, roots[4]);
                    defer runtime.allocator.free(cell_units);
                    const needle_units = try valueUtf16Alloc(runtime, roots[2]);
                    defer runtime.allocator.free(needle_units);
                    break :blk std.mem.indexOf(u16, cell_units, needle_units) != null;
                };
                if (matches) try result.append(runtime.allocator, row);
            }
            return roots[3];
        },
        .table_search => {
            if (arguments.len < 4) return error.InvalidArgumentCount;
            return tableSearchBuiltin(runtime, source, arguments[1], arguments[2], arguments[3]);
        },
        .table_regexp_search => {
            if (arguments.len < 4) return error.InvalidArgumentCount;
            return tableRegexpSearchBuiltin(runtime, source, arguments[1], arguments[2], arguments[3]);
        },
        .table_regexp_pickup => {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            return tableRegexpPickupBuiltin(runtime, source, arguments[1], arguments[2]);
        },
        .table_transpose, .table_rotate => return tableTransposeBuiltin(runtime, source, command == .table_rotate),
        .table_unique => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            return tableUniqueBuiltin(runtime, source, arguments[1]);
        },
        .table_insert_column => {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            return tableInsertColumnBuiltin(runtime, source, arguments[1], arguments[2]);
        },
        .table_delete_column => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            return tableDeleteColumnBuiltin(runtime, source, arguments[1]);
        },
        .table_column_sum => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            return tableColumnSumBuiltin(runtime, source, arguments[1]);
        },
        else => return error.UnknownCommand,
    }
}

const CloneState = struct {
    active: std.ArrayList(*Object) = .empty,

    pub fn deinit(self: *CloneState, allocator: std.mem.Allocator) void {
        self.active.deinit(allocator);
    }
};

/// `配列複製` is the upstream JSON.stringify/JSON.parse operation.  Keep the
/// JSON-specific rules here instead of using the general value copier: NaN and
/// infinities become null, undefined/functions disappear from objects (and
/// become null in arrays), and cycles/BigInt are errors.
pub fn deepCloneBuiltin(runtime: *Runtime, source: Value) !Value {
    if (source.tag == @intFromEnum(Tag.undefined) or source.tag == @intFromEnum(Tag.function)) return error.InvalidJsonCloneValue;
    var state: CloneState = .{};
    defer state.deinit(runtime.allocator);
    return deepCloneValue(runtime, source, &state);
}

pub fn deepCloneValue(runtime: *Runtime, source: Value, state: *CloneState) !Value {
    return switch (@as(Tag, @enumFromInt(source.tag))) {
        .undefined, .function => .{},
        .null_value, .boolean => source,
        .number => blk: {
            const number: f64 = @bitCast(source.payload);
            break :blk if (std.math.isFinite(number)) numberValue(if (number == 0) 0 else number) else .{ .tag = @intFromEnum(Tag.null_value) };
        },
        .bigint => error.CannotSerializeBigInt,
        .byte_buffer => blk: {
            const serialized = try jsonEncodeBuiltin(runtime, source, false);
            var roots = [_]Value{serialized};
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            break :blk try jsonDecodeBuiltin(runtime, roots[0]);
        },
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, source);
            defer runtime.allocator.free(units);
            break :blk try runtime.createString(units);
        },
        .array => {
            const object = source.object() orelse return error.InvalidArray;
            if (object.payload != .array) return error.InvalidArray;
            for (state.active.items) |active| if (active == object) return error.CircularCloneValue;
            try state.active.append(runtime.allocator, object);
            defer _ = state.active.pop();
            const result = try runtime.createArray(&.{});
            var roots = [_]Value{result};
            var frame: RootFrame = .{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            const values = object.payload.array.items;
            try roots[0].object().?.payload.array.ensureTotalCapacity(runtime.allocator, values.len);
            for (values) |item| {
                var cloned = try deepCloneValue(runtime, item, state);
                if (cloned.tag == @intFromEnum(Tag.undefined) or cloned.tag == @intFromEnum(Tag.function)) cloned = .{ .tag = @intFromEnum(Tag.null_value) };
                try roots[0].object().?.payload.array.append(runtime.allocator, cloned);
            }
            return roots[0];
        },
        .dictionary => {
            const object = source.object() orelse return error.InvalidDictionary;
            if (object.payload != .dictionary) return error.InvalidDictionary;
            for (state.active.items) |active| if (active == object) return error.CircularCloneValue;
            try state.active.append(runtime.allocator, object);
            defer _ = state.active.pop();
            const result = try runtime.createDictionary(&.{});
            var roots = [_]Value{result};
            var frame: RootFrame = .{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            for (object.payload.dictionary.items) |entry| {
                const cloned = try deepCloneValue(runtime, entry.value, state);
                if (cloned.tag == @intFromEnum(Tag.undefined) or cloned.tag == @intFromEnum(Tag.function)) continue;
                try runtime.setDictionary(&roots[0].object().?.payload.dictionary, entry.key, cloned);
            }
            return roots[0];
        },
        .iterator, .promise => runtime.createDictionary(&.{}),
        .binding_cell => unreachable,
    };
}

const SliceRange = struct { start: usize, end: usize };

pub fn sliceIndex(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number == 0) return 0;
    if (number == std.math.inf(f64)) return length;
    if (number == -std.math.inf(f64)) return 0;
    const integer = @trunc(number);
    if (integer < 0) {
        const magnitude = @min(-integer, @as(f64, @floatFromInt(length)));
        return length - @as(usize, @intFromFloat(magnitude));
    }
    if (integer >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(integer);
}

pub fn directIndex(number: f64) ?usize {
    if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number) return null;
    if (number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(number);
}

pub fn bigIntPropertyIndex(value: BigInt, length: usize) ?usize {
    const integer = value.toI64() catch return null;
    if (integer < 0) return null;
    const index = std.math.cast(usize, integer) orelse return null;
    return if (index < length) index else null;
}

pub fn charAtIndex(number: f64, length: usize) ?usize {
    if (std.math.isNan(number) or number == 0) return if (length > 0) 0 else null;
    if (!std.math.isFinite(number)) return null;
    const integer = @trunc(number);
    if (integer < 0 or integer >= @as(f64, @floatFromInt(length))) return null;
    return @intFromFloat(integer);
}

pub fn sliceRange(runtime: *Runtime, index: Value, length: usize) !?SliceRange {
    if (index.tag == @intFromEnum(Tag.null_value)) return error.ArrayCutNullIndex;
    if (index.tag != @intFromEnum(Tag.dictionary) and index.tag != @intFromEnum(Tag.array)) return null;
    const first = dictionaryProperty(index, &.{ 0x5148, 0x982d });
    if (first.tag != @intFromEnum(Tag.number)) return null;
    const last = dictionaryProperty(index, &.{ 0x672b, 0x5c3e });
    const start = sliceIndex(@bitCast(first.payload), length);
    const end_number = try explicitRangeNumber(runtime, last);
    const end = sliceIndex(end_number + 1, length);
    return .{ .start = start, .end = end };
}

pub fn substringRange(runtime: *Runtime, index: Value, length: usize) !?SliceRange {
    if (index.tag == @intFromEnum(Tag.null_value)) return error.ArrayCutNullIndex;
    if (index.tag != @intFromEnum(Tag.dictionary) and index.tag != @intFromEnum(Tag.array)) return null;
    const first = dictionaryProperty(index, &.{ 0x5148, 0x982d });
    if (first.tag != @intFromEnum(Tag.number)) return null;
    const last = dictionaryProperty(index, &.{ 0x672b, 0x5c3e });
    const first_number: f64 = @bitCast(first.payload);
    const last_number = try explicitRangeNumber(runtime, last) + 1;
    const normalize = struct {
        pub fn apply(number: f64, size: usize) usize {
            if (std.math.isNan(number) or number <= 0 or number == -std.math.inf(f64)) return 0;
            if (number == std.math.inf(f64)) return size;
            if (number >= @as(f64, @floatFromInt(size))) return size;
            return @intFromFloat(@trunc(number));
        }
    }.apply;
    var start = normalize(first_number, length);
    var end = normalize(last_number, length);
    if (start > end) std.mem.swap(usize, &start, &end);
    return .{ .start = start, .end = end };
}

pub fn arrayRangeCopyBuiltin(runtime: *Runtime, source: Value, index: Value) !Value {
    var rooted = [_]Value{ source, index, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    if (rooted[0].tag != @intFromEnum(Tag.array)) return error.ArrayRangeCopyReceiver;
    const items = try arrayItems(rooted[0]);
    if (rooted[1].tag == @intFromEnum(Tag.number)) {
        const position = directIndex(@bitCast(rooted[1].payload)) orelse return .{};
        if (position >= items.items.len) return .{};
        const item = items.items[position];
        return switch (@as(Tag, @enumFromInt(item.tag))) {
            .array, .dictionary, .iterator, .null_value => deepCloneBuiltin(runtime, item),
            else => item,
        };
    }
    const range = (try sliceRange(runtime, rooted[1], items.items.len)) orelse return .{};
    if (range.end <= range.start) return runtime.createArray(&.{});
    rooted[2] = try runtime.createArray(&.{});
    const values = items.items[range.start..range.end];
    try rooted[2].object().?.payload.array.ensureTotalCapacity(runtime.allocator, values.len);
    var state: CloneState = .{};
    defer state.deinit(runtime.allocator);
    for (values) |item| {
        var cloned = try deepCloneValue(runtime, item, &state);
        if (cloned.tag == @intFromEnum(Tag.undefined) or cloned.tag == @intFromEnum(Tag.function)) cloned = .{ .tag = @intFromEnum(Tag.null_value) };
        try appendAotArraySlot(runtime, rooted[2].object().?, cloned, true);
    }
    return rooted[2];
}

pub fn referenceBuiltin(runtime: *Runtime, source: Value, index: Value) !Value {
    var rooted = [_]Value{ source, index, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    if (isString(rooted[0])) {
        const units = try valueUtf16Alloc(runtime, rooted[0]);
        defer runtime.allocator.free(units);
        if (rooted[1].tag == @intFromEnum(Tag.number)) {
            const position = charAtIndex(@bitCast(rooted[1].payload), units.len) orelse return runtime.createString(&.{});
            return runtime.createString(units[position .. position + 1]);
        }
        const range = (try substringRange(runtime, rooted[1], units.len)) orelse return invalidStringRangeBuiltin(runtime, rooted[1]);
        const start = @min(range.start, units.len);
        const end = @min(range.end, units.len);
        return runtime.createString(units[start..end]);
    }
    if (rooted[0].tag == @intFromEnum(Tag.array)) {
        const items = try arrayItems(rooted[0]);
        if (rooted[1].tag == @intFromEnum(Tag.number)) {
            const position = directIndex(@bitCast(rooted[1].payload)) orelse return runtime.aotArrayPropertyGet(rooted[0].object().?, rooted[1]);
            return if (position <= 4_294_967_294 and position < items.items.len) items.items[position] else runtime.aotArrayPropertyGet(rooted[0].object().?, rooted[1]);
        }
        if (rooted[1].tag == @intFromEnum(Tag.bigint)) {
            const position = bigIntPropertyIndex(rooted[1].object().?.payload.bigint, items.items.len) orelse return runtime.aotArrayPropertyGet(rooted[0].object().?, rooted[1]);
            return items.items[position];
        }
        if (isString(rooted[1])) return tableRowProperty(runtime, rooted[0], rooted[1]);
        const range = (try sliceRange(runtime, rooted[1], items.items.len)) orelse return .{};
        const start = @min(range.start, items.items.len);
        const end = @min(@max(range.end, start), items.items.len);
        const source_object = rooted[0].object().?;
        try runtime.normalizeAotArrayPresence(source_object);
        rooted[2] = try runtime.createArray(&.{});
        const result_object = rooted[2].object().?;
        try result_object.payload.array.ensureTotalCapacity(runtime.allocator, end - start);
        try result_object.array_presence.ensureTotalCapacity(runtime.allocator, end - start);
        for (items.items[start..end], start..) |item, source_index| {
            try appendAotArraySlot(runtime, result_object, item, runtime.aotArrayIsPresent(source_object, source_index));
        }
        return rooted[2];
    }
    if (rooted[0].tag == @intFromEnum(Tag.byte_buffer)) return tableRowProperty(runtime, rooted[0], rooted[1]);
    if (rooted[0].tag == @intFromEnum(Tag.dictionary)) {
        const key = try valueUtf16Alloc(runtime, rooted[1]);
        defer runtime.allocator.free(key);
        if (dictionaryOwnProperty(rooted[0], key)) |value| return value;
        if (try tableInheritedProperty(runtime, rooted[0], .dictionary, key)) |value| return value;
        return .{};
    }
    return error.IndexableValueExpected;
}

pub fn invalidStringRangeBuiltin(runtime: *Runtime, index: Value) !Value {
    const encoded = try jsonEncodeBuiltin(runtime, index, false);
    var roots = [_]Value{encoded};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    var message: std.ArrayList(u16) = .empty;
    errdefer message.deinit(runtime.allocator);
    try appendUtf8Units(&message, runtime.allocator, "『参照』で文字列型の範囲指定(");
    if (roots[0].tag == @intFromEnum(Tag.undefined)) {
        try appendAsciiUnits(&message, runtime.allocator, "undefined");
    } else {
        try message.appendSlice(runtime.allocator, roots[0].object().?.payload.utf16_string);
    }
    try appendUtf8Units(&message, runtime.allocator, ")が不正です。");
    runtime.setFailureUnits(message.items);
    return error.InvalidStringRange;
}

pub fn appendAotArraySlot(runtime: *Runtime, object: *Object, value: Value, present: bool) !void {
    const index = object.payload.array.items.len;
    try runtime.aotArrayAppend(object, value);
    if (!present) object.array_presence.items[index] = false;
}

pub fn arrayAddBuiltin(runtime: *Runtime, source: Value, other: Value) !Value {
    var roots = [_]Value{ source, other, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array)) return deepCloneBuiltin(runtime, roots[0]);
    roots[2] = try runtime.createArray(&.{});
    const source_object = roots[0].object().?;
    try runtime.normalizeAotArrayPresence(source_object);
    const source_items = &source_object.payload.array;
    const other_is_array = roots[1].tag == @intFromEnum(Tag.array);
    const other_object = if (other_is_array) roots[1].object().? else null;
    if (other_object) |object| try runtime.normalizeAotArrayPresence(object);
    const extra: usize = if (roots[1].tag == @intFromEnum(Tag.array)) (try arrayItems(roots[1])).items.len else 1;
    const final_length = std.math.add(usize, source_items.items.len, extra) catch return error.ArrayTooLarge;
    const result_object = roots[2].object().?;
    const result = &result_object.payload.array;
    try result.ensureTotalCapacity(runtime.allocator, final_length);
    try result_object.array_presence.ensureTotalCapacity(runtime.allocator, final_length);
    for (source_items.items, 0..) |item, source_index| {
        try appendAotArraySlot(runtime, result_object, item, runtime.aotArrayIsPresent(source_object, source_index));
    }
    if (other_is_array) {
        const other_array = other_object.?;
        for (other_array.payload.array.items, 0..) |item, other_index| {
            try appendAotArraySlot(runtime, result_object, item, runtime.aotArrayIsPresent(other_array, other_index));
        }
    } else {
        try appendAotArraySlot(runtime, result_object, roots[1], true);
    }
    return roots[2];
}

pub fn arrayExtremumBuiltin(runtime: *Runtime, source: Value, maximum: bool) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    const items = object.payload.array.items;
    var first_index: ?usize = null;
    for (items, 0..) |_, index| if (runtime.aotArrayIsPresent(object, index)) {
        first_index = index;
        break;
    };
    const first = first_index orelse return error.NonEmptyArrayExpected;
    var present_count: usize = 0;
    for (items, 0..) |_, index| {
        if (runtime.aotArrayIsPresent(object, index)) present_count += 1;
    }
    if (present_count == 1) return items[first];
    var result = try valueToNumberRuntime(runtime, items[first]);
    for (items[first + 1 ..], 0..) |item, offset| {
        if (!runtime.aotArrayIsPresent(object, first + 1 + offset)) continue;
        const number = try valueToNumberRuntime(runtime, item);
        if (std.math.isNan(number) or std.math.isNan(result)) {
            result = std.math.nan(f64);
        } else if ((maximum and (number > result or (number == result and isNegativeZero(result)))) or
            (!maximum and (number < result or (number == result and isNegativeZero(number)))))
        {
            result = number;
        }
    }
    return numberValue(result);
}

pub fn isNegativeZero(number: f64) bool {
    return number == 0 and (@as(u64, @bitCast(number)) >> 63) != 0;
}

pub fn arraySumBuiltin(runtime: *Runtime, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    var total: f64 = 0;
    for (object.payload.array.items, 0..) |item, index| {
        if (!runtime.aotArrayIsPresent(object, index)) continue;
        const number = try parseFloatBuiltin(runtime, item);
        if (!std.math.isNan(number)) total += number;
    }
    return numberValue(total);
}

pub fn arraySwapBuiltin(runtime: *Runtime, source: Value, first_value: Value, second_value: Value) !Value {
    var roots = [_]Value{ source, first_value, second_value };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const first_units = try valueUtf16Alloc(runtime, roots[1]);
    defer runtime.allocator.free(first_units);
    const second_units = try valueUtf16Alloc(runtime, roots[2]);
    defer runtime.allocator.free(second_units);
    if (std.mem.eql(u16, first_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or
        std.mem.eql(u16, second_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthAssignment;
    const first = runtime.aotCanonicalArrayIndexUnits(first_units);
    const second = runtime.aotCanonicalArrayIndexUnits(second_units);
    const largest_index = if (first) |first_index| if (second) |second_index| @max(first_index, second_index) else first_index else second;
    if (largest_index) |index| {
        const required_length = std.math.add(usize, index, 1) catch return error.ArraySparseLengthLimit;
        const items = &roots[0].object().?.payload.array.items;
        if (required_length > items.len and required_length > safe_array_element_limit) return error.ArraySparseLengthLimit;
    }
    const array = roots[0].object().?;
    const first_item = runtime.aotArrayPropertyGet(array, roots[1]);
    const second_item = runtime.aotArrayPropertyGet(array, roots[2]);
    try runtime.aotArrayPropertySet(array, roots[1], second_item);
    try runtime.aotArrayPropertySet(array, roots[2], first_item);
    return roots[0];
}

pub fn fillArrayLength(number: f64, maximum: usize) !usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > @as(f64, @floatFromInt(maximum))) return error.ArrayFillSizeLimit;
    return @intFromFloat(@floor(number));
}

pub fn arraySequenceBuiltin(runtime: *Runtime, first_value: Value, last_value: Value) !Value {
    var roots = [_]Value{ first_value, last_value, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try runtime.createArray(&.{});
    roots[3] = try runtime.createBigInt("1n");
    const result_items = try arrayItems(roots[2]);
    var count: usize = 0;
    const lessEqual = struct {
        pub fn check(rt: *Runtime, left: Value, right: Value) !bool {
            if (left.tag == @intFromEnum(Tag.bigint) and right.tag == @intFromEnum(Tag.bigint)) {
                return BigInt.order(left.object().?.payload.bigint, right.object().?.payload.bigint) != .gt;
            }
            return compareValues(rt, .less_equal, left, right);
        }
    }.check;
    while (try lessEqual(runtime, roots[0], roots[1])) {
        if (count >= safe_array_element_limit) return error.ArraySequenceSizeLimit;
        if (roots[1].tag != @intFromEnum(Tag.bigint) and try valueToNumberRuntime(runtime, roots[1]) == std.math.inf(f64)) return error.ArraySequenceSizeLimit;
        try result_items.append(runtime.allocator, roots[0]);
        if (roots[0].tag == @intFromEnum(Tag.bigint)) {
            roots[0] = try bigIntArithmetic(runtime, .add, roots[0], roots[3]);
        } else {
            const current_number = try valueToNumberRuntime(runtime, roots[0]);
            const next = numberValue(current_number + 1);
            if (@as(f64, @bitCast(next.payload)) == current_number and try lessEqual(runtime, next, roots[1])) return error.ArraySequenceSizeLimit;
            roots[0] = next;
        }
        count += 1;
    }
    return roots[2];
}

pub fn arrayFillBuiltin(runtime: *Runtime, value: Value, shape: Value) !Value {
    var roots = [_]Value{ value, shape };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[1].tag == @intFromEnum(Tag.array)) try validateFillDimensions(runtime, roots[1]);
    return arrayFillAtDepth(runtime, roots[0], roots[1], 0);
}

pub fn validateFillDimensions(runtime: *Runtime, shape: Value) !void {
    const dimensions = try arrayItems(shape);
    var product: usize = 1;
    var total: usize = 0;
    for (dimensions.items) |dimension| {
        const count = try fillArrayLength(try valueToNumberRuntime(runtime, dimension), safe_array_element_limit);
        product = std.math.mul(usize, product, count) catch return error.ArrayFillSizeLimit;
        total = std.math.add(usize, total, product) catch return error.ArrayFillSizeLimit;
        if (total > safe_array_element_limit) return error.ArrayFillSizeLimit;
        if (product == 0) break;
    }
}

pub fn cloneFillValue(runtime: *Runtime, value: Value) !Value {
    if (value.tag != @intFromEnum(Tag.array)) return switch (@as(Tag, @enumFromInt(value.tag))) {
        .dictionary, .byte_buffer, .iterator, .promise => deepCloneBuiltin(runtime, value),
        else => value,
    };
    const source = try arrayItems(value);
    const result = try runtime.createArray(&.{});
    var roots = [_]Value{ value, result };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const destination = try arrayItems(roots[1]);
    try runtime.normalizeAotArrayPresence(roots[0].object().?);
    try destination.ensureTotalCapacity(runtime.allocator, source.items.len);
    for (source.items, 0..) |item, index| {
        try appendAotArraySlot(runtime, roots[1].object().?, try cloneFillValue(runtime, item), runtime.aotArrayIsPresent(roots[0].object().?, index));
    }
    return roots[1];
}

pub fn arrayFillAtDepth(runtime: *Runtime, value: Value, shape: Value, depth: usize) !Value {
    if (shape.tag != @intFromEnum(Tag.array)) {
        const count = try fillArrayLength(try valueToNumberRuntime(runtime, shape), safe_array_element_limit - 1);
        const result = try runtime.createArray(&.{});
        var roots = [_]Value{ value, result };
        var frame: RootFrame = .{};
        runtime.pushRoots(&frame, &roots, roots.len);
        defer runtime.popRoots(&frame);
        const items = try arrayItems(roots[1]);
        try items.ensureTotalCapacity(runtime.allocator, count);
        for (0..count) |_| try items.append(runtime.allocator, try cloneFillValue(runtime, roots[0]));
        return roots[1];
    }
    const dimensions = try arrayItems(shape);
    if (dimensions.items.len == 0 and depth == 0) return runtime.createArray(&.{});
    if (depth >= dimensions.items.len) return cloneFillValue(runtime, value);
    const count = try fillArrayLength(try valueToNumberRuntime(runtime, dimensions.items[depth]), safe_array_element_limit);
    const result = try runtime.createArray(&.{});
    var roots = [_]Value{ value, shape, result };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const items = try arrayItems(roots[2]);
    try items.ensureTotalCapacity(runtime.allocator, count);
    for (0..count) |_| try items.append(runtime.allocator, try arrayFillAtDepth(runtime, roots[0], roots[1], depth + 1));
    return roots[2];
}

pub fn explodeBuiltin(runtime: *Runtime, value: Value) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createArray(&.{});
    var index: usize = 0;
    while (index < units.len) {
        const length = codePointLength(units, index);
        roots[1] = try runtime.createString(units[index .. index + length]);
        try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
        index += length;
    }
    return roots[0];
}

pub fn refrainBuiltin(runtime: *Runtime, value: Value, count_value: Value) !Value {
    const count_number = try valueToNumberRuntime(runtime, count_value);
    if (std.math.isNan(count_number) or count_number <= 0) return runtime.createString(&.{});
    if (!std.math.isFinite(count_number) or count_number > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.RepetitionTooLarge;
    const count: usize = @intFromFloat(@ceil(count_number));
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const length = std.math.mul(usize, units.len, count) catch return error.RepetitionTooLarge;
    const output = try runtime.allocator.alloc(u16, length);
    for (0..count) |index| @memcpy(output[index * units.len ..][0..units.len], units);
    return runtime.ownString(output);
}

pub fn occurrenceBuiltin(runtime: *Runtime, source: Value, needle: Value) !bool {
    if (source.tag == @intFromEnum(Tag.array)) {
        for (source.object().?.payload.array.items) |item| {
            if (try sameValueZero(runtime, item, needle)) return true;
        }
        return false;
    }
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const needle_units = try valueUtf16Alloc(runtime, needle);
    defer runtime.allocator.free(needle_units);
    return indexOfUnitsBuiltin(source_units, needle_units, 0) != null;
}

pub fn occurrenceCountBuiltin(runtime: *Runtime, source_value: Value, needle_value: Value) !i64 {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const needle = try valueUtf16Alloc(runtime, needle_value);
    defer runtime.allocator.free(needle);
    if (needle.len == 0) return @as(i64, @intCast(source.len)) - 1;
    var count: i64 = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u16, source, start, needle)) |found| {
        count += 1;
        start = found + needle.len;
    }
    return count;
}

pub fn substringBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const source = try valueUtf16Alloc(runtime, arguments[0]);
    defer runtime.allocator.free(source);
    const length = codePointCount(source);
    var start: usize = 0;
    var end: usize = length;
    switch (command) {
        .substring_mid => {
            var start_number = try substringNumberBuiltin(runtime, arguments[1]);
            const count_number = try substringNumberBuiltin(runtime, arguments[2]);
            if (count_number <= 0) return runtime.createString(&.{});
            if (start_number < 0) {
                start_number = @as(f64, @floatFromInt(length)) + start_number + 1;
                if (start_number < 0) start_number = 1;
            }
            start = sliceIndexBuiltin(start_number - 1, length);
            end = sliceIndexBuiltin(start_number + count_number - 1, length);
            if (end <= start) return runtime.createString(&.{});
        },
        .substring_left => end = sliceIndexBuiltin(try valueToNumberRuntime(runtime, arguments[1]), length),
        .substring_right => {
            var index_number = @as(f64, @floatFromInt(length)) - try valueToNumberRuntime(runtime, arguments[1]);
            if (index_number < 0) index_number = 0;
            start = sliceIndexBuiltin(index_number, length);
        },
        else => unreachable,
    }
    return runtime.createString(source[codePointOffsetBuiltin(source, start)..codePointOffsetBuiltin(source, end)]);
}

pub fn substringNumberBuiltin(runtime: *Runtime, value: Value) !f64 {
    return if (isString(value)) parseIntBuiltin(runtime, value) else valueToNumberRuntime(runtime, value);
}

pub fn sliceIndexBuiltin(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number == 0) return 0;
    const length_number: f64 = @floatFromInt(length);
    if (number >= length_number) return length;
    if (number <= -length_number) return 0;
    if (number < 0) return length - @as(usize, @intFromFloat(-@trunc(number)));
    return @intFromFloat(@trunc(number));
}

pub fn splitBuiltin(runtime: *Runtime, source_value: Value, delimiter_value: Value, first_only: bool) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const delimiter = try valueUtf16Alloc(runtime, delimiter_value);
    defer runtime.allocator.free(delimiter);
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createArray(&.{});
    if (first_only) {
        if (std.mem.indexOf(u16, source, delimiter)) |found| {
            try appendStringPart(runtime, &roots, source[0..found]);
            try appendStringPart(runtime, &roots, source[found + delimiter.len ..]);
        } else try appendStringPart(runtime, &roots, source);
        return roots[0];
    }
    if (delimiter.len == 0) {
        for (source) |unit| try appendStringPart(runtime, &roots, &.{unit});
        return roots[0];
    }
    var start: usize = 0;
    while (std.mem.indexOfPos(u16, source, start, delimiter)) |found| {
        try appendStringPart(runtime, &roots, source[start..found]);
        start = found + delimiter.len;
    }
    try appendStringPart(runtime, &roots, source[start..]);
    return roots[0];
}

pub fn appendStringPart(runtime: *Runtime, roots: *[2]Value, units: []const u16) !void {
    roots[1] = try runtime.createString(units);
    try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
}

pub fn stringRemoveBuiltin(runtime: *Runtime, source_value: Value, start_value: Value, count_value: Value) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const length = codePointCount(source);
    const start = sliceIndexBuiltin(try valueToNumberRuntime(runtime, start_value) - 1, length);
    const count = spliceDeleteCountBuiltin(try valueToNumberRuntime(runtime, count_value), length - start);
    const unit_start = codePointOffsetBuiltin(source, start);
    const unit_end = codePointOffsetBuiltin(source, start + count);
    const output = try runtime.allocator.alloc(u16, source.len - (unit_end - unit_start));
    @memcpy(output[0..unit_start], source[0..unit_start]);
    @memcpy(output[unit_start..], source[unit_end..]);
    return runtime.ownString(output);
}

pub fn spliceDeleteCountBuiltin(number: f64, remaining: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(remaining))) return remaining;
    return @intFromFloat(@trunc(number));
}

pub fn trimBuiltin(runtime: *Runtime, value: Value, trim_left: bool, trim_right: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var start: usize = 0;
    var end = units.len;
    if (trim_left) {
        while (start < end and string_mod.isEcmaWhitespace(units[start])) : (start += 1) {}
    }
    if (trim_right) {
        while (end > start and string_mod.isEcmaWhitespace(units[end - 1])) : (end -= 1) {}
    }
    return runtime.createString(units[start..end]);
}

pub fn unicodeCaseBuiltin(runtime: *Runtime, value: Value, uppercase: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var codepoints: std.ArrayList(u21) = .empty;
    defer codepoints.deinit(runtime.allocator);
    var unit_index: usize = 0;
    while (unit_index < units.len) {
        const length = codePointLength(units, unit_index);
        const codepoint: u21 = if (length == 2)
            @intCast(0x10000 + ((@as(u32, units[unit_index]) - 0xd800) << 10) + (@as(u32, units[unit_index + 1]) - 0xdc00))
        else
            @intCast(units[unit_index]);
        try codepoints.append(runtime.allocator, codepoint);
        unit_index += length;
    }

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    for (codepoints.items, 0..) |codepoint, index| {
        if (!uppercase and codepoint == 0x03a3 and isFinalSigmaBuiltin(codepoints.items, index)) {
            try output.append(runtime.allocator, 0x03c2);
            continue;
        }
        const mapped = if (uppercase) unicode_case.upper(codepoint) else unicode_case.lower(codepoint);
        if (mapped) |values| {
            for (values) |mapped_codepoint| try appendCodePointBuiltin(runtime.allocator, &output, mapped_codepoint);
        } else {
            try appendCodePointBuiltin(runtime.allocator, &output, codepoint);
        }
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn isFinalSigmaBuiltin(codepoints: []const u21, index: usize) bool {
    var before = index;
    var has_cased_before = false;
    while (before > 0) {
        before -= 1;
        if (unicode_case.isCaseIgnorable(codepoints[before])) continue;
        has_cased_before = unicode_case.isCased(codepoints[before]);
        break;
    }
    if (!has_cased_before) return false;
    var after = index + 1;
    while (after < codepoints.len) : (after += 1) {
        if (unicode_case.isCaseIgnorable(codepoints[after])) continue;
        return !unicode_case.isCased(codepoints[after]);
    }
    return true;
}

pub fn appendCodePointBuiltin(allocator: std.mem.Allocator, output: *std.ArrayList(u16), codepoint: u21) !void {
    if (codepoint <= 0xffff) return output.append(allocator, @intCast(codepoint));
    const offset: u32 = codepoint - 0x10000;
    try output.append(allocator, @intCast(0xd800 + (offset >> 10)));
    try output.append(allocator, @intCast(0xdc00 + (offset & 0x3ff)));
}

pub fn kanaOffsetBuiltin(runtime: *Runtime, value: Value, to_katakana: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const output = try runtime.allocator.dupe(u16, units);
    errdefer runtime.allocator.free(output);
    const first: u16 = if (to_katakana) 0x3041 else 0x30a1;
    const last: u16 = if (to_katakana) 0x3096 else 0x30f6;
    const offset: i32 = if (to_katakana) 0x60 else -0x60;
    for (output) |*unit| {
        if (unit.* >= first and unit.* <= last) unit.* = @intCast(@as(i32, unit.*) + offset);
    }
    return runtime.ownString(output);
}

pub fn asciiWidthBuiltin(runtime: *Runtime, value: Value, to_full: bool, symbols: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const output = try runtime.allocator.dupe(u16, units);
    for (output) |*unit| {
        if (to_full) {
            if (symbols and unit.* == 0x20) {
                unit.* = 0x3000;
            } else if ((symbols and unit.* >= 0x21 and unit.* <= 0x7e) or
                (!symbols and ((unit.* >= 'A' and unit.* <= 'Z') or
                    (unit.* >= 'a' and unit.* <= 'z') or
                    (unit.* >= '0' and unit.* <= '9'))))
            {
                unit.* += 0xfee0;
            }
        } else if (symbols and unit.* == 0x3000) {
            unit.* = 0x20;
        } else if ((symbols and unit.* >= 0xff00 and unit.* <= 0xff5f) or
            (!symbols and ((unit.* >= 0xff21 and unit.* <= 0xff3a) or
                (unit.* >= 0xff41 and unit.* <= 0xff5a) or
                (unit.* >= 0xff10 and unit.* <= 0xff19))))
        {
            unit.* -= 0xfee0;
        }
    }
    return runtime.ownString(output);
}

pub fn kanaWidthBuiltin(runtime: *Runtime, value: Value, to_full: bool) !Value {
    return kanaMapBuiltin(runtime, value, to_full);
}

pub fn widthBuiltin(runtime: *Runtime, value: Value, to_full: bool) !Value {
    // 公式実装と同じく、全角化はカナ→英数記号、半角化もカナ→英数記号の順に行う。
    var roots = [_]Value{.{}};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try kanaMapBuiltin(runtime, value, to_full);
    return asciiWidthBuiltin(runtime, roots[0], to_full, true);
}

pub fn currencyBuiltin(runtime: *Runtime, value: Value) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    var index: usize = 0;
    while (index < units.len) {
        if (!isAsciiDigitBuiltin(units[index])) {
            try output.append(runtime.allocator, units[index]);
            index += 1;
            continue;
        }
        const start = index;
        while (index < units.len and isAsciiDigitBuiltin(units[index])) : (index += 1) {}
        const end = index;
        // 公式の可変長後読みは、ドット直後の数字run全体を除外する。
        if (start > 0 and units[start - 1] == '.') {
            try output.appendSlice(runtime.allocator, units[start..end]);
            continue;
        }
        var group = (end - start) % 3;
        if (group == 0) group = 3;
        var cursor = start;
        while (cursor < end) {
            const next = std.math.add(usize, cursor, @min(end - cursor, group)) catch return error.StringTooLarge;
            try output.appendSlice(runtime.allocator, units[cursor..next]);
            cursor = next;
            if (cursor < end) try output.append(runtime.allocator, ',');
            group = 3;
        }
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn padBuiltin(runtime: *Runtime, value: Value, width_value: Value, fill: u16) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const original_number = switch (@as(Tag, @enumFromInt(width_value.tag))) {
        .bigint => width_value.object().?.payload.bigint.toF64(),
        else => try valueToNumberRuntime(runtime, width_value),
    };
    const parsed = try parseIntBuiltin(runtime, width_value);
    // 公式はparseInt前に `for (i = 0; i < A; i++)` で埋め文字を作る。
    // したがってAが数値化不能でも、parseInt後の幅とは別に1文字が残る。
    const fill_count = if (std.math.isNan(original_number) or original_number <= 0) @as(usize, 1) else blk: {
        // 正のInfinityでは公式のループが終了しないため、AOTでは安全に拒否する。
        // 実際の割当失敗とは別の境界として呼び出し側へ伝える。
        if (!std.math.isFinite(original_number)) return error.StringPadWidthUnbounded;
        if (original_number >= @as(f64, @floatFromInt(std.math.maxInt(usize) - 1))) return error.OutOfMemory;
        const iterations: usize = @intFromFloat(@ceil(original_number));
        break :blk iterations + 1;
    };
    if (std.math.isNan(parsed)) {
        const source_len = std.math.add(usize, fill_count, units.len) catch return error.OutOfMemory;
        const output = try runtime.allocator.alloc(u16, source_len);
        errdefer runtime.allocator.free(output);
        @memset(output[0..fill_count], fill);
        @memcpy(output[fill_count..], units);
        return runtime.ownString(output);
    }
    const requested: usize = if (parsed <= 0) 0 else blk: {
        if (!std.math.isFinite(parsed) or parsed >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.OutOfMemory;
        break :blk @intFromFloat(@trunc(parsed));
    };
    const target = @max(units.len, requested);
    const source_len = std.math.add(usize, fill_count, units.len) catch return error.OutOfMemory;
    const result_len = @min(target, source_len);
    const output = try runtime.allocator.alloc(u16, result_len);
    errdefer runtime.allocator.free(output);
    const result_fill_count = result_len - units.len;
    @memset(output[0..result_fill_count], fill);
    @memcpy(output[result_fill_count..], units);
    return runtime.ownString(output);
}

pub fn stringPredicateBuiltin(runtime: *Runtime, value: Value, command: aot_builtin.Command) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const first = if (units.len == 0) 0 else units[0];
    const result = switch (command) {
        .hiragana_predicate => first >= 0x3041 and first <= 0x309f,
        .katakana_predicate => first >= 0x30a1 and first <= 0x30fa,
        .digit_predicate => isSequenceDigitBuiltin(first),
        .number_sequence_predicate => if (isString(value) and units.len == 0) false else numberSequenceBuiltin(units),
        else => unreachable,
    };
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(result) };
}

pub fn numberSequenceBuiltin(units: []const u16) bool {
    var index: usize = 0;
    if (index < units.len and isSequenceSignBuiltin(units[index])) index += 1;
    while (index < units.len and isSequenceDigitBuiltin(units[index])) : (index += 1) {}
    if (index < units.len and (units[index] == '.' or units[index] == 0xff0e)) {
        index += 1;
        const fraction_start = index;
        while (index < units.len and isSequenceDigitBuiltin(units[index])) : (index += 1) {}
        if (index == fraction_start) return false;
        if (index < units.len and (units[index] == 'e' or units[index] == 'E' or units[index] == 0xff45 or units[index] == 0xff25)) {
            index += 1;
            if (index < units.len and isSequenceSignBuiltin(units[index])) index += 1;
            const exponent_start = index;
            while (index < units.len and isSequenceDigitBuiltin(units[index])) : (index += 1) {}
            if (index == exponent_start) return false;
        }
    }
    // 公式正規表現は空文字列だけを別扱いにし、符号単独も受理する。
    return index == units.len;
}

pub fn isAsciiDigitBuiltin(unit: u16) bool {
    return unit >= '0' and unit <= '9';
}

pub fn isSequenceDigitBuiltin(unit: u16) bool {
    return isAsciiDigitBuiltin(unit) or (unit >= 0xff10 and unit <= 0xff19);
}

pub fn isSequenceSignBuiltin(unit: u16) bool {
    return unit == '+' or unit == '-' or unit == 0xff0b or unit == 0xff0d;
}

pub fn kanaMapBuiltin(runtime: *Runtime, value: Value, to_full: bool) !Value {
    var roots = [_]Value{ value, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    var allocated_source: ?[]u16 = null;
    defer if (allocated_source) |source| runtime.allocator.free(source);
    const source: []const u16 = blk: {
        if (isString(roots[0])) {
            allocated_source = try valueUtf16Alloc(runtime, roots[0]);
            break :blk allocated_source.?;
        }
        if (@as(Tag, @enumFromInt(roots[0].tag)) == .dictionary) {
            if (!to_full) return kanaMapDictionaryHalfWidthBuiltin(runtime, roots[0], &roots);
            const length = dictionaryProperty(roots[0], &.{ 'l', 'e', 'n', 'g', 't', 'h' });
            // `0 < s.length` uses JavaScript's abstract relational
            // comparison. Undefined/NaN therefore takes the empty path.
            if (try compareValues(runtime, .less, numberValue(0), length)) return kanaMapDictionaryFullWidthBuiltin(runtime, roots[0], length, &roots);
            break :blk &.{};
        }
        if (!to_full) switch (@as(Tag, @enumFromInt(roots[0].tag))) {
            .null_value => return error.KatakanaHalfWidthSplitNull,
            .undefined => return error.KatakanaHalfWidthSplitUndefined,
            else => return error.KatakanaHalfWidthSplitReceiver,
        };

        switch (@as(Tag, @enumFromInt(roots[0].tag))) {
            .null_value => return error.KatakanaFullWidthLengthNull,
            .undefined => return error.KatakanaFullWidthLengthUndefined,
            .array => {
                if (roots[0].object().?.payload.array.items.len > 0) return error.KatakanaFullWidthSubstringReceiver;
                break :blk &.{};
            },
            .byte_buffer => {
                const buffer = roots[0].object().?.payload.byte_buffer;
                if (buffer.kind != .array_buffer and buffer.bytes.len > 0) return error.KatakanaFullWidthSubstringReceiver;
                break :blk &.{};
            },
            .function => break :blk &.{},
            else => break :blk &.{},
        }
    };
    const full_utf8 = system_constant.lookupString("全角カナ一覧").?;
    const full_voiced_utf8 = system_constant.lookupString("全角カナ濁音一覧").?;
    const half_utf8 = system_constant.lookupString("半角カナ一覧").?;
    const half_voiced_utf8 = system_constant.lookupString("半角カナ濁音一覧").?;
    const full = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_utf8);
    defer runtime.allocator.free(full);
    const half = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_utf8);
    defer runtime.allocator.free(half);
    const full_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_voiced_utf8);
    defer runtime.allocator.free(full_voiced);
    const half_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_voiced_utf8);
    defer runtime.allocator.free(half_voiced);

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    var index: usize = 0;
    while (index < source.len) {
        if (to_full) {
            const candidate_end = @min(source.len, index + 2);
            // The official implementation searches the half-width voiced table
            // with the two-unit candidate. This intentionally also maps a lone
            // dakuten/handakuten to the first matching voiced kana entry.
            if (indexOfUnitsBuiltin(half_voiced, source[index..candidate_end], 0)) |position| {
                try output.append(runtime.allocator, full_voiced[position / 2]);
                index = candidate_end;
                continue;
            }
            if (unitIndexBuiltin(half, source[index])) |half_index| {
                if (half_index < full.len) try output.append(runtime.allocator, full[half_index]);
            } else {
                try output.append(runtime.allocator, source[index]);
            }
        } else if (unitIndexBuiltin(full, source[index])) |full_index| {
            try output.append(runtime.allocator, half[full_index]);
        } else if (unitIndexBuiltin(full_voiced, source[index])) |voiced_index| {
            try output.append(runtime.allocator, half_voiced[voiced_index * 2]);
            try output.append(runtime.allocator, half_voiced[voiced_index * 2 + 1]);
        } else {
            try output.append(runtime.allocator, source[index]);
        }
        index += 1;
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn kanaMapDictionaryFullWidthBuiltin(runtime: *Runtime, source: Value, length: Value, roots: []Value) !Value {
    const length_number = try explicitRangeNumber(runtime, length);
    if (!std.math.isFinite(length_number) or length_number > @as(f64, @floatFromInt(safe_array_element_limit))) return error.ArraySizeLimitExceeded;
    const iterations: usize = @intFromFloat(@ceil(length_number));

    roots[1] = dictionaryProperty(source, &.{ 's', 'u', 'b', 's', 't', 'r', 'i', 'n', 'g' });
    roots[2] = dictionaryProperty(source, &.{ 'c', 'h', 'a', 'r', 'A', 't' });
    if (roots[1].tag != @intFromEnum(Tag.function)) return error.KatakanaFullWidthSubstringReceiver;
    if (roots[2].tag != @intFromEnum(Tag.function)) return error.KatakanaFullWidthCharAtReceiver;

    const full_utf8 = system_constant.lookupString("全角カナ一覧").?;
    const full_voiced_utf8 = system_constant.lookupString("全角カナ濁音一覧").?;
    const half_utf8 = system_constant.lookupString("半角カナ一覧").?;
    const half_voiced_utf8 = system_constant.lookupString("半角カナ濁音一覧").?;
    const full = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_utf8);
    defer runtime.allocator.free(full);
    const half = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_utf8);
    defer runtime.allocator.free(half);
    const full_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_voiced_utf8);
    defer runtime.allocator.free(full_voiced);
    const half_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_voiced_utf8);
    defer runtime.allocator.free(half_voiced);

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    var arguments = [_]Value{ numberValue(0), numberValue(2) };
    roots[3] = arguments[0];
    roots[4] = arguments[1];
    var index: usize = 0;
    while (index < iterations) : (index += 1) {
        arguments[0] = numberValue(@floatFromInt(index));
        arguments[1] = numberValue(@floatFromInt(index + 2));
        roots[3] = arguments[0];
        roots[4] = arguments[1];
        roots[5] = try invokeAotCallback(runtime, roots[1], &arguments, arguments.len);
        const candidate = try valueUtf16Alloc(runtime, roots[5]);
        defer runtime.allocator.free(candidate);
        if (indexOfUnitsBuiltin(half_voiced, candidate, 0)) |position| {
            try output.append(runtime.allocator, full_voiced[position / 2]);
            index += 1;
            continue;
        }

        arguments[0] = numberValue(@floatFromInt(index));
        roots[3] = arguments[0];
        roots[5] = try invokeAotCallback(runtime, roots[2], arguments[0..1].ptr, 1);
        const character = try valueUtf16Alloc(runtime, roots[5]);
        defer runtime.allocator.free(character);
        if (indexOfUnitsBuiltin(half, character, 0)) |position| {
            if (position < full.len) try output.append(runtime.allocator, full[position]);
        } else try output.appendSlice(runtime.allocator, character);
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn kanaMapDictionaryHalfWidthBuiltin(runtime: *Runtime, source: Value, roots: []Value) !Value {
    roots[1] = dictionaryProperty(source, &.{ 's', 'p', 'l', 'i', 't' });
    if (roots[1].tag != @intFromEnum(Tag.function)) return error.KatakanaHalfWidthSplitReceiver;
    roots[2] = try invokeAotCallback(runtime, roots[1], @ptrCast(&[_]Value{staticStringValue("")}), 1);
    if (roots[2].tag != @intFromEnum(Tag.array)) return error.KatakanaHalfWidthMapReceiver;

    const full_utf8 = system_constant.lookupString("全角カナ一覧").?;
    const full_voiced_utf8 = system_constant.lookupString("全角カナ濁音一覧").?;
    const half_utf8 = system_constant.lookupString("半角カナ一覧").?;
    const half_voiced_utf8 = system_constant.lookupString("半角カナ濁音一覧").?;
    const full = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_utf8);
    defer runtime.allocator.free(full);
    const half = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_utf8);
    defer runtime.allocator.free(half);
    const full_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_voiced_utf8);
    defer runtime.allocator.free(full_voiced);
    const half_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_voiced_utf8);
    defer runtime.allocator.free(half_voiced);

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    const items = &roots[2].object().?.payload.array;
    for (items.items, 0..) |value, index| {
        if (!runtime.aotArrayIsPresent(roots[2].object().?, index)) continue;
        roots[3] = value;
        const character = try valueUtf16Alloc(runtime, roots[3]);
        defer runtime.allocator.free(character);
        if (indexOfUnitsBuiltin(full, character, 0)) |position| {
            if (position < half.len) try output.append(runtime.allocator, half[position]);
        } else if (indexOfUnitsBuiltin(full_voiced, character, 0)) |position| {
            const start = position * 2;
            if (start + 2 <= half_voiced.len) try output.appendSlice(runtime.allocator, half_voiced[start .. start + 2]);
        } else if (roots[3].tag != @intFromEnum(Tag.undefined) and roots[3].tag != @intFromEnum(Tag.null_value)) {
            try output.appendSlice(runtime.allocator, character);
        }
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn unitIndexBuiltin(units: []const u16, needle: u16) ?usize {
    for (units, 0..) |unit, index| if (unit == needle) return index;
    return null;
}

pub fn indexOfUnitsBuiltin(haystack: []const u16, needle: []const u16, start: usize) ?usize {
    if (needle.len == 0) return @min(start, haystack.len);
    if (start > haystack.len or needle.len > haystack.len - start) return null;
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.mem.eql(u16, haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

pub fn replaceBuiltin(runtime: *Runtime, source_value: Value, needle_value: Value, replacement_value: Value, all: bool) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    // split(undefined) returns the source as its sole element, so join never
    // observes the replacement separator. replace(undefined, ...) still
    // searches for the literal string "undefined" and must use the path below.
    if (all and needle_value.tag == @intFromEnum(Tag.undefined)) return runtime.createString(source);
    const needle = try valueUtf16Alloc(runtime, needle_value);
    defer runtime.allocator.free(needle);
    var allocated_replacement: ?[]u16 = null;
    const replacement: []const u16 = if (all and replacement_value.tag == @intFromEnum(Tag.undefined))
        // Array.prototype.join(undefined) uses its default comma separator.
        &.{','}
    else blk: {
        allocated_replacement = try valueUtf16Alloc(runtime, replacement_value);
        break :blk allocated_replacement.?;
    };
    defer if (allocated_replacement) |allocated| runtime.allocator.free(allocated);
    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    if (!all) {
        const found = std.mem.indexOf(u16, source, needle) orelse return runtime.createString(source);
        try output.appendSlice(runtime.allocator, source[0..found]);
        try appendFirstReplacementBuiltin(runtime, &output, source, found, found + needle.len, replacement);
        try output.appendSlice(runtime.allocator, source[found + needle.len ..]);
        return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
    }
    if (needle.len == 0) {
        for (source, 0..) |unit, index| {
            if (index > 0) try output.appendSlice(runtime.allocator, replacement);
            try output.append(runtime.allocator, unit);
        }
        return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
    }
    var start: usize = 0;
    while (std.mem.indexOfPos(u16, source, start, needle)) |found| {
        try output.appendSlice(runtime.allocator, source[start..found]);
        try output.appendSlice(runtime.allocator, replacement);
        start = found + needle.len;
    }
    try output.appendSlice(runtime.allocator, source[start..]);
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn appendFirstReplacementBuiltin(runtime: *Runtime, output: *std.ArrayList(u16), source: []const u16, match_start: usize, match_end: usize, replacement: []const u16) !void {
    var index: usize = 0;
    while (index < replacement.len) {
        if (replacement[index] != '$' or index + 1 >= replacement.len) {
            try output.append(runtime.allocator, replacement[index]);
            index += 1;
            continue;
        }
        switch (replacement[index + 1]) {
            '$' => try output.append(runtime.allocator, '$'),
            '&' => try output.appendSlice(runtime.allocator, source[match_start..match_end]),
            '`' => try output.appendSlice(runtime.allocator, source[0..match_start]),
            '\'' => try output.appendSlice(runtime.allocator, source[match_end..]),
            else => {
                try output.append(runtime.allocator, '$');
                index += 1;
                continue;
            },
        }
        index += 2;
    }
}

pub fn testAotFunction(out: *Value, _: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    out.* = if (arguments == null or len != 1) .{} else arguments.?[0];
}

pub fn testAotCustomString(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = staticStringValue("CUSTOM");
}

pub fn testAotKanaSubstringVoiced(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = staticStringValue("ｶﾞ");
}

pub fn testAotKanaSubstringPlain(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = staticStringValue("x");
}

pub fn testAotKanaCharAtA(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = staticStringValue("ｱ");
}

pub fn testAotKanaSplit(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const runtime = if (active_runtime) |*active| active else return;
    out.* = runtime.createArray(&.{ staticStringValue("ガ"), staticStringValue("ッ"), staticStringValue("ツ") }) catch |failure| runtimeFailure(failure);
}

pub fn testAotToPrimitiveObject(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const runtime = if (active_runtime) |*active| active else return;
    out.* = runtime.createDictionary(&.{}) catch |failure| runtimeFailure(failure);
}

pub fn testAotTimerStop(out: *Value, _: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    if (arguments != null and len > 0) {
        var ignored = Value{};
        lnako_aot_builtin_call(&ignored, arguments, 1, @intFromEnum(aot_builtin.Command.timer_stop));
    }
    out.* = .{};
}

pub fn testAotConstantSeven(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = numberValue(7);
}

pub fn testAotSecondArgument(out: *Value, _: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    out.* = if (arguments == null or len != 2) .{} else arguments.?[1];
}

pub fn testAotDescending(out: *Value, _: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    out.* = if (arguments == null or len != 2)
        .{}
    else
        numberValue(valueToNumber(arguments.?[1]) - valueToNumber(arguments.?[0]));
}

pub fn testAotSortOrder(out: *Value, context: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    const runtime = if (active_runtime) |*active| active else return;
    if (arguments == null or len != 2) {
        out.* = .{};
        return;
    }
    const function: *Object = @ptrCast(@alignCast(context));
    const log = function.payload.function.captures[0];
    runtime.aotArrayAppend(log.object() orelse return, numberValue(valueToNumber(arguments.?[0]) * 10 + valueToNumber(arguments.?[1]))) catch |failure| runtimeFailure(failure);
    out.* = numberValue(valueToNumber(arguments.?[0]) - valueToNumber(arguments.?[1]));
}

pub fn testAotDouble(out: *Value, _: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    out.* = if (arguments == null or len != 1) .{} else numberValue(valueToNumber(arguments.?[0]) * 2);
}

pub fn testAotEven(out: *Value, _: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    out.* = if (arguments == null or len != 1)
        .{}
    else
        .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(@mod(valueToNumber(arguments.?[0]), 2) == 0) };
}

pub fn testAotCapturedIncrement(out: *Value, context: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const function: *Object = @ptrCast(@alignCast(context));
    const cell = function.payload.function.captures[0].object().?;
    const next = numberValue(valueToNumber(cell.payload.binding_cell) + 1);
    cell.payload.binding_cell = next;
    out.* = next;
}

pub fn testAotFileProgressStop(out: *Value, context: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    const function: *Object = @ptrCast(@alignCast(context));
    const cell = function.payload.function.captures[0].object().?;
    if (arguments != null and len == 1) {
        const current = valueToNumber(dictionaryProperty(arguments.?[0], &.{ '現', '在' }));
        cell.payload.binding_cell = numberValue(current);
        if (current == 1) {
            var ignored = Value{};
            lnako_aot_builtin_call(&ignored, null, 0, @intFromEnum(aot_builtin.Command.node_file_process_stop));
        }
    }
    out.* = .{};
}

pub fn expectAotNodePathArgumentFailure(runtime: *Runtime, label: []const u8, value: Value, expected: []const u8) !void {
    _ = nodePathArgument(runtime, label, value) catch |failure| {
        try std.testing.expectEqual(error.InvalidPathSource, failure);
        try std.testing.expect(runtime.has_pending_exception);
        try expectUtf16String(runtime, runtime.pending_exception, expected);
        _ = runtime.takeException();
        return;
    };
    return error.ExpectedFailure;
}

pub fn codePointFindAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    const source = try runtime.createArray(&.{ staticStringValue("A"), staticStringValue("😀"), staticStringValue("B") });
    const needle = try runtime.createArray(&.{staticStringValue("😀")});
    const result = try codePointFindBuiltin(&runtime, source, needle);
    try std.testing.expectEqual(@as(usize, 2), result);
    const string_source = try runtime.createString(&.{ 'A', 0xd83d, 0xde00, 'B' });
    const string_needle = try runtime.createString(&.{ 0xd83d, 0xde00, 'B' });
    const string_result = try codePointFindBuiltin(&runtime, string_source, string_needle);
    try std.testing.expectEqual(@as(usize, 2), string_result);
}

pub fn referenceAotArrayStringKeyAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 2;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createArray(&.{ numberValue(1), numberValue(2) });
    roots[1] = try runtime.createString(&.{ 'l', 'e', 'n', 'g', 't', 'h' });
    const result = try referenceBuiltin(&runtime, roots[0], roots[1]);
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(result));
}

pub fn aotBigintRangeAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 7;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{ numberValue(0), numberValue(1), numberValue(2) });
    roots[1] = try runtime.createBigInt("1n");
    roots[2] = try runtime.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[1] });
    runtime.next_collection = runtime.object_count;
    roots[3] = try arrayRangeCopyBuiltin(&runtime, roots[0], roots[2]);
    try std.testing.expectEqual(@as(usize, 2), roots[3].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(try referenceBuiltin(&runtime, roots[0], roots[1])));
    roots[4] = try runtime.createString(&.{ 'A', 'B', 'C' });
    roots[5] = try runtime.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[1] });
    runtime.next_collection = runtime.object_count;
    roots[6] = try referenceBuiltin(&runtime, roots[4], roots[5]);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'B' }, roots[6].object().?.payload.utf16_string);
}

pub fn expectAotReferenceStringRangeMessage(runtime: *Runtime, index: Value, expected: []const u8) !void {
    _ = referenceBuiltin(runtime, staticStringValue("ABC"), index) catch |failure| {
        try std.testing.expectEqual(error.InvalidStringRange, failure);
        const message = runtime.takeException();
        const actual = try valueUtf16Alloc(runtime, message);
        defer runtime.allocator.free(actual);
        const expected_units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, expected);
        defer runtime.allocator.free(expected_units);
        try std.testing.expectEqualSlices(u16, expected_units, actual);
        return;
    };
    try std.testing.expect(false);
}

pub fn aotWidthAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 4;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createString(&.{ 'A', 0x20, 0xff76, 0xff9e });
    roots[2] = try runtime.createArray(&.{numberValue(1)});
    roots[3] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(1) });
    runtime.next_collection = 1;

    roots[1] = try asciiWidthBuiltin(&runtime, roots[0], true, false);
    runtime.next_collection = 1;
    roots[1] = try asciiWidthBuiltin(&runtime, roots[0], false, false);
    runtime.next_collection = 1;
    roots[1] = try asciiWidthBuiltin(&runtime, roots[0], true, true);
    runtime.next_collection = 1;
    roots[1] = try asciiWidthBuiltin(&runtime, roots[0], false, true);
    runtime.next_collection = 1;
    roots[1] = try kanaMapBuiltin(&runtime, roots[0], true);
    runtime.next_collection = 1;
    roots[1] = try kanaMapBuiltin(&runtime, roots[0], false);
    runtime.next_collection = 1;
    roots[1] = try widthBuiltin(&runtime, roots[0], true);
    runtime.next_collection = 1;
    roots[1] = try widthBuiltin(&runtime, roots[0], false);
    try std.testing.expectError(error.KatakanaFullWidthSubstringReceiver, kanaMapBuiltin(&runtime, roots[2], true));
    try std.testing.expectError(error.KatakanaFullWidthSubstringReceiver, kanaMapBuiltin(&runtime, roots[3], true));
    try std.testing.expectError(error.KatakanaHalfWidthSplitReceiver, kanaMapBuiltin(&runtime, numberValue(1), false));
}

pub fn aotDictionaryPropertyKeyAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    var roots = [_]Value{ try runtime.createBigInt("1n"), .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    runtime.next_collection = runtime.object_count;
    roots[1] = try runtime.createDictionary(&.{ roots[0], numberValue(1), staticStringValue("1"), numberValue(2), numberValue(2), numberValue(3), staticStringValue("2"), numberValue(4) });
    const entries = roots[1].object().?.payload.dictionary.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(entries[0].value));
    try std.testing.expectEqual(@as(f64, 4), valueToNumber(entries[1].value));
    roots[2] = try dictionaryKeysBuiltin(&runtime, roots[1]);
    try std.testing.expectEqualSlices(u16, &.{'1'}, roots[2].object().?.payload.array.items[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'2'}, roots[2].object().?.payload.array.items[1].object().?.payload.utf16_string);
}

pub fn aotDictionaryBigIntPropertyKeyAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 3;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createBigInt("1n");
    roots[1] = try runtime.createBigInt("2n");
    runtime.next_collection = runtime.object_count;
    roots[2] = try runtime.createDictionary(&.{ roots[0], numberValue(1), staticStringValue("1"), numberValue(2), roots[1], numberValue(3), staticStringValue("2"), numberValue(4) });
    const entries = roots[2].object().?.payload.dictionary.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(entries[0].value));
    try std.testing.expectEqual(@as(f64, 4), valueToNumber(entries[1].value));
}

pub fn numberValue(number: f64) Value {
    return .{ .tag = @intFromEnum(Tag.number), .payload = @bitCast(number) };
}

pub fn staticStringValue(comptime text: [:0]const u8) Value {
    return .{ .tag = @intFromEnum(Tag.static_utf8_string), .payload = @intFromPtr(text.ptr) };
}

const values_module = @import("values.zig");
const instructions_module = @import("instructions.zig");
const functions_module = @import("functions.zig");

pub const lnako_aot_string_new = values_module.lnako_aot_string_new;
pub const lnako_aot_print_utf16 = values_module.lnako_aot_print_utf16;
pub const lnako_aot_print_number = values_module.lnako_aot_print_number;
pub const lnako_aot_bigint_new = values_module.lnako_aot_bigint_new;
pub const lnako_aot_print_bigint = values_module.lnako_aot_print_bigint;
pub const lnako_aot_print_collection = values_module.lnako_aot_print_collection;
pub const lnako_aot_display_value = values_module.lnako_aot_display_value;
pub const lnako_aot_array_new = values_module.lnako_aot_array_new;
pub const lnako_aot_dictionary_new = values_module.lnako_aot_dictionary_new;
pub const lnako_aot_caniuse_agents_new = values_module.lnako_aot_caniuse_agents_new;
pub const lnako_aot_era_data_new = values_module.lnako_aot_era_data_new;

pub const lnako_aot_bigint_truthy = instructions_module.lnako_aot_bigint_truthy;
pub const lnako_aot_arithmetic = instructions_module.lnako_aot_arithmetic;
pub const lnako_aot_compare = instructions_module.lnako_aot_compare;
pub const lnako_aot_shift = instructions_module.lnako_aot_shift;
pub const lnako_aot_concat = instructions_module.lnako_aot_concat;
pub const lnako_aot_increment = instructions_module.lnako_aot_increment;
pub const lnako_aot_index_get = instructions_module.lnako_aot_index_get;
pub const lnako_aot_index_set = instructions_module.lnako_aot_index_set;
pub const lnako_aot_destructure_get = instructions_module.lnako_aot_destructure_get;
pub const lnako_aot_iterator_new = instructions_module.lnako_aot_iterator_new;
pub const lnako_aot_iterator_has_next = instructions_module.lnako_aot_iterator_has_next;
pub const lnako_aot_iterator_next = instructions_module.lnako_aot_iterator_next;
pub const lnako_aot_binding_cell_new = instructions_module.lnako_aot_binding_cell_new;
pub const lnako_aot_binding_cell_value = instructions_module.lnako_aot_binding_cell_value;
pub const lnako_aot_cut = instructions_module.lnako_aot_cut;
pub const lnako_aot_cut_site = instructions_module.lnako_aot_cut_site;

pub const lnako_aot_native_plugin_register = functions_module.lnako_aot_native_plugin_register;
pub const lnako_aot_dynamic_global_register = functions_module.lnako_aot_dynamic_global_register;
pub const lnako_aot_dynamic_call = functions_module.lnako_aot_dynamic_call;
pub const lnako_aot_native_plugin_call = functions_module.lnako_aot_native_plugin_call;
pub const lnako_aot_function_new = functions_module.lnako_aot_function_new;
pub const lnako_aot_function_new_named = functions_module.lnako_aot_function_new_named;
pub const lnako_aot_function_capture = functions_module.lnako_aot_function_capture;
pub const lnako_aot_function_call = functions_module.lnako_aot_function_call;
