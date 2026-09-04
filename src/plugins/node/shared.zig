const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../../runtime/value.zig");
const common = @import("../system/common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const FileKind = enum { file, directory, other };
pub const FileStat = struct {
    kind: FileKind,
    size: u64,
    inode: f64 = 0,
    links: f64 = 0,
    block_size: f64 = 1,
    modified_nanoseconds: i128 = 0,
    changed_nanoseconds: i128 = 0,
    accessed_nanoseconds: ?i128 = null,
};
pub const FileEntry = struct { name: []u8, kind: FileKind };
pub const ArchiveOperation = enum { compress, extract };
pub const FileOperation = enum { copy, move, delete };
pub const HttpHeader = struct { name: []const u8, value: []const u8 };
pub const HttpRequest = struct {
    method: []const u8,
    url: []const u8,
    headers: []const HttpHeader = &.{},
    body: []const u8 = &.{},
    has_body: bool = false,
};
pub const NetworkAddresses = struct {
    items: [][]u8,

    pub fn deinit(self: *NetworkAddresses, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    http_status: ?u16 = null,

    pub fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const State = struct {
    stdin_bytes: ?[]u8 = null,
    stdin_offset: usize = 0,
    requested_exit_code: ?u8 = null,
    file_process_callback: Value = .undefined,
    file_process_stop: bool = false,
    interrupt_callback: Value = .undefined,
    archive_tool_path: ?[]u8 = null,
    pending_operations: std.ArrayList(PendingOperation) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.stdin_bytes) |bytes| allocator.free(bytes);
        if (self.archive_tool_path) |path| allocator.free(path);
        self.pending_operations.deinit(allocator);
        self.* = undefined;
    }

    pub fn trace(self: State, runtime: *Runtime) !void {
        try runtime.traceExternal(self.file_process_callback);
        try runtime.traceExternal(self.interrupt_callback);
        for (self.pending_operations.items) |pending| {
            try runtime.traceExternal(pending.callback);
            try runtime.traceExternal(pending.promise);
        }
    }
};

pub const HttpResultKind = enum { response, text, json, binary, none };
pub const PendingMode = enum { command_output, output_callback, no_argument_callback, http_callback, http_set_target, http_promise };
pub const PendingOperation = struct {
    token: u64,
    mode: PendingMode,
    callback: Value = .undefined,
    promise: Value = .undefined,
    http_result: HttpResultKind = .text,
    require_success: bool = false,
};

pub const Effects = struct {
    context: *anyopaque,
    invokeFn: *const fn (context: *anyopaque, callable: Value, arguments: []const Value) anyerror!Value,
    resolveFn: *const fn (context: *anyopaque, value: Value) anyerror!Value,
    getGlobalFn: *const fn (context: *anyopaque, name: []const u8) ?Value,
    setGlobalFn: *const fn (context: *anyopaque, name: []const u8, value: Value) anyerror!void,

    pub fn invoke(self: Effects, callable: Value, arguments: []const Value) !Value {
        return self.invokeFn(self.context, callable, arguments);
    }

    pub fn resolve(self: Effects, value: Value) !Value {
        return self.resolveFn(self.context, value);
    }

    pub fn getGlobal(self: Effects, name: []const u8) ?Value {
        return self.getGlobalFn(self.context, name);
    }

    pub fn setGlobal(self: Effects, name: []const u8, value: Value) !void {
        try self.setGlobalFn(self.context, name, value);
    }
};

pub const Context = struct {
    context: *anyopaque,
    cwdFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
    chdirFn: ?*const fn (context: *anyopaque, path: []const u8) anyerror!void = null,
    program_arguments: []const []const u8 = &.{},
    runtime_path: []const u8 = "lnako",
    source_path: []const u8 = ".",
    environment_names: []const []const u8 = &.{},
    environment_values: []const []const u8 = &.{},
    home_directory: ?[]const u8 = null,
    temporary_directory: []const u8 = "/tmp",
    readFileFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 = null,
    writeFileFn: ?*const fn (context: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void = null,
    statFileFn: ?*const fn (context: *anyopaque, path: []const u8) anyerror!FileStat = null,
    createDirectoryFn: ?*const fn (context: *anyopaque, path: []const u8) anyerror!void = null,
    deletePathFn: ?*const fn (context: *anyopaque, path: []const u8) anyerror!void = null,
    copyPathFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, source: []const u8, destination: []const u8, overwrite: bool) anyerror!void = null,
    movePathFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, source: []const u8, destination: []const u8, overwrite: bool) anyerror!void = null,
    listDirectoryFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8, recursive: bool) anyerror![]FileEntry = null,
    runCommandFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, command: []const u8) anyerror!CommandResult = null,
    startCommandFn: ?*const fn (context: *anyopaque, command: []const u8) anyerror!u64 = null,
    startFileOperationFn: ?*const fn (context: *anyopaque, operation: FileOperation, source: []const u8, destination: ?[]const u8, overwrite: bool) anyerror!u64 = null,
    startArchiveFn: ?*const fn (context: *anyopaque, operation: ArchiveOperation, source: []const u8, destination: []const u8, external_tool: ?[]const u8) anyerror!u64 = null,
    pollOperationFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, token: u64) anyerror!?CommandResult = null,
    readStdinFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 = null,
    createTemporaryDirectoryFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8) anyerror![]u8 = null,
    openExternalFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, target: []const u8, reveal: bool) anyerror!void = null,
    writeStdoutFn: ?*const fn (context: *anyopaque, bytes: []const u8) anyerror!void = null,
    writeStderrFn: ?*const fn (context: *anyopaque, bytes: []const u8) anyerror!void = null,
    archiveFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, operation: ArchiveOperation, source: []const u8, destination: []const u8, external_tool: ?[]const u8) anyerror![]u8 = null,
    installInterruptFn: ?*const fn (context: *anyopaque) anyerror!void = null,
    consumeInterruptFn: ?*const fn (context: *anyopaque) bool = null,
    randomBytesFn: ?*const fn (context: *anyopaque, output: []u8) anyerror!void = null,
    networkAddressesFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, ipv6: bool) anyerror!NetworkAddresses = null,
    httpRequestFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, request: HttpRequest) anyerror!CommandResult = null,
    startHttpFn: ?*const fn (context: *anyopaque, request: HttpRequest) anyerror!u64 = null,

    pub fn cwd(self: Context, allocator: std.mem.Allocator) ![]u8 {
        return self.cwdFn(self.context, allocator);
    }

    pub fn chdir(self: Context, path: []const u8) !void {
        const function = self.chdirFn orelse return error.ChangeDirectoryUnavailable;
        try function(self.context, path);
    }

    pub fn environment(self: Context, name: []const u8) ?[]const u8 {
        for (self.environment_names, self.environment_values) |candidate, value| {
            if (environmentNameEqual(candidate, name)) return value;
        }
        return null;
    }

    pub fn readFile(self: Context, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const function = self.readFileFn orelse return error.FileReadUnavailable;
        return function(self.context, allocator, path);
    }

    pub fn writeFile(self: Context, path: []const u8, bytes: []const u8) !void {
        const function = self.writeFileFn orelse return error.FileWriteUnavailable;
        try function(self.context, path, bytes);
    }

    pub fn statFile(self: Context, path: []const u8) !FileStat {
        const function = self.statFileFn orelse return error.FileStatUnavailable;
        return function(self.context, path);
    }

    pub fn runCommand(self: Context, allocator: std.mem.Allocator, command: []const u8) !CommandResult {
        const function = self.runCommandFn orelse return error.CommandExecutionUnavailable;
        return function(self.context, allocator, command);
    }

    pub fn writeStdout(self: Context, bytes: []const u8) !void {
        const function = self.writeStdoutFn orelse return;
        try function(self.context, bytes);
    }

    pub fn writeStderr(self: Context, bytes: []const u8) !void {
        const function = self.writeStderrFn orelse return;
        try function(self.context, bytes);
    }
};

