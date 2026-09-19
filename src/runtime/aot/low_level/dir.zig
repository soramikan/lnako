const std = @import("std");
const state = @import("../state.zig");
const shared = @import("shared.zig");
const foundation = @import("../../low_level_foundation.zig");
const low_level_dir = @import("../../low_level_dir.zig");

const aot_builtin = shared.aot_builtin;
const Runtime = shared.Runtime;
const Value = shared.Value;
const Tag = shared.Tag;
const RootFrame = shared.RootFrame;
const numberValue = shared.numberValue;
const valueUtf16Alloc = shared.valueUtf16Alloc;
const runtimeUtf8String = shared.runtimeUtf8String;
const isString = shared.isString;
const io = shared.io;
const dirTable = shared.dirTable;
const handleIdFor = shared.handleIdFor;
const rememberHandle = shared.rememberHandle;
const forgetHandleId = shared.forgetHandleId;
const pathStringFromBytes = shared.pathStringFromBytes;
const setField = shared.setField;
const throwIoMapped = shared.throwIoMapped;
const throwStructured = shared.throwStructured;

pub fn pluginOpenDir(context: *anyopaque, path: []const u8) anyerror!u64 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return (try dirTable(runtime).open(io(runtime), path)).raw();
}

pub fn pluginNextDir(context: *anyopaque, raw: u64, allocator: std.mem.Allocator) anyerror!?low_level_dir.Entry {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return dirTable(runtime).next(foundation.HandleId.fromRaw(raw), io(runtime), allocator);
}

pub fn pluginCloseDir(context: *anyopaque, raw: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const id = foundation.HandleId.fromRaw(raw);
    _ = dirTable(runtime).remove(io(runtime), id) orelse return error.BadFileDescriptor;
    // 動的InterpreterからAOTハンドルを閉じた場合も、AOT側のID対応表を
    // 解放する。残すと辞書がGCルートとして保持され解放不能になる
    // （pluginCloseFile/pluginDiscardHashと同じ後処理）。
    forgetHandleId(runtime, id);
}

fn pathArgument(runtime: *Runtime, value: Value, operation: []const u8) ![]u8 {
    if (!isString(value)) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "pathは文字列である必要があります");
    }
    // lossy変換は孤立サロゲートをU+FFFDへ化けさせ、実在する同名ファイルへの
    // 誤操作につながるため、可逆なWTF-8変換を使う（Interpreterと同じ規則）。
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return foundation.pathBytesFromUtf16(runtime.allocator, units);
}

pub fn openBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.directory_operations.open;
    if (arguments.len < 1) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "pathは文字列である必要があります");
    }
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    const id = dirTable(runtime).open(io(runtime), path) catch |failure| {
        return throwIoMapped(runtime, failure, foundation.dirOpenErrorCode(failure), operation, path, .dir_iterator);
    };
    errdefer _ = dirTable(runtime).remove(io(runtime), id);
    var handle = try runtime.createDictionary(&.{});
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&handle), 1);
    defer runtime.popRoots(&roots);
    try rememberHandle(runtime, handle, id);
    return handle;
}

pub fn nextBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.directory_operations.next;
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, operation, null, null, "無効なハンドルです");
    }
    const id = handleIdFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, operation, null, null, "無効なハンドルです");
    };
    const allocator = runtime.allocator;
    const entry = dirTable(runtime).next(id, io(runtime), allocator) catch |failure| {
        return throwIoMapped(runtime, failure, foundation.dirNextErrorCode(failure), operation, null, .dir_iterator);
    };
    const actual = entry orelse return .{ .tag = @intFromEnum(Tag.null_value) };
    defer allocator.free(actual.name);
    return dirEntryValue(runtime, actual);
}

pub fn closeBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.directory_operations.close;
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, operation, null, null, "無効なハンドルです");
    }
    const id = handleIdFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, operation, null, null, "無効なハンドルです");
    };
    _ = dirTable(runtime).remove(io(runtime), id) orelse {
        return throwStructured(runtime, .EBADF, operation, null, null, "無効なハンドルです");
    };
    forgetHandleId(runtime, id);
    if (runtime.dynamic_forget_handle) |forget| forget(runtime, id.raw());
    return .{};
}

