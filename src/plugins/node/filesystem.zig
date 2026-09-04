const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../../runtime/value.zig");
const common = @import("../system/common.zig");
const regexp = @import("../system/regexp.zig");
const encoding = @import("../encoding.zig");
const shared = @import("shared.zig");

const Value = shared.Value;
const Runtime = shared.Runtime;
const Context = shared.Context;
const State = shared.State;
const Effects = shared.Effects;
const FileKind = shared.FileKind;
const FileStat = shared.FileStat;
const FileEntry = shared.FileEntry;
const FileOperation = shared.FileOperation;
const ArchiveOperation = shared.ArchiveOperation;
const valueUtf8 = shared.valueUtf8;
const setDictionary = shared.setDictionary;
const isAny = shared.isAny;
const nodePathArgument = shared.nodePathArgument;

pub fn callFilesystem(runtime: *Runtime, state: *State, context: Context, effects: ?Effects, name: []const u8, arguments: []const Value, source: Value) !?Value {
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
    return null;
}

pub fn absolutePath(allocator: std.mem.Allocator, context: Context, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try context.cwd(allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

pub fn pathsOverlap(left: []const u8, right: []const u8) bool {
    const host_separator = std.fs.path.sep;
    var left_normalized: [4096]u8 = undefined;
    var right_normalized: [4096]u8 = undefined;
    if (left.len >= left_normalized.len or right.len >= right_normalized.len) return false;
    @memcpy(left_normalized[0..left.len], left);
    left_normalized[left.len] = 0;
    @memcpy(right_normalized[0..right.len], right);
    right_normalized[right.len] = 0;
    if (builtin.os.tag == .windows) {
        for (left_normalized[0..left.len]) |*byte| {
            if (std.fs.path.isSep(byte.*)) byte.* = host_separator;
            if (byte.* >= 'A' and byte.* <= 'Z') byte.* += 'a' - 'A';
        }
        for (right_normalized[0..right.len]) |*byte| {
            if (std.fs.path.isSep(byte.*)) byte.* = host_separator;
            if (byte.* >= 'A' and byte.* <= 'Z') byte.* += 'a' - 'A';
        }
    }
    if (std.mem.eql(u8, left_normalized[0..left.len], right_normalized[0..right.len])) return true;
    const left_norm = left_normalized[0..left.len];
    const right_norm = right_normalized[0..right.len];
    if (std.mem.startsWith(u8, right_norm, left_norm) and right_norm.len > left_norm.len and right_norm[left_norm.len] == host_separator) return true;
    if (std.mem.startsWith(u8, left_norm, right_norm) and left_norm.len > right_norm.len and left_norm[right_norm.len] == host_separator) return true;
    return false;
}

pub fn pathExists(context: Context, path: []const u8) bool {
    _ = context.statFile(path) catch return false;
    return true;
}

pub fn nodeBasename(path: []const u8) []const u8 {
    return nodeBasenameFor(path, builtin.os.tag == .windows);
}

pub fn nodeBasenameFor(path: []const u8, windows: bool) []const u8 {
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

pub fn nodeDirname(path: []const u8) []const u8 {
    return nodeDirnameFor(path, builtin.os.tag == .windows);
}

pub fn nodeDirnameFor(path: []const u8, windows: bool) []const u8 {
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

pub fn nodeDirnameWindowsFor(path: []const u8) []const u8 {
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

pub fn isWindowsDriveLetter(byte: u8) bool {
    return byte >= 'A' and byte <= 'Z' or byte >= 'a' and byte <= 'z';
}

pub fn isSeparator(byte: u8, windows: bool) bool {
    return byte == std.fs.path.sep or (windows and (byte == '/' or byte == '\\'));
}

pub fn fileStatValue(runtime: *Runtime, stat: FileStat) !Value {
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

pub fn listFiles(runtime: *Runtime, context: Context, pattern: []const u8, recursive: bool) !Value {
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

pub fn wildcardMatches(runtime: *Runtime, pattern: []const u8, name: []const u8) !bool {
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

pub fn copyOrMoveWithProgress(
    runtime: *Runtime,
    state: *State,
    context: Context,
    effects: ?Effects,
    source: []const u8,
    destination: []const u8,
    overwrite: bool,
    move: bool,
) !void {
    {
        const resolved_source = try absolutePath(runtime.allocator(), context, source);
        defer runtime.allocator().free(resolved_source);
        const resolved_destination = try absolutePath(runtime.allocator(), context, destination);
        defer runtime.allocator().free(resolved_destination);
        if (pathsOverlap(resolved_source, resolved_destination)) return error.SelfOrDescendantPath;
    }
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

pub fn defaultCopyOverwrite(runtime: *Runtime, effects: ?Effects) !bool {
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

pub fn emitFileProgress(runtime: *Runtime, state: *State, effects: Effects, total: usize, current: usize) !void {
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

test "copy/moveは同一・子孫パスを重複判定する" {
    try std.testing.expect(pathsOverlap("/work", "/work"));
    try std.testing.expect(pathsOverlap("/work", "/work/file"));
    try std.testing.expect(pathsOverlap("/work/file", "/work"));
    try std.testing.expect(!pathsOverlap("/work", "/work2"));
    try std.testing.expect(!pathsOverlap("/work", "/other"));
    try std.testing.expect(!pathsOverlap("/work/a", "/work/ab"));
    if (builtin.os.tag == .windows) {
        try std.testing.expect(pathsOverlap("C:/work", "C:\\work"));
        try std.testing.expect(pathsOverlap("C:/work/file", "C:\\WORK"));
    }
}