pub fn environmentNameEqual(left: []const u8, right: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(left, right) else std.mem.eql(u8, left, right);
}

pub fn valueUtf8(runtime: *Runtime, value: Value) ![]u8 {
    const text = try runtime.valueToString(value);
    return text.string.toUtf8Lossy(runtime.allocator());
}

pub fn valueBytes(runtime: *Runtime, value: Value) ![]u8 {
    if (value == .bytes) return runtime.allocator().dupe(u8, value.bytes.bytes);
    return valueUtf8(runtime, value);
}

pub fn isAny(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}

pub fn dictionaryGetAscii(dictionary: *value_mod.Dictionary, name: []const u8) ?Value {
    for (dictionary.keys(), dictionary.values()) |key, value| {
        if (key.units.len != name.len) continue;
        var equal = true;
        for (key.units, name) |unit, byte| if (unit != byte) {
            equal = false;
            break;
        };
        if (equal) return value;
    }
    return null;
}

pub fn setDictionary(runtime: *Runtime, dictionary: *value_mod.Dictionary, key: []const u8, value: Value) !void {
    var rooted_value = value;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_value);
    var key_value = try runtime.stringUtf8(key);
    try roots.protect(&key_value);
    try dictionary.set(key_value.string, rooted_value);
}

pub fn upperAsciiAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, source);
    for (result) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return result;
}

pub fn nodePathArgument(runtime: *Runtime, label: []const u8, value: Value) ![]u8 {
    if (value != .string) {
        const received = try nodePathReceivedType(runtime, value);
        defer runtime.allocator().free(received);
        const message = try std.fmt.allocPrint(
            runtime.allocator(),
            "The \"{s}\" argument must be of type string. Received {s}",
            .{ label, received },
        );
        defer runtime.allocator().free(message);
        try runtime.setFailureMessage(message);
        return error.InvalidPathSource;
    }
    return value.string.toUtf8Lossy(runtime.allocator());
}

