const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../runtime/value.zig");
const constants = @import("system/constants.zig");
const common = @import("system/common.zig");
const regexp = @import("system/regexp.zig");
const encoding = @import("encoding.zig");

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

pub const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

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
        for (self.pending_operations.items) |pending| try runtime.traceExternal(pending.callback);
    }
};

const PendingMode = enum { command_output, output_callback, no_argument_callback };
const PendingOperation = struct {
    token: usize,
    mode: PendingMode,
    callback: Value = .undefined,
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
        const path = try valueUtf8(runtime, source);
        defer runtime.allocator().free(path);
        const result = if (std.mem.eql(u8, name, "ファイル名抽出")) nodeBasename(path) else nodeDirname(path);
        return @as(?Value, try runtime.stringUtf8(result));
    }
    if (std.mem.eql(u8, name, "絶対パス変換")) {
        const path = try valueUtf8(runtime, source);
        defer runtime.allocator().free(path);
        const result = try absolutePath(runtime.allocator(), context, path);
        defer runtime.allocator().free(result);
        return @as(?Value, try runtime.stringUtf8(result));
    }
    if (std.mem.eql(u8, name, "相対パス展開")) {
        const base = try valueUtf8(runtime, source);
        defer runtime.allocator().free(base);
        const relative = try valueUtf8(runtime, common.argument(arguments, 1));
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
        const path = try valueUtf8(runtime, source);
        defer runtime.allocator().free(path);
        try context.chdir(path);
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
        }
    }
    return state.pending_operations.items.len > 0;
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

fn valueUtf8(runtime: *Runtime, value: Value) ![]u8 {
    const text = try runtime.valueToString(value);
    return text.string.toUtf8Lossy(runtime.allocator());
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
    var end = path.len;
    while (end > 0 and isSeparator(path[end - 1])) end -= 1;
    if (end == 0) return if (path.len > 0) path[path.len - 1 ..] else "";
    var start = end;
    while (start > 0 and !isSeparator(path[start - 1])) start -= 1;
    return path[start..end];
}

fn nodeDirname(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    var end = path.len;
    while (end > 1 and isSeparator(path[end - 1])) end -= 1;
    var index = end;
    while (index > 0 and !isSeparator(path[index - 1])) index -= 1;
    if (index == 0) return ".";
    while (index > 1 and isSeparator(path[index - 1])) index -= 1;
    return path[0..index];
}

fn isSeparator(byte: u8) bool {
    return byte == std.fs.path.sep or (builtin.os.tag == .windows and (byte == '/' or byte == '\\'));
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

test "ブラウザとファイルマネージャーの起動をホストへ委譲する" {
    const TestHost = struct {
        calls: usize = 0,
        reveal: bool = false,

        fn cwd(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, "/work");
        }

        fn open(context: *anyopaque, _: std.mem.Allocator, _: []const u8, reveal: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.reveal = reveal;
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
    try std.testing.expect(host.reveal);
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