/// `ディレクトリ列挙時` はhandle型を正本とする糖衣。コールバックが真を返すと
/// 列挙を中断し、例外はそのまま伝播する。ディレクトリは必ず閉じる。
pub fn foreachBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.directory_operations.foreach;
    if (arguments.len < 2) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "CALLBACKは関数である必要があります");
    }
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    var callback = state.resolveAotCallback(runtime, arguments[1]) catch |failure| {
        if (failure == error.OutOfMemory) return failure;
        return throwStructured(runtime, .EINVAL, operation, path, null, "CALLBACKは関数である必要があります");
    };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&callback), 1);
    defer runtime.popRoots(&roots);

    const id = dirTable(runtime).open(io(runtime), path) catch |failure| {
        return throwIoMapped(runtime, failure, foundation.dirForeachErrorCode(failure), operation, path, .dir_iterator);
    };
    defer _ = dirTable(runtime).remove(io(runtime), id);

    const allocator = runtime.allocator;
    while (true) {
        const entry = dirTable(runtime).next(id, io(runtime), allocator) catch |failure| {
            return throwIoMapped(runtime, failure, foundation.dirForeachErrorCode(failure), operation, path, .dir_iterator);
        } orelse break;
        defer allocator.free(entry.name);
        var entry_value = try dirEntryValue(runtime, entry);
        var entry_roots = RootFrame{};
        runtime.pushRoots(&entry_roots, @ptrCast(&entry_value), 1);
        const result = state.invokeAotCallback(runtime, callback, @ptrCast(&entry_value), 1) catch |failure| {
            runtime.popRoots(&entry_roots);
            return failure;
        };
        runtime.popRoots(&entry_roots);
        if (state.valueTruthy(result)) break;
    }
    return .{};
}

fn dirEntryValue(runtime: *Runtime, entry: low_level_dir.Entry) !Value {
    var result = try runtime.createDictionary(&.{});
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&result), 1);
    defer runtime.popRoots(&roots);
    try setField(runtime, result, foundation.dir_entry_keys.name, try pathStringFromBytes(runtime, entry.name));
    try setField(runtime, result, foundation.dir_entry_keys.kind, try runtimeUtf8String(runtime, entry.kind.name()));
    return result;
}

test "AOT低レイヤーのディレクトリ開/次取得/閉はRuntimeの表で動作する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "alpha.txt", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "beta.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, directory);
    const handle = try openBuiltin(&runtime, &.{roots[0]});
    try std.testing.expectEqual(@as(u32, 1), runtime.low_level_handle_ids.size);

    var names: usize = 0;
    while (true) {
        const entry = try nextBuiltin(&runtime, &.{handle});
        if (entry.tag == @intFromEnum(Tag.null_value)) break;
        roots[1] = entry;
        const name = shared.dictionaryProperty(entry, &.{ 'n', 'a', 'm', 'e' });
        try std.testing.expect(isString(name));
        const kind = shared.dictionaryProperty(entry, &.{ 't', 'y', 'p', 'e' });
        try std.testing.expect(isString(kind));
        names += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), names);

    _ = try closeBuiltin(&runtime, &.{handle});
    try std.testing.expectEqual(@as(u32, 0), runtime.low_level_handle_ids.size);
    try std.testing.expectEqual(@as(usize, 0), runtime.low_level_dir_handles.?.len());
    // 二重closeはEBADF。
    try std.testing.expectError(error.NakoException, closeBuiltin(&runtime, &.{handle}));
}

test "AOT低レイヤーのディレクトリ開はENOENTとENOTDIRを返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "plain.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const plain_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "plain.txt" });
    defer std.testing.allocator.free(plain_path);
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing" });
    defer std.testing.allocator.free(missing_path);

    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, plain_path);
    try std.testing.expectError(error.NakoException, openBuiltin(&runtime, &.{roots[0]}));
    try shared.expectPendingCode(&runtime, "ENOTDIR");
    try expectPendingPath(&runtime, plain_path);
    _ = runtime.takeException();

    roots[1] = try runtimeUtf8String(&runtime, missing_path);
    try std.testing.expectError(error.NakoException, openBuiltin(&runtime, &.{roots[1]}));
    try shared.expectPendingCode(&runtime, "ENOENT");
    try expectPendingPath(&runtime, missing_path);
    _ = runtime.takeException();
}

