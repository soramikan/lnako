const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../runtime/value.zig");
const constants = @import("system/constants.zig");
const common = @import("system/common.zig");
const regexp = @import("system/regexp.zig");
const encoding = @import("encoding.zig");
const crypto = @import("crypto.zig");
const json = @import("system/json.zig");

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

const HttpResultKind = enum { response, text, json, binary, none };
const PendingMode = enum { command_output, output_callback, no_argument_callback, http_callback, http_set_target, http_promise };
const PendingOperation = struct {
    token: usize,
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

    fn invoke(self: Effects, callable: Value, arguments: []const Value) !Value {
        return self.invokeFn(self.context, callable, arguments);
    }

    fn resolve(self: Effects, value: Value) !Value {
        return self.resolveFn(self.context, value);
    }

    fn getGlobal(self: Effects, name: []const u8) ?Value {
        return self.getGlobalFn(self.context, name);
    }

    fn setGlobal(self: Effects, name: []const u8, value: Value) !void {
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
    startCommandFn: ?*const fn (context: *anyopaque, command: []const u8) anyerror!usize = null,
    startFileOperationFn: ?*const fn (context: *anyopaque, operation: FileOperation, source: []const u8, destination: ?[]const u8, overwrite: bool) anyerror!usize = null,
    startArchiveFn: ?*const fn (context: *anyopaque, operation: ArchiveOperation, source: []const u8, destination: []const u8, external_tool: ?[]const u8) anyerror!usize = null,
    pollOperationFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, token: usize) anyerror!?CommandResult = null,
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
    startHttpFn: ?*const fn (context: *anyopaque, request: HttpRequest) anyerror!usize = null,

    fn cwd(self: Context, allocator: std.mem.Allocator) ![]u8 {
        return self.cwdFn(self.context, allocator);
    }

    fn chdir(self: Context, path: []const u8) !void {
        const function = self.chdirFn orelse return error.ChangeDirectoryUnavailable;
        try function(self.context, path);
    }

    fn environment(self: Context, name: []const u8) ?[]const u8 {
        for (self.environment_names, self.environment_values) |candidate, value| {
            if (environmentNameEqual(candidate, name)) return value;
        }
        return null;
    }

    fn readFile(self: Context, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const function = self.readFileFn orelse return error.FileReadUnavailable;
        return function(self.context, allocator, path);
    }

    fn writeFile(self: Context, path: []const u8, bytes: []const u8) !void {
        const function = self.writeFileFn orelse return error.FileWriteUnavailable;
        try function(self.context, path, bytes);
    }

    fn statFile(self: Context, path: []const u8) !FileStat {
        const function = self.statFileFn orelse return error.FileStatUnavailable;
        return function(self.context, path);
    }

    fn runCommand(self: Context, allocator: std.mem.Allocator, command: []const u8) !CommandResult {
        const function = self.runCommandFn orelse return error.CommandExecutionUnavailable;
        return function(self.context, allocator, command);
    }

    fn writeStdout(self: Context, bytes: []const u8) !void {
        const function = self.writeStdoutFn orelse return;
        try function(self.context, bytes);
    }

    fn writeStderr(self: Context, bytes: []const u8) !void {
        const function = self.writeStderrFn orelse return;
        try function(self.context, bytes);
    }
};

pub fn install(runtime: *Runtime, context: Context, installer: constants.Installer) !void {
    var arguments = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&arguments);
    for (context.program_arguments) |argument| _ = try arguments.array.push(try runtime.stringUtf8(argument));
    try installer.set("コマンドライン", arguments);
    try installer.set("ナデシコランタイムパス", try runtime.stringUtf8(context.runtime_path));
    try installer.set("ナデシコランタイム", try runtime.stringUtf8(nodeBasename(context.runtime_path)));
    const absolute_source = try absolutePath(runtime.allocator(), context, context.source_path);
    defer runtime.allocator().free(absolute_source);
    try installer.set("母艦パス", try runtime.stringUtf8(nodeDirname(absolute_source)));
    try installer.set("圧縮解凍ツールパス", try runtime.stringUtf8("7z"));
    try installer.set("ファイルコピーデフォルト動作", try runtime.stringUtf8("上書禁止"));
    try installer.set("AJAXオプション", try runtime.stringUtf8(""));
    try installer.set("AJAX:ONERROR", .null_value);
    if (context.home_directory) |home| {
        const desktop = try std.fs.path.join(runtime.allocator(), &.{ home, "Desktop" });
        defer runtime.allocator().free(desktop);
        try installer.set("デスクトップ", try runtime.stringUtf8(desktop));
        const documents = try std.fs.path.join(runtime.allocator(), &.{ home, "Documents" });
        defer runtime.allocator().free(documents);
        try installer.set("マイドキュメント", try runtime.stringUtf8(documents));
    } else {
        try installer.set("デスクトップ", .undefined);
        try installer.set("マイドキュメント", .undefined);
    }
    try installer.set("テンポラリフォルダ", try runtime.stringUtf8(context.temporary_directory));
}

