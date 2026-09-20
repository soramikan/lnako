const std = @import("std");
const builtin = @import("builtin");
const foundation = @import("../../runtime/low_level_foundation.zig");
const low_level_dir = @import("../../runtime/low_level_dir.zig");
const low_level_context = @import("../../runtime/low_level/context.zig");
const common = @import("../system/common.zig");
const node_shared = @import("../node/shared.zig");
const shared = @import("shared.zig");
// ドメインテストはディスパッチャ経由で契約を検査する。本番ビルドでは
// call.zigを解析しないよう、テスト時にだけ読み込んで閉路を避ける。
const call = if (builtin.is_test) @import("call.zig").call else void;

const Value = shared.Value;
const Runtime = shared.Runtime;
const State = shared.State;
const Effects = shared.Effects;
const Context = low_level_context.Context;

const throwStructured = shared.throwStructured;
const throwIoMapped = shared.throwIoMapped;
const lookupHandle = shared.lookupHandle;
const forgetHandle = shared.forgetHandle;
const rememberHandle = shared.rememberHandle;
const pathStringFromBytes = shared.pathStringFromBytes;

const captureThrow = shared.captureThrow;
const expectThrownCode = shared.expectThrownCode;
const expectThrownField = shared.expectThrownField;

fn requirePath(runtime: *Runtime, effects: Effects, value: Value, operation: []const u8) ![]u8 {
    if (value != .string) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "pathは文字列である必要があります");
    }
    // lossy変換は孤立サロゲートをU+FFFDへ化けさせ、実在する同名ファイルへの
    // 誤操作につながるため、可逆なWTF-8変換を使う（AOTのpathArgumentと同じ規則）。
    return foundation.pathBytesFromUtf16(runtime.allocator(), value.string.units);
}

pub fn openDirectory(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.directory_operations.open;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const raw = context.openDir(path) catch |failure| {
        return throwIoMapped(runtime, effects, failure, foundation.dirOpenErrorCode(failure), operation, path, .dir_iterator);
    };
    errdefer context.closeDir(raw) catch {};
    const id = foundation.HandleId.fromRaw(raw);
    var handle = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&handle);
    try rememberHandle(state, runtime.allocator(), handle, id);
    return handle;
}

pub fn nextEntry(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.directory_operations.next;
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, operation, null, null, "無効なハンドルです");
    };
    const allocator = runtime.allocator();
    const entry = context.nextDir(id.raw(), allocator) catch |failure| {
        return throwIoMapped(runtime, effects, failure, foundation.dirNextErrorCode(failure), operation, null, .dir_iterator);
    };
    const actual = entry orelse return .null_value;
    defer allocator.free(actual.name);
    return dirEntryValue(runtime, actual);
}

pub fn closeDirectory(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.directory_operations.close;
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, operation, null, null, "無効なハンドルです");
    };
    context.closeDir(id.raw()) catch |failure| {
        return throwIoMapped(runtime, effects, failure, foundation.dirCloseErrorCode(failure), operation, null, .dir_iterator);
    };
    forgetHandle(state, handle);
    return .undefined;
}