/// 保留中の構造化エラーの `path` が失敗対象パスと一致することを検査する。
fn expectPendingPath(runtime: *Runtime, expected: []const u8) !void {
    const path_value = shared.dictionaryProperty(runtime.pending_exception, &.{ 'p', 'a', 't', 'h' });
    const text = try shared.valueUtf8LossyAlloc(runtime, path_value);
    defer runtime.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "AOT低レイヤーのディレクトリ列挙時はコールバックを呼び途中で中断できる" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    // `invokeAotCallback` は `state.active_runtime` を経由してnative callbackを
    // 呼ぶため、組み込み単体テストでもactive runtimeを設定する。
    state.active_runtime = runtime;
    defer state.active_runtime = null;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "one.txt", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "two.txt", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "three.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, directory);
    roots[1] = try runtime.createBindingCell(numberValue(0));
    roots[2] = try runtime.createFunction(aotVisitCounter, 1, &.{roots[1]});

    _ = try foreachBuiltin(&runtime, &.{ roots[0], roots[2] });
    // コールバックは2回目で真を返し、3件目を読む前に中断する。
    try std.testing.expectEqual(@as(f64, 2), shared.valueToNumber(roots[1].object().?.payload.binding_cell));
    try std.testing.expectEqual(@as(usize, 0), runtime.low_level_dir_handles.?.len());
    try std.testing.expect(!runtime.has_pending_exception);
}

fn aotVisitCounter(out: *Value, context: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    const function: *shared.Object = @ptrCast(@alignCast(context));
    const cell = function.payload.function.captures[0].object().?;
    if (arguments == null or len != 1 or arguments.?[0].tag != @intFromEnum(Tag.dictionary)) {
        out.* = .{};
        return;
    }
    const count = shared.valueToNumber(cell.payload.binding_cell) + 1;
    cell.payload.binding_cell = numberValue(count);
    out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(count > 1) };
}

test "AOT低レイヤーのディレクトリ列挙時は数値の真でも中断する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer state.active_runtime = null;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "one.txt", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "two.txt", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "three.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtimeUtf8String(&runtime, directory);
    roots[1] = try runtime.createBindingCell(numberValue(0));
    roots[2] = try runtime.createFunction(aotVisitStopNumber, 1, &.{roots[1]});

    _ = try foreachBuiltin(&runtime, &.{ roots[0], roots[2] });
    // なでしこの真は数値1も含むため、最初のコールバックで中断する。
    try std.testing.expectEqual(@as(f64, 1), shared.valueToNumber(roots[1].object().?.payload.binding_cell));
    try std.testing.expectEqual(@as(usize, 0), runtime.low_level_dir_handles.?.len());
}

fn aotVisitStopNumber(out: *Value, context: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const function: *shared.Object = @ptrCast(@alignCast(context));
    const cell = function.payload.function.captures[0].object().?;
    cell.payload.binding_cell = numberValue(shared.valueToNumber(cell.payload.binding_cell) + 1);
    out.* = numberValue(1);
}

test "AOT低レイヤーのファイル種別handleはディレクトリ命令でEBADFになる" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    var roots = [_]Value{.{}};
    var frame: RootFrame = .{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);

    // ファイル種別のindex空間（1〜）を持つ偽handle。dir表には無い。
    roots[0] = try active.createDictionary(&.{});
    try shared.rememberHandle(active, roots[0], .{ .index = 1, .generation = 1 });

    try expectLowLevelCode(active, .low_level_dir_next, &.{roots[0]}, "EBADF");
    try expectLowLevelCode(active, .low_level_dir_close, &.{roots[0]}, "EBADF");
}

/// dispatch経由で低レイヤー命令を呼び、構造化エラーのcodeを検査する。
fn expectLowLevelCode(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value, expected: []const u8) !void {
    var out: Value = .{};
    state.lnako_aot_builtin_call(&out, if (arguments.len > 0) arguments.ptr else null, arguments.len, @intFromEnum(command));
    try std.testing.expect(runtime.has_pending_exception);
    const code = try shared.aotThrownCode(runtime);
    defer runtime.allocator.free(code);
    try std.testing.expectEqualStrings(expected, code);
}

test "AOT低レイヤーのディレクトリ列挙時はコールバック例外時に必ず閉じる" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "only.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);
    roots[0] = try runtimeUtf8String(active, directory);
    roots[1] = try active.createFunction(aotFailVisitor, 1, &.{});

    try std.testing.expectError(error.CallbackExecutionFailed, foreachBuiltin(active, &.{ roots[0], roots[1] }));
    try std.testing.expect(active.has_pending_exception);
    _ = active.takeException();
    // 例外が伝播してもハンドルは残らない。
    try std.testing.expectEqual(@as(usize, 0), active.low_level_dir_handles.?.len());
}

fn aotFailVisitor(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    // 無効ハンドルのcloseを呼び、なでしこ例外（EBADF）を発生させる。
    var arguments = [_]Value{numberValue(1)};
    var ignored = Value{};
    state.lnako_aot_builtin_call(&ignored, &arguments, arguments.len, @intFromEnum(aot_builtin.Command.low_level_file_close));
    out.* = .{};
}