pub fn call(runtime: *Runtime, state: *State, context: Context, effects: ?Effects, name: []const u8, arguments: []const Value) !?Value {
    const crypto_context: ?crypto.Context = if (context.randomBytesFn) |function| .{ .context = context.context, .randomBytesFn = function } else null;
    if (try crypto.call(runtime, crypto_context, name, arguments)) |value| return value;
    if (try callHttp(runtime, state, context, effects, name, arguments)) |value| return value;
    if (std.mem.eql(u8, name, "自分IPアドレス取得") or std.mem.eql(u8, name, "自分IPV6アドレス取得")) {
        const function = context.networkAddressesFn orelse return error.NetworkInterfacesUnavailable;
        var addresses = try function(context.context, runtime.allocator(), std.mem.eql(u8, name, "自分IPV6アドレス取得"));
        defer addresses.deinit(runtime.allocator());
        var result = try runtime.createArray();
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        for (addresses.items) |address| _ = try result.array.push(try runtime.stringUtf8(address));
        return @as(?Value, result);
    }
    const source = common.argument(arguments, 0);
    if (std.mem.eql(u8, name, "SJISファイル読") or std.mem.eql(u8, name, "EUCファイル読")) {
        const path = try valueUtf8(runtime, source);
        defer runtime.allocator().free(path);
        const bytes = try context.readFile(runtime.allocator(), path);
        defer runtime.allocator().free(bytes);
        var byte_value = try runtime.createBytes(bytes);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&byte_value);
        return @as(?Value, try encoding.decode(runtime, byte_value, if (std.mem.eql(u8, name, "SJISファイル読")) "shift_jis" else "euc-jp"));
    }
    if (std.mem.eql(u8, name, "SJISファイル保存") or std.mem.eql(u8, name, "EUCファイル保存")) {
        const path = try valueUtf8(runtime, common.argument(arguments, 1));
        defer runtime.allocator().free(path);
        var encoded = try encoding.encode(runtime, source, if (std.mem.eql(u8, name, "SJISファイル保存")) "shift_jis" else "euc-jp");
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&encoded);
        try context.writeFile(path, encoded.bytes.bytes);
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "開") or std.mem.eql(u8, name, "読") or std.mem.eql(u8, name, "バイナリ読")) {
        const path = try valueUtf8(runtime, source);
        defer runtime.allocator().free(path);
        const bytes = try context.readFile(runtime.allocator(), path);
        defer runtime.allocator().free(bytes);
        return @as(?Value, if (std.mem.eql(u8, name, "バイナリ読")) try runtime.createBytes(bytes) else try runtime.stringUtf8Lossy(bytes));
    }
    if (std.mem.eql(u8, name, "保存")) {
        const path = try valueUtf8(runtime, common.argument(arguments, 1));
        defer runtime.allocator().free(path);
        if (source == .bytes) {
            try context.writeFile(path, source.bytes.bytes);
        } else {
            const bytes = try valueUtf8(runtime, source);
            defer runtime.allocator().free(bytes);
            try context.writeFile(path, bytes);
        }
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "存在") or std.mem.eql(u8, name, "フォルダ存在")) {
        const path = try valueUtf8(runtime, source);
        defer runtime.allocator().free(path);
        const stat = context.statFile(path) catch return @as(?Value, .{ .boolean = false });
        return @as(?Value, .{ .boolean = if (std.mem.eql(u8, name, "フォルダ存在")) stat.kind == .directory else true });
    }
    if (std.mem.eql(u8, name, "フォルダ作成")) {
        const path = try valueUtf8(runtime, source);
        defer runtime.allocator().free(path);
        const function = context.createDirectoryFn orelse return error.CreateDirectoryUnavailable;
        try function(context.context, path);
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "ファイル削除")) {
        const path = try valueUtf8(runtime, source);
        defer runtime.allocator().free(path);
        const function = context.deletePathFn orelse return error.DeletePathUnavailable;
        try function(context.context, path);
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "ファイルサイズ取得") or std.mem.eql(u8, name, "ファイル情報取得")) {
        const path = try valueUtf8(runtime, source);
        defer runtime.allocator().free(path);
        const stat = try context.statFile(path);
        if (std.mem.eql(u8, name, "ファイルサイズ取得")) return @as(?Value, .{ .number = @floatFromInt(stat.size) });
        return @as(?Value, try fileStatValue(runtime, stat));
    }
    if (std.mem.eql(u8, name, "ファイル列挙") or std.mem.eql(u8, name, "全ファイル列挙")) {
        const pattern = try valueUtf8(runtime, source);
        defer runtime.allocator().free(pattern);
        return @as(?Value, try listFiles(runtime, context, pattern, std.mem.eql(u8, name, "全ファイル列挙")));
    }
    if (std.mem.eql(u8, name, "ファイルコピー") or std.mem.eql(u8, name, "ファイル上書コピー") or std.mem.eql(u8, name, "ファイル移動") or std.mem.eql(u8, name, "ファイル上書移動")) {
        const from = try valueUtf8(runtime, source);
        defer runtime.allocator().free(from);
        const to = try valueUtf8(runtime, common.argument(arguments, 1));
        defer runtime.allocator().free(to);
        const explicit_overwrite = std.mem.indexOf(u8, name, "上書") != null;
        const overwrite = explicit_overwrite or try defaultCopyOverwrite(runtime, effects);
        try copyOrMoveWithProgress(runtime, state, context, effects, from, to, overwrite, std.mem.indexOf(u8, name, "移動") != null);
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "ファイル名抽出") or std.mem.eql(u8, name, "パス抽出")) {
        const path = try nodePathArgument(runtime, "path", source);
        defer runtime.allocator().free(path);
        const result = if (std.mem.eql(u8, name, "ファイル名抽出")) nodeBasename(path) else nodeDirname(path);
        return @as(?Value, try runtime.stringUtf8(result));
    }
    if (std.mem.eql(u8, name, "絶対パス変換")) {
        const path = try nodePathArgument(runtime, "paths[0]", source);
        defer runtime.allocator().free(path);
        const result = try absolutePath(runtime.allocator(), context, path);
        defer runtime.allocator().free(result);
        return @as(?Value, try runtime.stringUtf8(result));
    }
    if (std.mem.eql(u8, name, "相対パス展開")) {
        const base = try nodePathArgument(runtime, "path", source);
        defer runtime.allocator().free(base);
        const relative = try nodePathArgument(runtime, "path", common.argument(arguments, 1));
        defer runtime.allocator().free(relative);
        const joined = try std.fs.path.join(runtime.allocator(), &.{ base, relative });
        defer runtime.allocator().free(joined);
        const result = try absolutePath(runtime.allocator(), context, joined);
        defer runtime.allocator().free(result);
        return @as(?Value, try runtime.stringUtf8(result));
    }
    if (std.mem.eql(u8, name, "OS取得")) return @as(?Value, try runtime.stringUtf8(osName()));
    if (std.mem.eql(u8, name, "OSアーキテクチャ取得")) return @as(?Value, try runtime.stringUtf8(architectureName()));
    if (std.mem.eql(u8, name, "カレントディレクトリ取得") or std.mem.eql(u8, name, "作業フォルダ取得")) {
        const cwd = try context.cwd(runtime.allocator());
        defer runtime.allocator().free(cwd);
        return @as(?Value, try runtime.stringUtf8(cwd));
    }
    if (std.mem.eql(u8, name, "カレントディレクトリ変更") or std.mem.eql(u8, name, "作業フォルダ変更")) {
        const path = try nodeFilesystemPath(runtime, source);
        defer runtime.allocator().free(path);
        context.chdir(path) catch |failure| {
            setNodeChangeDirectoryFailure(runtime, context, path, failure) catch {};
            return failure;
        };
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "ホームディレクトリ取得")) return @as(?Value, if (context.home_directory) |home| try runtime.stringUtf8(home) else .undefined);
    if (std.mem.eql(u8, name, "デスクトップ")) return joinHome(runtime, context.home_directory, "Desktop");
    if (std.mem.eql(u8, name, "マイドキュメント")) return joinHome(runtime, context.home_directory, "Documents");
    if (std.mem.eql(u8, name, "母艦パス取得")) {
        const absolute_source = try absolutePath(runtime.allocator(), context, context.source_path);
        defer runtime.allocator().free(absolute_source);
        return @as(?Value, try runtime.stringUtf8(nodeDirname(absolute_source)));
    }
    if (std.mem.eql(u8, name, "テンポラリフォルダ")) return @as(?Value, try runtime.stringUtf8(context.temporary_directory));
    if (std.mem.eql(u8, name, "環境変数取得")) {
        const key = try valueUtf8(runtime, source);
        defer runtime.allocator().free(key);
        return @as(?Value, if (context.environment(key)) |value| try runtime.stringUtf8(value) else .undefined);
    }
    if (std.mem.eql(u8, name, "環境変数一覧取得")) {
        var result = try runtime.createDictionary();
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        for (context.environment_names, context.environment_values) |key, value| {
            var key_value = try runtime.stringUtf8(key);
            try roots.protect(&key_value);
            try result.dictionary.set(key_value.string, try runtime.stringUtf8(value));
        }
        return @as(?Value, result);
    }
    if (std.mem.eql(u8, name, "圧縮解凍ツールパス変更")) {
        const path = try valueUtf8(runtime, source);
        defer runtime.allocator().free(path);
        if (state.archive_tool_path) |old| runtime.allocator().free(old);
        state.archive_tool_path = try runtime.allocator().dupe(u8, path);
        if (effects) |actual_effects| try actual_effects.setGlobal("圧縮解凍ツールパス", source);
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "一時フォルダ作成")) {
        const prefix = try valueUtf8(runtime, source);
        defer runtime.allocator().free(prefix);
        const effective_prefix = if (prefix.len == 0) context.temporary_directory else prefix;
        const function = context.createTemporaryDirectoryFn orelse return error.CreateTemporaryDirectoryUnavailable;
        const path = try function(context.context, runtime.allocator(), effective_prefix);
        defer runtime.allocator().free(path);
        return @as(?Value, try runtime.stringUtf8(path));
    }
    if (std.mem.eql(u8, name, "起動待機") or std.mem.eql(u8, name, "起動") or std.mem.eql(u8, name, "コマンド実行") or std.mem.eql(u8, name, "コマンド実行待機")) {
        const command = try valueUtf8(runtime, source);
        defer runtime.allocator().free(command);
        if ((std.mem.eql(u8, name, "起動") or std.mem.eql(u8, name, "コマンド実行")) and context.startCommandFn != null and context.pollOperationFn != null) {
            const token = try context.startCommandFn.?(context.context, command);
            try state.pending_operations.append(runtime.allocator(), .{ .token = token, .mode = .command_output });
            return @as(?Value, .undefined);
        }
        var result = try context.runCommand(runtime.allocator(), command);
        defer result.deinit(runtime.allocator());
        if (std.mem.eql(u8, name, "起動待機")) {
            if (result.exit_code != 0) return error.CommandFailed;
            return @as(?Value, try runtime.stringUtf8(result.stdout));
        }
        if (std.mem.eql(u8, name, "コマンド実行待機")) {
            try context.writeStdout(result.stdout);
            try context.writeStderr(result.stderr);
            return @as(?Value, .{ .number = result.exit_code });
        }
        if (result.exit_code == 0) {
            if (result.stdout.len > 0) {
                try context.writeStdout(result.stdout);
                try context.writeStdout("\n");
            }
        } else try context.writeStderr(result.stderr);
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "起動時")) {
        const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
        const command = try valueUtf8(runtime, common.argument(arguments, 1));
        defer runtime.allocator().free(command);
        var callback = try actual_effects.resolve(source);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&callback);
        if (context.startCommandFn != null and context.pollOperationFn != null) {
            const token = try context.startCommandFn.?(context.context, command);
            try state.pending_operations.append(runtime.allocator(), .{ .token = token, .mode = .output_callback, .callback = callback });
            return @as(?Value, .undefined);
        }
        var result = try context.runCommand(runtime.allocator(), command);
        defer result.deinit(runtime.allocator());
        if (result.exit_code != 0) return error.CommandFailed;
        var stdout = try runtime.stringUtf8Lossy(result.stdout);
        try roots.protect(&stdout);
        _ = try actual_effects.invoke(callback, &.{stdout});
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "コンソールクリア")) return @as(?Value, .undefined);
    if (std.mem.eql(u8, name, "ブラウザ起動") or std.mem.eql(u8, name, "エクスプローラー起動")) {
        const target = try valueUtf8(runtime, source);
        defer runtime.allocator().free(target);
        const function = context.openExternalFn orelse return error.OpenExternalUnavailable;
        try function(context.context, runtime.allocator(), target, std.mem.eql(u8, name, "エクスプローラー起動"));
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "尋") or std.mem.eql(u8, name, "文字尋") or std.mem.eql(u8, name, "標準入力全取得")) {
        try ensureStdin(runtime.allocator(), state, context);
        if (std.mem.eql(u8, name, "標準入力全取得")) return @as(?Value, try runtime.stringUtf8(state.stdin_bytes.?));
        const prompt = try valueUtf8(runtime, source);
        defer runtime.allocator().free(prompt);
        try context.writeStdout(prompt);
        const line = nextStdinLine(state);
        var text = try runtime.stringUtf8(line);
        if (std.mem.eql(u8, name, "文字尋")) return @as(?Value, text);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&text);
        const number = try runtime.valueToNumber(text);
        return @as(?Value, if (std.math.isNan(number)) text else .{ .number = number });
    }
    if (std.mem.eql(u8, name, "標準入力取得時")) {
        const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
        try ensureStdin(runtime.allocator(), state, context);
        var callback = try actual_effects.resolve(source);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&callback);
        while (state.stdin_offset < state.stdin_bytes.?.len) {
            var line = try runtime.stringUtf8(nextStdinLine(state));
            try roots.protect(&line);
            try actual_effects.setGlobal("対象", line);
            _ = try actual_effects.invoke(callback, &.{line});
        }
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "ファイル処理時")) {
        const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
        state.file_process_callback = try actual_effects.resolve(source);
        state.file_process_stop = false;
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "ファイル処理強制停止")) {
        state.file_process_stop = true;
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "ファイルコピー時") or std.mem.eql(u8, name, "ファイル移動時") or std.mem.eql(u8, name, "ファイル削除時")) {
        const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
        var callback = try actual_effects.resolve(source);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&callback);
        if (std.mem.eql(u8, name, "ファイル削除時")) {
            const path = try valueUtf8(runtime, common.argument(arguments, 1));
            defer runtime.allocator().free(path);
            if (context.startFileOperationFn != null and context.pollOperationFn != null) {
                const absolute = try absolutePath(runtime.allocator(), context, path);
                defer runtime.allocator().free(absolute);
                const token = try context.startFileOperationFn.?(context.context, .delete, absolute, null, false);
                try state.pending_operations.append(runtime.allocator(), .{ .token = token, .mode = .no_argument_callback, .callback = callback });
                return @as(?Value, .undefined);
            }
            const function = context.deletePathFn orelse return error.DeletePathUnavailable;
            try function(context.context, path);
        } else {
            const from = try valueUtf8(runtime, common.argument(arguments, 1));
            defer runtime.allocator().free(from);
            const to = try valueUtf8(runtime, common.argument(arguments, 2));
            defer runtime.allocator().free(to);
            if (context.startFileOperationFn != null and context.pollOperationFn != null) {
                const absolute_from = try absolutePath(runtime.allocator(), context, from);
                defer runtime.allocator().free(absolute_from);
                const absolute_to = try absolutePath(runtime.allocator(), context, to);
                defer runtime.allocator().free(absolute_to);
                const operation: FileOperation = if (std.mem.eql(u8, name, "ファイル移動時")) .move else .copy;
                const token = try context.startFileOperationFn.?(context.context, operation, absolute_from, absolute_to, operation == .copy);
                try state.pending_operations.append(runtime.allocator(), .{ .token = token, .mode = .no_argument_callback, .callback = callback });
                return @as(?Value, .undefined);
            }
            if (std.mem.eql(u8, name, "ファイル移動時")) {
                const function = context.movePathFn orelse return error.MovePathUnavailable;
                try function(context.context, runtime.allocator(), from, to, false);
            } else {
                const function = context.copyPathFn orelse return error.CopyPathUnavailable;
                try function(context.context, runtime.allocator(), from, to, false);
            }
        }
        _ = try actual_effects.invoke(callback, &.{});
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "強制終了時")) {
        const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
        state.interrupt_callback = try actual_effects.resolve(source);
        const install_interrupt = context.installInterruptFn orelse return error.InterruptHandlingUnavailable;
        try install_interrupt(context.context);
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "圧縮") or std.mem.eql(u8, name, "解凍") or std.mem.eql(u8, name, "圧縮時") or std.mem.eql(u8, name, "解凍時")) {
        const callback_command = std.mem.endsWith(u8, name, "時");
        const source_index: usize = if (callback_command) 1 else 0;
        const destination_index: usize = if (callback_command) 2 else 1;
        const from = try valueUtf8(runtime, common.argument(arguments, source_index));
        defer runtime.allocator().free(from);
        const to = try valueUtf8(runtime, common.argument(arguments, destination_index));
        defer runtime.allocator().free(to);
        const function = context.archiveFn orelse return error.ArchiveUnavailable;
        const operation: ArchiveOperation = if (std.mem.startsWith(u8, name, "圧縮")) .compress else .extract;
        if (callback_command and context.startArchiveFn != null and context.pollOperationFn != null) {
            const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
            var callback = try actual_effects.resolve(source);
            var roots = runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&callback);
            const absolute_from = try absolutePath(runtime.allocator(), context, from);
            defer runtime.allocator().free(absolute_from);
            const absolute_to = try absolutePath(runtime.allocator(), context, to);
            defer runtime.allocator().free(absolute_to);
            const token = try context.startArchiveFn.?(context.context, operation, absolute_from, absolute_to, state.archive_tool_path);
            try state.pending_operations.append(runtime.allocator(), .{ .token = token, .mode = .output_callback, .callback = callback });
            return @as(?Value, .undefined);
        }
        const archive_output = try function(context.context, runtime.allocator(), operation, from, to, state.archive_tool_path);
        defer runtime.allocator().free(archive_output);
        if (callback_command) {
            const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
            var callback = try actual_effects.resolve(source);
            var roots = runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&callback);
            var output = try runtime.stringUtf8Lossy(archive_output);
            try roots.protect(&output);
            _ = try actual_effects.invoke(callback, &.{output});
            return @as(?Value, .undefined);
        }
        return @as(?Value, .{ .boolean = true });
    }
    if (std.mem.eql(u8, name, "終") or std.mem.eql(u8, name, "終了") or std.mem.eql(u8, name, "プロセス終")) {
        const number = if (std.mem.eql(u8, name, "プロセス終")) try runtime.valueToNumber(source) else 0;
        state.requested_exit_code = if (!std.math.isFinite(number)) 0 else @intFromFloat(@mod(@trunc(number), 256.0));
        return error.ProcessExitRequested;
    }
    return null;
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

