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
// ドメインテストはディスパッチャ経由で契約を検査する。本番ビルドでは
// call.zigを解析しないよう、テスト時にだけ読み込んで閉路を避ける。
const call = if (builtin.is_test) @import("call.zig").call else void;

const Value = shared.Value;
const Runtime = shared.Runtime;
const State = shared.State;
const Effects = shared.Effects;
const Context = low_level_context.Context;
const emptyContext = low_level_context.emptyContext;

const captureThrow = shared.captureThrow;
const expectThrownCode = shared.expectThrownCode;
const expectThrownField = shared.expectThrownField;

pub fn capabilitySupported(arguments: []const Value, context: Context) bool {
    const value = common.argument(arguments, 0);
    if (value != .string) return false;
    var buffer: [64]u8 = undefined;
    const length = @min(value.string.units.len, buffer.len);
    for (value.string.units[0..length], 0..) |unit, index| {
        if (unit > 0x7f) return false;
        buffer[index] = @intCast(unit);
    }
    const capability = foundation.Capability.fromId(buffer[0..length]) orelse return false;
    if (!foundation.capabilityImplemented(capability)) return false;
    return switch (capability) {
        .stream_file_io => context.hasStreamFileIo(),
        .truncate => context.hasTruncate(),
        .incremental_hash => context.hasIncrementalHash(),
        .raw_stdio => context.hasRawStdio(),
        .stat, .lstat => context.hasStat(),
        .symlink => context.hasSymlink(),
        .readlink => context.hasReadlink(),
        .hardlink => context.hasHardLink(),
        .realpath => context.hasRealpath(),
        .rename => context.hasRename(),
        .unlink => context.hasUnlink(),
        .rmdir => context.hasRmdir(),
        .dir_iterator => context.hasDirIterator(),
        else => false,
    };
}

pub fn capabilityList(runtime: *Runtime) !Value {
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    inline for (std.meta.tags(foundation.Capability)) |capability| {
        _ = try result.array.push(try runtime.stringUtf8(capability.id()));
    }
    return result;
}

test "新規capabilityはホスト関数が無い場合ENOTSUPを返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var name = try runtime.stringUtf8("stat");
    try roots.protect(&name);
    const supported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and !supported.boolean);

    var path = try runtime.stringUtf8("whatever");
    try roots.protect(&path);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ファイル詳細情報取得", &.{path}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOTSUP");
    try expectThrownField(&runtime, thrown, foundation.error_object_keys.capability, "stat");
}