/// `ディレクトリ列挙時` は handle型を正本とする糖衣。開く・次取得・閉じるを
/// 1呼出しにまとめ、コールバックを各エントリの `dirEntry` 辞書で呼ぶ。
/// コールバックが真を返すとその時点で列挙を中断する。コールバックの例外は
/// そのまま伝播し、ディレクトリは必ず閉じる。
pub fn foreach(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.directory_operations.foreach;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var callback = effects.resolve(common.argument(arguments, 1)) catch |failure| {
        if (failure == error.OutOfMemory) return failure;
        if (failure == error.CallbackExecutionUnavailable) {
            return throwStructured(runtime, effects, .ENOTSUP, operation, null, "dir_iterator", "コールバックを実行できません");
        }
        return throwStructured(runtime, effects, .EINVAL, operation, path, null, "CALLBACKは関数である必要があります");
    };
    try roots.protect(&callback);

    const raw = context.openDir(path) catch |failure| {
        return throwIoMapped(runtime, effects, failure, foundation.dirForeachErrorCode(failure), operation, path, .dir_iterator);
    };
    defer context.closeDir(raw) catch {};

    const allocator = runtime.allocator();
    while (true) {
        const maybe_entry = context.nextDir(raw, allocator) catch |failure| {
            return throwIoMapped(runtime, effects, failure, foundation.dirForeachErrorCode(failure), operation, path, .dir_iterator);
        };
        const entry = maybe_entry orelse break;
        defer allocator.free(entry.name);
        var entry_value = try dirEntryValue(runtime, entry);
        var entry_roots = runtime.rootFrame();
        defer entry_roots.deinit();
        try entry_roots.protect(&entry_value);
        const result = effects.invoke(callback, &.{entry_value}) catch |failure| {
            if (failure == error.OutOfMemory) return failure;
            if (failure == error.CallbackExecutionUnavailable) {
                return throwStructured(runtime, effects, .ENOTSUP, operation, null, "dir_iterator", "コールバックを実行できません");
            }
            return failure;
        };
        if (result.toBoolean()) break;
    }
    return .undefined;
}

fn dirEntryValue(runtime: *Runtime, entry: low_level_dir.Entry) !Value {
    var dictionary = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.dir_entry_keys.name, try pathStringFromBytes(runtime, entry.name));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.dir_entry_keys.kind, try runtime.stringUtf8(entry.kind.name()));
    return dictionary;
}