fn callHttp(runtime: *Runtime, state: *State, context: Context, effects_optional: ?Effects, name: []const u8, arguments: []const Value) !?Value {
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
    const poll = context.pollOperationFn orelse return error.HttpRequestUnavailable;
    _ = poll;
    const token = try start(context.context, request.view());

    if (callback_kind) {
        const callback = common.argument(arguments, 0);
        try state.pending_operations.append(runtime.allocator(), .{
            .token = token,
            .mode = .http_callback,
            .callback = callback,
            .http_result = .text,
        });
        return @as(?Value, .undefined);
    }
    if (set_target) {
        try state.pending_operations.append(runtime.allocator(), .{ .token = token, .mode = .http_set_target, .http_result = .text });
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
    });
    return @as(?Value, promise);
}

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
    try body.writer.print("--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{ boundary, nodeBasename(path) });
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

fn settledHttpContent(runtime: *Runtime, response: Value, kind: HttpResultKind) !Value {
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

fn responseBody(response: Value) !Value {
    if (response != .dictionary) return error.HttpResponseExpected;
    return dictionaryGetAscii(response.dictionary, "__lnako_body") orelse return error.HttpResponseExpected;
}

fn responseStatus(response: Value) u16 {
    if (response != .dictionary) return 0;
    const value = dictionaryGetAscii(response.dictionary, "status") orelse return 0;
    return if (value == .number and value.number >= 0 and value.number <= 999) @intFromFloat(value.number) else 0;
}

fn httpBodyValue(runtime: *Runtime, body: []const u8, kind: HttpResultKind, status: u16) !Value {
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

fn httpResponseValue(runtime: *Runtime, result: CommandResult) !Value {
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

fn dictionaryGetAscii(dictionary: *value_mod.Dictionary, name: []const u8) ?Value {
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

fn upperAsciiAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, source);
    for (result) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return result;
}

fn valueBytes(runtime: *Runtime, value: Value) ![]u8 {
    if (value == .bytes) return runtime.allocator().dupe(u8, value.bytes.bytes);
    return valueUtf8(runtime, value);
}

pub fn pollOperations(runtime: *Runtime, state: *State, context: Context, effects: Effects) !bool {
    const poll = context.pollOperationFn orelse return false;
    var index: usize = 0;
    while (index < state.pending_operations.items.len) {
        const token = state.pending_operations.items[index].token;
        var result = (try poll(context.context, runtime.allocator(), token)) orelse {
            index += 1;
            continue;
        };
        defer result.deinit(runtime.allocator());
        var pending = state.pending_operations.orderedRemove(index);
        switch (pending.mode) {
            .command_output => if (result.exit_code == 0) {
                if (result.stdout.len > 0) {
                    try context.writeStdout(result.stdout);
                    try context.writeStdout("\n");
                }
            } else try context.writeStderr(result.stderr),
            .output_callback => {
                if (result.exit_code != 0) return error.CommandFailed;
                var roots = runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&pending.callback);
                var stdout = try runtime.stringUtf8Lossy(result.stdout);
                try roots.protect(&stdout);
                _ = try effects.invoke(pending.callback, &.{stdout});
            },
            .no_argument_callback => {
                if (result.exit_code != 0) return error.FileOperationFailed;
                var roots = runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&pending.callback);
                _ = try effects.invoke(pending.callback, &.{});
            },
            .http_callback => {
                if (result.exit_code != 0) {
                    const handler = effects.getGlobal("AJAX:ONERROR") orelse .null_value;
                    if (handler == .function) {
                        const reason = try runtime.stringUtf8Lossy(result.stderr);
                        _ = try effects.invoke(handler, &.{reason});
                        continue;
                    }
                    return error.HttpRequestFailed;
                }
                var roots = runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&pending.callback);
                var body = try runtime.stringUtf8Lossy(result.stdout);
                try roots.protect(&body);
                try effects.setGlobal("対象", body);
                _ = try effects.invoke(pending.callback, &.{body});
            },
            .http_set_target => {
                const status = result.http_status orelse 0;
                if (result.exit_code != 0 or status < 200 or status >= 300) {
                    try writeAjaxReceiveError(context, result);
                    continue;
                }
                const body = try runtime.stringUtf8Lossy(result.stdout);
                try effects.setGlobal("対象", body);
            },
            .http_promise => {
                if (pending.promise != .promise) return error.InvalidPendingPromise;
                const status = result.http_status orelse 0;
                if (result.exit_code != 0 or (pending.require_success and (status < 200 or status >= 300))) {
                    const reason = if (result.stderr.len > 0) try runtime.stringUtf8Lossy(result.stderr) else try runtime.stringUtf8("HTTP request failed");
                    try runtime.rejectPromise(pending.promise.promise, reason);
                    continue;
                }
                var value = if (pending.http_result == .response)
                    try httpResponseValue(runtime, result)
                else
                    try httpBodyValue(runtime, result.stdout, pending.http_result, status);
                var roots = runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&value);
                try runtime.resolvePromise(pending.promise.promise, value);
            },
        }
    }
    return state.pending_operations.items.len > 0;
}

