const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../../runtime/value.zig");
const foundation = @import("../../runtime/low_level_foundation.zig");
const low_level_io = @import("../../runtime/low_level_io.zig");
const low_level_hash = @import("../../runtime/low_level_hash.zig");
const low_level_fs = @import("../../runtime/low_level_fs.zig");
const low_level_context = @import("../../runtime/low_level/context.zig");
const common = @import("../system/common.zig");
const node_shared = @import("../node/shared.zig");
const shared = @import("shared.zig");
const capabilities = @import("capabilities.zig");
const stdio = @import("stdio.zig");
const stream = @import("stream.zig");
const hash = @import("hash.zig");
const fs = @import("fs.zig");

const Value = shared.Value;
const Runtime = shared.Runtime;
const State = shared.State;
const Effects = shared.Effects;
const Context = low_level_context.Context;
const emptyContext = low_level_context.emptyContext;
const captureThrow = shared.captureThrow;
const lookupHandle = shared.lookupHandle;
const handleForId = shared.handleForId;
const rememberHandle = shared.rememberHandle;
const forgetHandleId = shared.forgetHandleId;

pub fn call(
    runtime: *Runtime,
    state: *State,
    context: Context,
    effects: Effects,
    name: []const u8,
    arguments: []const Value,
) !?Value {
    if (foundation.catalogCommandFor(name)) |spec| {
        if (arguments.len > spec.max) {
            return shared.throwStructured(runtime, effects, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
        // 実装済み命令の引数不足は引数数エラー。未実装命令はENOTSUPが
        // 「未実装」の通知を兼ねるためmin未満もENOTSUPへ統一する
        // （`aot/low_level.zig` の lowLevelUnsupportedBuiltin と同じ方針）。
        if (spec.implemented and arguments.len < spec.min) {
            return shared.throwStructured(runtime, effects, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
    }
    if (std.mem.eql(u8, name, foundation.capability_supported_command)) {
        return @as(?Value, .{ .boolean = capabilities.capabilitySupported(arguments, context) });
    }
    if (std.mem.eql(u8, name, foundation.capability_list_command)) {
        return @as(?Value, try capabilities.capabilityList(runtime));
    }
    if (matches(name, foundation.stream_commands.open, foundation.stream_commands.open_user)) return @as(?Value, try stream.openFile(runtime, state, context, effects, arguments));
    if (matches(name, foundation.stream_commands.close, foundation.stream_commands.close_user)) return @as(?Value, try stream.closeFile(runtime, state, context, effects, arguments));
    if (matches(name, foundation.stream_commands.read_bytes, foundation.stream_commands.read_bytes_user)) return @as(?Value, try stream.readBytes(runtime, state, context, effects, arguments));
    if (matches(name, foundation.stream_commands.write_bytes, foundation.stream_commands.write_bytes_user)) return @as(?Value, try stream.writeBytes(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.stream_commands.sync)) return @as(?Value, try stream.syncFile(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.stream_commands.truncate)) return @as(?Value, try stream.truncateFile(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.hash_commands.create)) return @as(?Value, try hash.hashCreate(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.hash_commands.update)) return @as(?Value, try hash.hashUpdate(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.hash_commands.digest)) return @as(?Value, try hash.hashDigest(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.hash_commands.discard)) return @as(?Value, try hash.hashDiscard(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.stat)) return @as(?Value, try fs.statPath(runtime, state, context, effects, arguments, true));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.lstat)) return @as(?Value, try fs.statPath(runtime, state, context, effects, arguments, false));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.symlink)) return @as(?Value, try fs.symlinkPath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.readlink)) return @as(?Value, try fs.readlinkPath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.hardlink)) return @as(?Value, try fs.hardlinkPath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.realpath)) return @as(?Value, try fs.realpathPath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.rename)) return @as(?Value, try fs.renamePath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.unlink)) return @as(?Value, try fs.unlinkPath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.rmdir)) return @as(?Value, try fs.rmdirPath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.truncate_path)) return @as(?Value, try fs.truncatePath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.utime_path)) return @as(?Value, try fs.utimePath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.utime_handle)) return @as(?Value, try fs.utimeHandle(runtime, state, context, effects, arguments));
    if (matches(name, foundation.stdio_commands.stdin_read, foundation.stdio_commands.stdin_read_user)) return @as(?Value, try stdio.stdinRead(runtime, context, effects, arguments));
    if (matches(name, foundation.stdio_commands.stdout_write, foundation.stdio_commands.stdout_write_user)) return @as(?Value, try stdio.stdoutWrite(runtime, context, effects, arguments));
    if (matches(name, foundation.stdio_commands.stderr_write, foundation.stdio_commands.stderr_write_user)) return @as(?Value, try stdio.stderrWrite(runtime, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.stdio_commands.stdout_sync)) return @as(?Value, try stdio.stdoutSync(runtime, context, effects));
    if (std.mem.eql(u8, name, foundation.stdio_commands.stderr_sync)) return @as(?Value, try stdio.stderrSync(runtime, context, effects));
    // カタログ掲載済みだが未実装の命令は、capabilityとoperationを設定した
    // 構造化 ENOTSUP で応答する（G0の未対応契約）。実装済み命令がここへ
    // 到達するのはdispatch腕の書き忘れなので、開発時に検出する。
    if (foundation.catalogCommandFor(name)) |command| {
        std.debug.assert(!command.implemented);
        const capability: ?[]const u8 = if (command.capability) |cap| cap.id() else null;
        return shared.throwStructured(runtime, effects, .ENOTSUP, command.operation, null, capability, "この低レイヤー命令はまだ実装されていません");
    }
    return null;
}