/// Issue #33のディレクトリ列挙を実OSで検証するためのContext。InterpreterのHostと
/// 同じ `low_level_dir` 実装を共有し、dispatchと値組み立てだけを単体で検査する。
const DirTestHost = struct {
    table: low_level_dir.DirHandleTable,

    fn init(allocator: std.mem.Allocator) DirTestHost {
        return .{ .table = low_level_dir.DirHandleTable.init(allocator) };
    }

    fn deinit(self: *DirTestHost) void {
        self.table.deinit(std.testing.io);
    }

    fn openDirCallback(pointer: *anyopaque, path: []const u8) anyerror!u64 {
        const self: *DirTestHost = @ptrCast(@alignCast(pointer));
        return (try self.table.open(std.testing.io, path)).raw();
    }

    fn nextDirCallback(pointer: *anyopaque, raw: u64, allocator: std.mem.Allocator) anyerror!?low_level_dir.Entry {
        const self: *DirTestHost = @ptrCast(@alignCast(pointer));
        return self.table.next(foundation.HandleId.fromRaw(raw), std.testing.io, allocator);
    }

    fn closeDirCallback(pointer: *anyopaque, raw: u64) anyerror!void {
        const self: *DirTestHost = @ptrCast(@alignCast(pointer));
        _ = self.table.remove(std.testing.io, foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    }

    fn context(self: *DirTestHost) Context {
        return .{ .dir = .{
            .context = self,
            .openDirFn = openDirCallback,
            .nextDirFn = nextDirCallback,
            .closeDirFn = closeDirCallback,
        } };
    }
};

/// コールバック実行を検査するEffects。実際の関数呼び出しの代わりに、
/// `dirEntry` 辞書を1引数で受け取り回数を数える。`reject_resolve` を立てると
/// 関数名解決が失敗する状況（非関数CALLBACK）を再現する。
const CallbackHost = struct {
    thrown: Value = .undefined,
    count: usize = 0,
    stop_after: usize = std.math.maxInt(usize),
    bad_argument: bool = false,
    reject_resolve: bool = false,
    fail_invoke: bool = false,

    fn throwFn(context: *anyopaque, value: Value) anyerror!void {
        const self: *CallbackHost = @ptrCast(@alignCast(context));
        self.thrown = value;
        return error.NakoException;
    }

    fn invoke(context: *anyopaque, callable: Value, arguments: []const Value) anyerror!Value {
        _ = callable;
        const self: *CallbackHost = @ptrCast(@alignCast(context));
        if (self.fail_invoke) return error.NakoException;
        if (arguments.len != 1 or arguments[0] != .dictionary) {
            self.bad_argument = true;
            return error.TestExpectedEqual;
        }
        self.count += 1;
        return .{ .boolean = self.count >= self.stop_after };
    }

    fn resolve(context: *anyopaque, value: Value) anyerror!Value {
        const self: *CallbackHost = @ptrCast(@alignCast(context));
        if (self.reject_resolve) return error.NotCallable;
        return value;
    }

    fn effects(self: *CallbackHost) Effects {
        return .{
            .context = @ptrCast(self),
            .throwFn = throwFn,
            .invokeFn = invoke,
            .resolveFn = resolve,
        };
    }
};

test "低レイヤーのディレクトリ開/次取得/閉はContext経由で動作する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var host = DirTestHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "alpha.txt", .data = "" });
    try temporary.dir.createDir(std.testing.io, "日本語フォルダ", .default_dir);
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    var path = try runtime.stringUtf8(directory);
    try roots.protect(&path);

    var capability_name = try runtime.stringUtf8("dir_iterator");
    try roots.protect(&capability_name);
    const supported = (try call(&runtime, &state, context, effects, foundation.capability_supported_command, &.{capability_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and supported.boolean);

    var handle = (try call(&runtime, &state, context, effects, "ディレクトリ開く", &.{path})) orelse return error.TestExpectedEqual;
    try roots.protect(&handle);
    try std.testing.expect(handle == .dictionary);

    var names: std.ArrayList([]u16) = .empty;
    defer {
        for (names.items) |units| std.testing.allocator.free(units);
        names.deinit(std.testing.allocator);
    }
    var kinds: std.ArrayList([]u8) = .empty;
    defer {
        for (kinds.items) |kind| std.testing.allocator.free(kind);
        kinds.deinit(std.testing.allocator);
    }
    while (true) {
        var entry = (try call(&runtime, &state, context, effects, "ディレクトリ次取得", &.{handle})) orelse return error.TestExpectedEqual;
        if (entry == .null_value) break;
        try roots.protect(&entry);
        const name = node_shared.dictionaryGetAscii(entry.dictionary, foundation.dir_entry_keys.name) orelse return error.TestExpectedEqual;
        try std.testing.expect(name == .string);
        try names.append(std.testing.allocator, try std.testing.allocator.dupe(u16, name.string.units));
        const kind = node_shared.dictionaryGetAscii(entry.dictionary, foundation.dir_entry_keys.kind) orelse return error.TestExpectedEqual;
        const kind_text = try node_shared.valueUtf8(&runtime, kind);
        try kinds.append(std.testing.allocator, kind_text);
        // カタログ typeSchemas.dirEntry の2フィールドが両方存在する。
        inline for (foundation.dir_entry_key_list) |key| {
            try std.testing.expect(node_shared.dictionaryGetAscii(entry.dictionary, key) != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    // 日本語名はWTF-8往復で化けない。
    const expected_japanese = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "日本語フォルダ");
    defer std.testing.allocator.free(expected_japanese);
    var found_japanese = false;
    for (names.items) |units| {
        if (std.mem.eql(u16, units, expected_japanese)) found_japanese = true;
    }
    try std.testing.expect(found_japanese);

    _ = (try call(&runtime, &state, context, effects, "ディレクトリ閉じる", &.{handle})) orelse return error.TestExpectedEqual;

    // 二重closeとclose後の次取得はEBADF。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ディレクトリ閉じる", &.{handle}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EBADF");

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ディレクトリ次取得", &.{handle}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EBADF");
}

test "低レイヤーのディレクトリ開はENOENTとENOTDIRを返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var host = DirTestHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "plain.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const plain_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "plain.txt" });
    defer std.testing.allocator.free(plain_path);
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing" });
    defer std.testing.allocator.free(missing_path);

    var plain = try runtime.stringUtf8(plain_path);
    try roots.protect(&plain);
    var missing = try runtime.stringUtf8(missing_path);
    try roots.protect(&missing);

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ディレクトリ開く", &.{plain}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOTDIR");
    try expectThrownField(&runtime, thrown, foundation.error_object_keys.operation, "opendir");
    // 失敗した対象パスをエラー辞書の path に保持する。
    try expectThrownField(&runtime, thrown, foundation.error_object_keys.path, plain_path);

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ディレクトリ開く", &.{missing}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOENT");
    try expectThrownField(&runtime, thrown, foundation.error_object_keys.path, missing_path);

    // 非文字列pathはEINVAL。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ディレクトリ開く", &.{.{ .number = 1 }}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "低レイヤーのディレクトリ列挙時はコールバックを各エントリで呼び中断できる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = DirTestHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "one.txt", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "two.txt", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "three.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    var path = try runtime.stringUtf8(directory);
    try roots.protect(&path);

    var callback_host = CallbackHost{};
    _ = (try call(&runtime, &state, context, callback_host.effects(), "ディレクトリ列挙時", &.{ path, .undefined })) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 3), callback_host.count);
    try std.testing.expect(!callback_host.bad_argument);
    // 全エントリを見た後にハンドルは残らない。
    try std.testing.expectEqual(@as(usize, 0), host.table.len());

    // 途中で真を返すとそれ以上呼ばれない。
    callback_host = .{ .stop_after = 1 };
    _ = (try call(&runtime, &state, context, callback_host.effects(), "ディレクトリ列挙時", &.{ path, .undefined })) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), callback_host.count);
    try std.testing.expectEqual(@as(usize, 0), host.table.len());
}