fn writeAjaxReceiveError(context: Context, result: CommandResult) !void {
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

fn defaultCopyOverwrite(runtime: *Runtime, effects: ?Effects) !bool {
    const actual_effects = effects orelse return false;
    var mode = actual_effects.getGlobal("ファイルコピーデフォルト動作") orelse return false;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&mode);
    const text = try runtime.valueToString(mode);
    const utf8 = try text.string.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(utf8);
    return isAny(utf8, &.{ "上書き", "上書", "overwrite" });
}

fn copyOrMoveWithProgress(
    runtime: *Runtime,
    state: *State,
    context: Context,
    effects: ?Effects,
    source: []const u8,
    destination: []const u8,
    overwrite: bool,
    move: bool,
) !void {
    if (!overwrite and pathExists(context, destination)) return error.CopyDestinationExists;
    state.file_process_stop = false;
    const callback_enabled = state.file_process_callback != .undefined and effects != null;
    if (!callback_enabled) {
        if (move) {
            const function = context.movePathFn orelse return error.MovePathUnavailable;
            return function(context.context, runtime.allocator(), source, destination, overwrite);
        }
        const function = context.copyPathFn orelse return error.CopyPathUnavailable;
        return function(context.context, runtime.allocator(), source, destination, overwrite);
    }

    const copy = context.copyPathFn orelse return error.CopyPathUnavailable;
    const stat = try context.statFile(source);
    if (stat.kind != .directory) {
        try copy(context.context, runtime.allocator(), source, destination, overwrite);
        try emitFileProgress(runtime, state, effects.?, 1, 1);
    } else {
        const list = context.listDirectoryFn orelse return error.ListDirectoryUnavailable;
        const entries = try list(context.context, runtime.allocator(), source, true);
        defer {
            for (entries) |entry| runtime.allocator().free(entry.name);
            runtime.allocator().free(entries);
        }
        var total: usize = 0;
        for (entries) |entry| if (entry.kind == .file) {
            total += 1;
        };
        var current: usize = 0;
        for (entries) |entry| {
            if (entry.kind != .file) continue;
            if (state.file_process_stop) break;
            const from = try std.fs.path.join(runtime.allocator(), &.{ source, entry.name });
            defer runtime.allocator().free(from);
            const to = try std.fs.path.join(runtime.allocator(), &.{ destination, entry.name });
            defer runtime.allocator().free(to);
            try copy(context.context, runtime.allocator(), from, to, overwrite);
            current += 1;
            emitFileProgress(runtime, state, effects.?, total, current) catch {};
        }
    }
    if (move and !state.file_process_stop) {
        const remove = context.deletePathFn orelse return error.DeletePathUnavailable;
        try remove(context.context, source);
    }
}