pub fn nodePathReceivedType(runtime: *Runtime, value: Value) ![]u8 {
    return switch (value) {
        .undefined => runtime.allocator().dupe(u8, "undefined"),
        .null_value => runtime.allocator().dupe(u8, "null"),
        .boolean => |boolean| std.fmt.allocPrint(runtime.allocator(), "type boolean ({s})", .{if (boolean) "true" else "false"}),
        .number => nodePathPrimitiveReceivedType(runtime, value, "number", false),
        .bigint => nodePathPrimitiveReceivedType(runtime, value, "bigint", true),
        .bytes => |bytes| switch (bytes.kind) {
            .buffer => runtime.allocator().dupe(u8, "an instance of Buffer"),
            .uint8_array => runtime.allocator().dupe(u8, "an instance of Uint8Array"),
            .array_buffer => runtime.allocator().dupe(u8, "an instance of ArrayBuffer"),
        },
        .array => runtime.allocator().dupe(u8, "an instance of Array"),
        .dictionary => runtime.allocator().dupe(u8, "an instance of Object"),
        .function => runtime.allocator().dupe(u8, "function "),
        .promise => runtime.allocator().dupe(u8, "an instance of Promise"),
        .string => unreachable,
    };
}

pub fn nodePathPrimitiveReceivedType(runtime: *Runtime, value: Value, type_name: []const u8, bigint_suffix: bool) ![]u8 {
    var rendered = try runtime.valueToStringDefault(value);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rendered);
    const text = try rendered.string.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(text);
    return std.fmt.allocPrint(
        runtime.allocator(),
        "type {s} ({s}{s})",
        .{ type_name, text, if (bigint_suffix) "n" else "" },
    );
}

pub const NodeChangeDirectoryErrorInfo = struct {
    code: []const u8,
    description: []const u8,
};

pub fn nodeChangeDirectoryErrorInfo(failure: anyerror) ?NodeChangeDirectoryErrorInfo {
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

pub fn nodeFilesystemPath(runtime: *Runtime, value: Value) ![]u8 {
    const text = try runtime.valueToString(value);
    if (comptime builtin.os.tag == .windows) {
        return std.unicode.wtf16LeToWtf8Alloc(runtime.allocator(), text.string.units);
    }
    return text.string.toUtf8Lossy(runtime.allocator());
}

pub fn nodeErrorPath(runtime: *Runtime, path: []const u8) ![]u8 {
    if (comptime builtin.os.tag == .windows) {
        return std.unicode.wtf8ToUtf8LossyAlloc(runtime.allocator(), path);
    }
    return runtime.allocator().dupe(u8, path);
}

pub fn setNodeChangeDirectoryFailure(runtime: *Runtime, context: Context, path: []const u8, failure: anyerror) !void {
    const info = nodeChangeDirectoryErrorInfo(failure) orelse return;
    const cwd_raw = context.cwd(runtime.allocator()) catch return;
    defer runtime.allocator().free(cwd_raw);
    const cwd = try nodeErrorPath(runtime, cwd_raw);
    defer runtime.allocator().free(cwd);
    const display_path = try nodeErrorPath(runtime, path);
    defer runtime.allocator().free(display_path);
    const message = try std.fmt.allocPrint(
        runtime.allocator(),
        "{s}: {s}, chdir '{s}' -> '{s}'",
        .{ info.code, info.description, cwd, display_path },
    );
    defer runtime.allocator().free(message);
    try runtime.setFailureMessage(message);
}

test "Nodeパス命令は非文字列入力をNodeの型診断へ変換する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try expectNodePathArgumentFailure(&runtime, "path", .null_value, "The \"path\" argument must be of type string. Received null");
    try expectNodePathArgumentFailure(&runtime, "path", .{ .number = 123 }, "The \"path\" argument must be of type string. Received type number (123)");

    var dictionary = try runtime.createDictionary();
    var array = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try roots.protect(&array);
    try expectNodePathArgumentFailure(&runtime, "path", dictionary, "The \"path\" argument must be of type string. Received an instance of Object");
    try expectNodePathArgumentFailure(&runtime, "path", array, "The \"path\" argument must be of type string. Received an instance of Array");
}

fn expectNodePathArgumentFailure(runtime: *Runtime, label: []const u8, value: Value, expected: []const u8) !void {
    _ = nodePathArgument(runtime, label, value) catch |failure| {
        try std.testing.expectEqual(error.InvalidPathSource, failure);
        try std.testing.expectEqualStrings(expected, runtime.failureMessage().?);
        runtime.clearFailureMessage();
        return;
    };
    return error.ExpectedFailure;
}
