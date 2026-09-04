const std = @import("std");
const state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const encoding = shared.encoding;
const string_mod = shared.string_mod;
const regexp = shared.regexp;

const AotFileTaskOperation = state.AotFileTaskOperation;

const Runtime = state.Runtime;
const Value = state.Value;
const Object = state.Object;
const Tag = state.Tag;
const RootFrame = state.RootFrame;
const numberValue = state.numberValue;
const valueToNumber = state.valueToNumber;
const valueToNumberRuntime = state.valueToNumberRuntime;
const valueUtf8LossyAlloc = state.valueUtf8LossyAlloc;
const valueUtf16Alloc = state.valueUtf16Alloc;
const runtimeUtf8String = state.runtimeUtf8String;
const runtimeUtf8StringLossy = state.runtimeUtf8StringLossy;
const staticStringValue = state.staticStringValue;
const arrayAppendBuiltin = state.arrayAppendBuiltin;
const aotRuntimeIo = state.aotRuntimeIo;
const currentDirectoryAlloc = state.currentDirectoryAlloc;
const queueAotFileTask = state.queueAotFileTask;
const nodeBasename = state.nodeBasename;
const nodeDirname = state.nodeDirname;
const writeBytes = state.writeBytes;
const createAotPromise = state.createAotPromise;
const resolveAotPromise = state.resolveAotPromise;
const invokeAotCallback = state.invokeAotCallback;
const resolveAotCallback = state.resolveAotCallback;

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