fn pathExists(context: Context, path: []const u8) bool {
    _ = context.statFile(path) catch return false;
    return true;
}

fn ensureStdin(allocator: std.mem.Allocator, state: *State, context: Context) !void {
    if (state.stdin_bytes != null) return;
    const function = context.readStdinFn orelse return error.StandardInputUnavailable;
    state.stdin_bytes = try function(context.context, allocator);
}

fn emitFileProgress(runtime: *Runtime, state: *State, effects: Effects, total: usize, current: usize) !void {
    if (state.file_process_stop) return;
    var progress = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&progress);
    try setDictionary(runtime, progress.dictionary, "件数", .{ .number = @floatFromInt(total) });
    try setDictionary(runtime, progress.dictionary, "現在", .{ .number = @floatFromInt(current) });
    try effects.setGlobal("対象", progress);
    _ = try effects.invoke(state.file_process_callback, &.{progress});
}

fn nextStdinLine(state: *State) []const u8 {
    const bytes = state.stdin_bytes.?;
    if (state.stdin_offset >= bytes.len) return "";
    const start = state.stdin_offset;
    var end = start;
    while (end < bytes.len and bytes[end] != '\n') end += 1;
    state.stdin_offset = if (end < bytes.len) end + 1 else end;
    if (end > start and bytes[end - 1] == '\r') end -= 1;
    return bytes[start..end];
}