test "低レイヤーのディレクトリ列挙時はENOENTと非関数CALLBACKを拒否する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = DirTestHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing" });
    defer std.testing.allocator.free(missing_path);

    var missing = try runtime.stringUtf8(missing_path);
    try roots.protect(&missing);

    var callback_host = CallbackHost{};
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, callback_host.effects(), "ディレクトリ列挙時", &.{ missing, .undefined }));
    try roots.protect(&callback_host.thrown);
    try expectThrownCode(&runtime, callback_host.thrown, "ENOENT");

    // 解決できないCALLBACKはEINVAL。
    var path = try runtime.stringUtf8(directory);
    try roots.protect(&path);
    var rejecting = CallbackHost{ .reject_resolve = true };
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, rejecting.effects(), "ディレクトリ列挙時", &.{ path, .undefined }));
    try roots.protect(&rejecting.thrown);
    try expectThrownCode(&runtime, rejecting.thrown, "EINVAL");
}

test "低レイヤーのファイル種別handleはディレクトリ命令でEBADFになる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var host = DirTestHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();

    // ファイル種別のindex空間（1〜）を持つ偽handle。DirTestHostの表には
    // 存在しないため、種別取り違えはEBADFになる。
    var file_like = try runtime.createDictionary();
    try roots.protect(&file_like);
    try rememberHandle(&state, runtime.allocator(), file_like, .{ .index = 1, .generation = 1 });

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ディレクトリ次取得", &.{file_like}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EBADF");

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ディレクトリ閉じる", &.{file_like}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EBADF");
}

test "低レイヤーのディレクトリ列挙時はコールバック例外時に必ず閉じる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = DirTestHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "only.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    var path = try runtime.stringUtf8(directory);
    try roots.protect(&path);

    var callback_host = CallbackHost{ .fail_invoke = true };
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, callback_host.effects(), "ディレクトリ列挙時", &.{ path, .undefined }));
    // 例外が伝播してもハンドルは残らない。
    try std.testing.expectEqual(@as(usize, 0), host.table.len());
}