fn matches(name: []const u8, canonical: []const u8, user_form: []const u8) bool {
    return std.mem.eql(u8, name, canonical) or std.mem.eql(u8, name, user_form);
}

test "throwStructuredはGC stress下でもエラー辞書を保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ファイル閉", &.{.{ .number = 1 }}));
    try std.testing.expect(thrown == .dictionary);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&thrown);
    const code = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const text = try node_shared.valueUtf8(&runtime, code);
    defer runtime.allocator().free(text);
    try std.testing.expectEqualStrings("EBADF", text);
}

test "未実装命令はdispatch名と利用者名の両形で構造化ENOTSUPを投げる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var arguments = [_]Value{.undefined} ** 4;
    var covered: usize = 0;
    for (foundation.catalog_commands) |spec| {
        if (spec.implemented) continue;
        covered += 1;
        for ([2][]const u8{ spec.name, spec.user_name orelse spec.name }) |name| {
            thrown = .undefined;
            try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, name, arguments[0..spec.min]));
            try std.testing.expect(thrown == .dictionary);
            try roots.protect(&thrown);
            try std.testing.expectEqual(value_mod.DictionaryKind.structured_error, thrown.dictionary.kind);
            const code = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
            const code_text = try node_shared.valueUtf8(&runtime, code);
            defer runtime.allocator().free(code_text);
            try std.testing.expectEqualStrings("ENOTSUP", code_text);
            const operation = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.operation) orelse return error.TestExpectedEqual;
            const operation_text = try node_shared.valueUtf8(&runtime, operation);
            defer runtime.allocator().free(operation_text);
            try std.testing.expectEqualStrings(spec.operation, operation_text);
            if (spec.capability) |capability| {
                const field = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.capability) orelse return error.TestExpectedEqual;
                const field_text = try node_shared.valueUtf8(&runtime, field);
                defer runtime.allocator().free(field_text);
                try std.testing.expectEqualStrings(capability.id(), field_text);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 32), covered);
}

test "実装済み命令の引数不足はEINVALで未知capability照会はfalse" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{}));
    try std.testing.expect(thrown == .dictionary);
    try roots.protect(&thrown);
    const code = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const text = try node_shared.valueUtf8(&runtime, code);
    defer runtime.allocator().free(text);
    try std.testing.expectEqualStrings("EINVAL", text);

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ファイル閉", &.{}));
    try std.testing.expect(thrown == .dictionary);
    try roots.protect(&thrown);
    const close_code = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const close_text = try node_shared.valueUtf8(&runtime, close_code);
    defer runtime.allocator().free(close_text);
    try std.testing.expectEqualStrings("EINVAL", close_text);

    // 未知capability名の照会は引数数エラーではなくfalseを返す。
    var name = try runtime.stringUtf8("unknown_capability");
    try roots.protect(&name);
    const supported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and !supported.boolean);
}

test "余分な引数はEINVALで、openだけのホストはstream_file_io非対応" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var handle = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&handle);
    try rememberHandle(&state, runtime.allocator(), handle, .{ .index = 1, .generation = 1 });
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ファイル閉", &.{ handle, .{ .number = 1 } }));
    try roots.protect(&thrown);
    const code = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const text = try node_shared.valueUtf8(&runtime, code);
    defer runtime.allocator().free(text);
    try std.testing.expectEqualStrings("EINVAL", text);

    var name = try runtime.stringUtf8("stream_file_io");
    try roots.protect(&name);
    const supported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and !supported.boolean);

    var truncate_name = try runtime.stringUtf8("truncate");
    try roots.protect(&truncate_name);
    const truncate_full = Context{
        .stream = .{
            .context = emptyContext().stream.context,
            .truncateFileFn = struct {
                fn dummy(_: *anyopaque, _: u64, _: u64) anyerror!void {
                    return;
                }
            }.dummy,
        },
        .fs = .{
            .context = emptyContext().fs.context,
            .truncatePathFn = struct {
                fn dummy(_: *anyopaque, _: []const u8, _: u64) anyerror!void {
                    return;
                }
            }.dummy,
        },
    };
    const truncate_supported = (try call(&runtime, &state, truncate_full, effects, foundation.capability_supported_command, &.{truncate_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(truncate_supported == .boolean and truncate_supported.boolean);

    // handle側callbackだけではtruncate capabilityは成立しない（path側が必要）。
    const truncate_partial = Context{ .stream = .{
        .context = emptyContext().stream.context,
        .truncateFileFn = struct {
            fn dummy(_: *anyopaque, _: u64, _: u64) anyerror!void {
                return;
            }
        }.dummy,
    } };
    const truncate_partial_supported = (try call(&runtime, &state, truncate_partial, effects, foundation.capability_supported_command, &.{truncate_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(truncate_partial_supported == .boolean and !truncate_partial_supported.boolean);
}