fn joinHome(runtime: *Runtime, home: ?[]const u8, child: []const u8) !?Value {
    const base = home orelse return @as(?Value, .undefined);
    const path = try std.fs.path.join(runtime.allocator(), &.{ base, child });
    defer runtime.allocator().free(path);
    return @as(?Value, try runtime.stringUtf8(path));
}

fn absolutePath(allocator: std.mem.Allocator, context: Context, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try context.cwd(allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn nodePathArgument(runtime: *Runtime, label: []const u8, value: Value) ![]u8 {
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

fn nodePathReceivedType(runtime: *Runtime, value: Value) ![]u8 {
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

fn nodePathPrimitiveReceivedType(runtime: *Runtime, value: Value, type_name: []const u8, bigint_suffix: bool) ![]u8 {
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

fn valueUtf8(runtime: *Runtime, value: Value) ![]u8 {
    const text = try runtime.valueToString(value);
    return text.string.toUtf8Lossy(runtime.allocator());
}

const NodeChangeDirectoryErrorInfo = struct {
    code: []const u8,
    description: []const u8,
};

fn nodeChangeDirectoryErrorInfo(failure: anyerror) ?NodeChangeDirectoryErrorInfo {
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

fn nodeFilesystemPath(runtime: *Runtime, value: Value) ![]u8 {
    const text = try runtime.valueToString(value);
    if (comptime builtin.os.tag == .windows) {
        return std.unicode.wtf16LeToWtf8Alloc(runtime.allocator(), text.string.units);
    }
    return text.string.toUtf8Lossy(runtime.allocator());
}

fn nodeErrorPath(runtime: *Runtime, path: []const u8) ![]u8 {
    if (comptime builtin.os.tag == .windows) {
        return std.unicode.wtf8ToUtf8LossyAlloc(runtime.allocator(), path);
    }
    return runtime.allocator().dupe(u8, path);
}

fn setNodeChangeDirectoryFailure(runtime: *Runtime, context: Context, path: []const u8, failure: anyerror) !void {
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

fn fileStatValue(runtime: *Runtime, stat: FileStat) !Value {
    var result = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    try setDictionary(runtime, result.dictionary, "size", .{ .number = @floatFromInt(stat.size) });
    try setDictionary(runtime, result.dictionary, "mtimeMs", .{ .number = @as(f64, @floatFromInt(stat.modified_nanoseconds)) / 1_000_000 });
    try setDictionary(runtime, result.dictionary, "ctimeMs", .{ .number = @as(f64, @floatFromInt(stat.changed_nanoseconds)) / 1_000_000 });
    try setDictionary(runtime, result.dictionary, "atimeMs", .{ .number = if (stat.accessed_nanoseconds) |time| @as(f64, @floatFromInt(time)) / 1_000_000 else 0 });
    try setDictionary(runtime, result.dictionary, "ino", .{ .number = stat.inode });
    try setDictionary(runtime, result.dictionary, "nlink", .{ .number = stat.links });
    try setDictionary(runtime, result.dictionary, "blksize", .{ .number = stat.block_size });
    try setStatMethod(runtime, result.dictionary, "isFile", stat.kind == .file);
    try setStatMethod(runtime, result.dictionary, "isDirectory", stat.kind == .directory);
    const false_methods = [_][]const u8{ "isBlockDevice", "isCharacterDevice", "isSymbolicLink", "isFIFO", "isSocket" };
    for (false_methods) |name| try setStatMethod(runtime, result.dictionary, name, false);
    return result;
}

fn setStatMethod(runtime: *Runtime, dictionary: *value_mod.Dictionary, name: []const u8, result: bool) !void {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var name_value = try runtime.stringUtf8(name);
    try roots.protect(&name_value);
    var function = try runtime.createNativeFunction(name_value.string, 0, if (result) returnTrue else returnFalse, &.{});
    try roots.protect(&function);
    try dictionary.set(name_value.string, function);
}

fn returnTrue(_: *Runtime, _: []const Value) anyerror!Value {
    return .{ .boolean = true };
}

fn returnFalse(_: *Runtime, _: []const Value) anyerror!Value {
    return .{ .boolean = false };
}

fn listFiles(runtime: *Runtime, context: Context, pattern: []const u8, recursive: bool) !Value {
    const has_wildcard = std.mem.indexOfScalar(u8, pattern, '*') != null;
    const base = if (has_wildcard) nodeDirname(pattern) else pattern;
    const mask = if (has_wildcard) nodeBasename(pattern) else "*";
    const function = context.listDirectoryFn orelse return error.ListDirectoryUnavailable;
    const entries = try function(context.context, runtime.allocator(), base, recursive);
    defer {
        for (entries) |entry| runtime.allocator().free(entry.name);
        runtime.allocator().free(entries);
    }
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    const absolute_base = if (recursive) try absolutePath(runtime.allocator(), context, base) else null;
    defer if (absolute_base) |path| runtime.allocator().free(path);
    for (entries) |entry| {
        if (recursive and entry.kind != .file) continue;
        if (!try wildcardMatches(runtime, mask, nodeBasename(entry.name))) continue;
        if (recursive) {
            const full_path = try std.fs.path.join(runtime.allocator(), &.{ absolute_base.?, entry.name });
            defer runtime.allocator().free(full_path);
            _ = try result.array.push(try runtime.stringUtf8(full_path));
        } else _ = try result.array.push(try runtime.stringUtf8(entry.name));
    }
    return result;
}

fn wildcardMatches(runtime: *Runtime, pattern: []const u8, name: []const u8) !bool {
    var expression: std.ArrayList(u8) = .empty;
    defer expression.deinit(runtime.allocator());
    const multiple = std.mem.indexOfScalar(u8, pattern, ';') != null;
    if (multiple) try expression.append(runtime.allocator(), '(');
    for (pattern) |byte| switch (byte) {
        '.' => try expression.appendSlice(runtime.allocator(), "\\."),
        '*' => try expression.appendSlice(runtime.allocator(), ".*"),
        ';' => try expression.append(runtime.allocator(), '|'),
        else => try expression.append(runtime.allocator(), byte),
    };
    if (multiple) try expression.append(runtime.allocator(), ')');
    try expression.append(runtime.allocator(), '$');
    var pattern_string = try value_mod.String.fromUtf8(runtime.allocator(), expression.items);
    defer pattern_string.deinit();
    var name_string = try value_mod.String.fromUtf8Lossy(runtime.allocator(), name);
    defer name_string.deinit();
    return regexp.testRaw(runtime.allocator(), pattern_string.units, name_string.units, true);
}

fn setDictionary(runtime: *Runtime, dictionary: *value_mod.Dictionary, key: []const u8, value: Value) !void {
    var rooted_value = value;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_value);
    var key_value = try runtime.stringUtf8(key);
    try roots.protect(&key_value);
    try dictionary.set(key_value.string, rooted_value);
}

fn nodeBasename(path: []const u8) []const u8 {
    return nodeBasenameFor(path, builtin.os.tag == .windows);
}

fn nodeBasenameFor(path: []const u8, windows: bool) []const u8 {
    var end = path.len;
    while (end > 0 and isSeparator(path[end - 1], windows)) end -= 1;
    if (end == 0) return "";
    const drive_path = windows and path.len >= 2 and isWindowsDriveLetter(path[0]) and path[1] == ':';
    if (drive_path and end == 2 and path.len > end and isSeparator(path[2], true)) return "";
    var start = end;
    while (start > 0 and !isSeparator(path[start - 1], windows)) start -= 1;
    if (drive_path and start < 2) start = 2;
    return path[start..end];
}

fn nodeDirname(path: []const u8) []const u8 {
    return nodeDirnameFor(path, builtin.os.tag == .windows);
}

fn nodeDirnameFor(path: []const u8, windows: bool) []const u8 {
    if (windows) return nodeDirnameWindowsFor(path);
    if (path.len == 0) return ".";
    if (path.len == 1) return if (isSeparator(path[0], false)) path else ".";
    var end = path.len;
    while (end > 0 and isSeparator(path[end - 1], false)) end -= 1;
    if (end == 0) return path[0..1];

    var start = end;
    while (start > 0 and !isSeparator(path[start - 1], false)) start -= 1;
    if (start == 0) return ".";
    if (start == 1 and isSeparator(path[0], false)) return path[0..1];
    if (start == 2 and isSeparator(path[0], false) and isSeparator(path[1], false)) return path[0..2];
    return path[0 .. start - 1];
}

fn nodeDirnameWindowsFor(path: []const u8) []const u8 {
    // Port Node 24's path.win32.dirname root scan.  A UNC root is special
    // only when it has a server, share, and a leftover component; the
    // original mixed separator bytes are retained in the returned prefix.
    const len = path.len;
    if (len == 0) return ".";
    if (len == 1) return if (isSeparator(path[0], true)) path else ".";

    var root_end: ?usize = null;
    var offset: usize = 0;
    const first = path[0];
    if (isSeparator(first, true)) {
        root_end = 1;
        offset = 1;
        if (isSeparator(path[1], true)) {
            var index: usize = 2;
            var last = index;
            while (index < len and !isSeparator(path[index], true)) index += 1;
            if (index < len and index != last) {
                last = index;
                while (index < len and isSeparator(path[index], true)) index += 1;
                if (index < len and index != last) {
                    last = index;
                    while (index < len and !isSeparator(path[index], true)) index += 1;
                    if (index == len) return path;
                    if (index != last) {
                        root_end = index + 1;
                        offset = index + 1;
                    }
                }
            }
        }
    } else if (isWindowsDriveLetter(first) and path[1] == ':') {
        root_end = if (len > 2 and isSeparator(path[2], true)) 3 else 2;
        offset = root_end.?;
    }

    var end: ?usize = null;
    var matched_separator = true;
    var index = len;
    while (index > offset) {
        index -= 1;
        if (isSeparator(path[index], true)) {
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

fn isWindowsDriveLetter(byte: u8) bool {
    return byte >= 'A' and byte <= 'Z' or byte >= 'a' and byte <= 'z';
}

fn isSeparator(byte: u8, windows: bool) bool {
    return byte == std.fs.path.sep or (windows and (byte == '/' or byte == '\\'));
}

fn osName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        .linux => "linux",
        else => @tagName(builtin.os.tag),
    };
}

fn architectureName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        .x86 => "ia32",
        else => @tagName(builtin.cpu.arch),
    };
}

fn environmentNameEqual(left: []const u8, right: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(left, right) else std.mem.eql(u8, left, right);
}

fn isAny(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}

test "Node互換のパス・OS・環境変数命令を処理する" {
    const TestHost = struct {
        fn cwd(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, "/work/project");
        }
    };
    var host = TestHost{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    const context = Context{
        .context = &host,
        .cwdFn = TestHost.cwd,
        .environment_names = &.{"LNAKO_TEST"},
        .environment_values = &.{"ok"},
        .home_directory = "/home/test",
    };
    const file = (try call(&runtime, &state, context, null, "ファイル名抽出", &.{try runtime.stringUtf8("a/b.txt")})).?;
    const file_utf8 = try file.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(file_utf8);
    try std.testing.expectEqualStrings("b.txt", file_utf8);
    const env = (try call(&runtime, &state, context, null, "環境変数取得", &.{try runtime.stringUtf8("LNAKO_TEST")})).?;
    const env_utf8 = try env.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(env_utf8);
    try std.testing.expectEqualStrings("ok", env_utf8);
}

test "Nodeカレントディレクトリ変更は失敗時にchdir診断を保持する" {
    const TestHost = struct {
        fn cwd(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, "/work/project");
        }

        fn chdir(_: *anyopaque, _: []const u8) !void {
            return error.FileNotFound;
        }
    };
    var host = TestHost{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var path = try runtime.stringUtf8("missing-日本語-7f4b");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&path);
    const context = Context{ .context = &host, .cwdFn = TestHost.cwd, .chdirFn = TestHost.chdir };
    _ = call(&runtime, &state, context, null, "カレントディレクトリ変更", &.{path}) catch |failure| {
        try std.testing.expectEqual(error.FileNotFound, failure);
        try std.testing.expectEqualStrings(
            "ENOENT: no such file or directory, chdir '/work/project' -> 'missing-日本語-7f4b'",
            runtime.failureMessage().?,
        );
        runtime.clearFailureMessage();
        return;
    };
    return error.ExpectedFailure;
}

test "Node互換のbasenameとdirnameはルートと連続区切りを処理する" {
    try std.testing.expectEqualStrings("", nodeBasename("/"));
    try std.testing.expectEqualStrings("/", nodeDirname("/"));
    try std.testing.expectEqualStrings("b", nodeBasename("a//b//"));
    try std.testing.expectEqualStrings("a/", nodeDirname("a//b//"));
}

test "Node互換のWindowsパスはdrive-relativeとUNC rootを保持する" {
    try std.testing.expectEqualStrings("foo", nodeBasenameFor("C:foo", true));
    try std.testing.expectEqualStrings("C:", nodeDirnameFor("C:foo", true));
    try std.testing.expectEqualStrings("bar", nodeBasenameFor("C:foo\\bar", true));
    try std.testing.expectEqualStrings("C:foo", nodeDirnameFor("C:foo\\bar", true));
    try std.testing.expectEqualStrings("", nodeBasenameFor("C:\\", true));
    try std.testing.expectEqualStrings("C:\\", nodeDirnameFor("C:\\", true));
    try std.testing.expectEqualStrings("file", nodeBasenameFor("\\\\server\\share\\file", true));
    try std.testing.expectEqualStrings("\\\\server\\share\\", nodeDirnameFor("\\\\server\\share\\file", true));
    try std.testing.expectEqualStrings("share", nodeBasenameFor("\\\\server\\share\\", true));
    try std.testing.expectEqualStrings("\\\\server\\share\\", nodeDirnameFor("\\\\server\\share\\", true));
    try std.testing.expectEqualStrings("bar", nodeBasenameFor("\\\\?\\C:\\foo\\bar", true));
    try std.testing.expectEqualStrings("\\\\?\\C:\\foo", nodeDirnameFor("\\\\?\\C:\\foo\\bar", true));
    try std.testing.expectEqualStrings("share", nodeBasenameFor("\\\\?\\UNC\\server\\share\\", true));
    try std.testing.expectEqualStrings("\\\\?\\UNC\\server", nodeDirnameFor("\\\\?\\UNC\\server\\share\\", true));
    try std.testing.expectEqualStrings("name", nodeBasenameFor("\\\\.\\pipe\\name\\", true));
    try std.testing.expectEqualStrings("\\\\.\\pipe\\", nodeDirnameFor("\\\\.\\pipe\\name\\", true));
    try std.testing.expectEqualStrings("b", nodeBasenameFor("a/\\\\b", true));
    try std.testing.expectEqualStrings("a/\\", nodeDirnameFor("a/\\\\b", true));
    try std.testing.expectEqualStrings("b", nodeBasenameFor("a\\\\/b", true));
    try std.testing.expectEqualStrings("a\\\\", nodeDirnameFor("a\\\\/b", true));
    const mixed_unc = [_]u8{ '/', '\\', '\\', 'c', '?', '\\', 'Z', ':', '_', 'a', 'b', '?', '0', 'Y', '/', '\\' };
    const mixed_unc_dir = [_]u8{ '/', '\\', '\\', 'c', '?' };
    try std.testing.expectEqualStrings("Z:_ab?0Y", nodeBasenameFor(&mixed_unc, true));
    try std.testing.expectEqualSlices(u8, &mixed_unc_dir, nodeDirnameFor(&mixed_unc, true));
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

test "ブラウザとファイルマネージャーの起動をホストへ委譲する" {
    const TestHost = struct {
        calls: usize = 0,
        first_target: [128]u8 = undefined,
        first_target_length: usize = 0,
        first_reveal: bool = false,
        last_target: [128]u8 = undefined,
        last_target_length: usize = 0,
        last_reveal: bool = false,

        fn cwd(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, "/work");
        }

        fn open(context: *anyopaque, _: std.mem.Allocator, target: []const u8, reveal: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.calls == 0) {
                @memcpy(self.first_target[0..target.len], target);
                self.first_target_length = target.len;
                self.first_reveal = reveal;
            }
            @memcpy(self.last_target[0..target.len], target);
            self.last_target_length = target.len;
            self.last_reveal = reveal;
            self.calls += 1;
        }
    };
    var host = TestHost{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    const context = Context{ .context = &host, .cwdFn = TestHost.cwd, .openExternalFn = TestHost.open };
    _ = try call(&runtime, &state, context, null, "ブラウザ起動", &.{try runtime.stringUtf8("https://example.invalid/")});
    _ = try call(&runtime, &state, context, null, "エクスプローラー起動", &.{try runtime.stringUtf8("file.txt")});
    try std.testing.expectEqual(@as(usize, 2), host.calls);
    try std.testing.expect(!host.first_reveal);
    try std.testing.expectEqualStrings("https://example.invalid/", host.first_target[0..host.first_target_length]);
    try std.testing.expect(host.last_reveal);
    try std.testing.expectEqualStrings("file.txt", host.last_target[0..host.last_target_length]);
}

test "一時フォルダの空指定はテンポラリパス自体を接頭辞にする" {
    const TestHost = struct {
        seen: [64]u8 = undefined,
        seen_length: usize = 0,

        fn cwd(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, "/work");
        }

        fn create(context: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            @memcpy(self.seen[0..prefix.len], prefix);
            self.seen_length = prefix.len;
            return std.fmt.allocPrint(allocator, "{s}ABC123", .{prefix});
        }
    };
    var host = TestHost{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    const context = Context{
        .context = &host,
        .cwdFn = TestHost.cwd,
        .temporary_directory = "/tmp/lnako-test",
        .createTemporaryDirectoryFn = TestHost.create,
    };
    const empty = try runtime.stringUtf8("");
    const result = (try call(&runtime, &state, context, null, "一時フォルダ作成", &.{empty})).?;
    try std.testing.expectEqualStrings("/tmp/lnako-test", host.seen[0..host.seen_length]);
    const result_utf8 = try result.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(result_utf8);
    try std.testing.expectEqualStrings("/tmp/lnako-testABC123", result_utf8);
}
