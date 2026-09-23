const std = @import("std");
const builtin = @import("builtin");
const state = @import("../state.zig");
const shared = @import("shared.zig");
const foundation = @import("../../low_level_foundation.zig");
const low_level_posix = @import("../../low_level_posix.zig");

const aot_builtin = shared.aot_builtin;
const BigInt = shared.BigInt;
const Runtime = shared.Runtime;
const Value = shared.Value;
const Tag = shared.Tag;
const RootFrame = shared.RootFrame;
const numberValue = shared.numberValue;
const valueToNumber = shared.valueToNumber;
const runtimeUtf8String = shared.runtimeUtf8String;
const pathArgument = shared.pathArgument;
const dictionaryProperty = shared.dictionaryProperty;
const throwIo = shared.throwIo;
const throwStructured = shared.throwStructured;
const expectPendingCode = shared.expectPendingCode;
const staticStringValue = state.staticStringValue;

const lowLevelPosixBuiltin = if (builtin.is_test) @import("../low_level.zig").lowLevelPosixBuiltin else void;

pub fn pluginChmod(context: *anyopaque, path: []const u8, mode: u32) anyerror!void {
    _ = context;
    return low_level_posix.chmod(path, mode);
}

pub fn pluginChown(context: *anyopaque, path: []const u8, uid: ?u32, gid: ?u32, follow: bool) anyerror!void {
    _ = context;
    return low_level_posix.chown(path, uid, gid, follow);
}

pub fn pluginAccess(context: *anyopaque, path: []const u8, mode: u32) anyerror!bool {
    _ = context;
    return low_level_posix.access(path, mode);
}

pub fn pluginId(context: *anyopaque, kind: low_level_posix.IdKind) anyerror!u32 {
    _ = context;
    return low_level_posix.id(kind);
}

pub fn pluginGroups(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]u32 {
    _ = context;
    return low_level_posix.groups(allocator);
}

pub fn pluginUmask(context: *anyopaque, mode: u32) anyerror!u32 {
    _ = context;
    return low_level_posix.umask(mode);
}

pub fn chmodBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.posix_operations.chmod;
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    const mode = try permissionModeArgument(runtime, arguments[1], operation);
    low_level_posix.chmod(path, mode) catch |failure| {
        return throwIo(runtime, failure, operation, path, null, .chmod);
    };
    return .{};
}

pub fn chownBuiltin(runtime: *Runtime, arguments: []const Value, follow: bool) !Value {
    const operation = if (follow) foundation.posix_operations.chown else foundation.posix_operations.lchown;
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    const uid = try idArgument(runtime, arguments[1], operation);
    const gid = try idArgument(runtime, arguments[2], operation);
    low_level_posix.chown(path, uid, gid, follow) catch |failure| {
        return throwIo(runtime, failure, operation, path, null, .chown);
    };
    return .{};
}

pub fn accessBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.posix_operations.access;
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    const mode = try accessModeArgument(runtime, arguments[1], operation);
    const allowed = low_level_posix.access(path, mode) catch |failure| {
        return throwIo(runtime, failure, operation, path, null, .access);
    };
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(allowed) };
}

pub fn idBuiltin(runtime: *Runtime, arguments: []const Value, kind: low_level_posix.IdKind) !Value {
    _ = arguments;
    const operation = operationForId(kind);
    const result = low_level_posix.id(kind) catch |failure| {
        return throwIo(runtime, failure, operation, null, null, .uid_gid);
    };
    return numberValue(@floatFromInt(result));
}

pub fn groupsBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    _ = arguments;
    const operation = foundation.posix_operations.groups;
    const list = low_level_posix.groups(runtime.allocator) catch |failure| {
        return throwIo(runtime, failure, operation, null, null, .uid_gid);
    };
    defer runtime.allocator.free(list);
    const result = try runtime.createArray(&.{});
    var rooted = [_]Value{ result, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);
    for (list) |group| {
        rooted[1] = numberValue(@floatFromInt(group));
        try rooted[0].object().?.payload.array.append(runtime.allocator, rooted[1]);
    }
    return rooted[0];
}

pub fn umaskBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.posix_operations.umask;
    const mode = try permissionModeArgument(runtime, arguments[0], operation);
    const previous = low_level_posix.umask(mode) catch |failure| {
        return throwIo(runtime, failure, operation, null, null, .uid_gid);
    };
    return numberValue(@floatFromInt(previous));
}

fn operationForId(kind: low_level_posix.IdKind) []const u8 {
    return switch (kind) {
        .uid => foundation.posix_operations.uid,
        .euid => foundation.posix_operations.euid,
        .gid => foundation.posix_operations.gid,
        .egid => foundation.posix_operations.egid,
    };
}

fn permissionModeArgument(runtime: *Runtime, value: Value, operation: []const u8) !u32 {
    return shared.unsignedArgument(runtime, value, operation, foundation.max_permission_mode, "modeは0〜0o7777の整数である必要があります");
}

fn accessModeArgument(runtime: *Runtime, value: Value, operation: []const u8) !u32 {
    return shared.unsignedArgument(runtime, value, operation, foundation.access_mode.all, "modeはF_OK/R_OK/W_OK/X_OKのビット和である必要があります");
}

/// chown/lchownのUID/GID引数。`-1` は「変更しない」を表す `null` へ写す。
fn idArgument(runtime: *Runtime, value: Value, operation: []const u8) !?u32 {
    var signed: i128 = undefined;
    switch (value.tag) {
        @intFromEnum(Tag.number) => {
            const number = valueToNumber(value);
            if (!foundation.isSafeInteger(number)) {
                return throwStructured(runtime, .EINVAL, operation, null, null, "UID/GIDは-1またはu32の整数である必要があります");
            }
            signed = @intFromFloat(number);
        },
        @intFromEnum(Tag.bigint) => {
            signed = value.object().?.payload.bigint.toI128() catch {
                return throwStructured(runtime, .EINVAL, operation, null, null, "UID/GIDは-1またはu32の整数である必要があります");
            };
        },
        else => return throwStructured(runtime, .EINVAL, operation, null, null, "UID/GIDは-1またはu32の整数である必要があります"),
    }
    if (signed == foundation.unchanged_id) return null;
    if (signed < 0 or signed > std.math.maxInt(u32)) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "UID/GIDは-1またはu32の整数である必要があります");
    }
    return @intCast(signed);
}

test "AOT低レイヤーのchmodはmodeを変更しaccessが権限を判定する" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
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
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "perm.txt", .data = "x" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "perm.txt" });
    defer std.testing.allocator.free(path);

    var roots = [_]Value{.{}};
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);
    roots[0] = try runtimeUtf8String(active, path);

    _ = try state.lowLevelPosixBuiltin(active, .low_level_file_chmod, &.{ roots[0], numberValue(0o600) });
    const stat_value = try state.lowLevelFileBuiltin(active, .low_level_file_stat, &.{roots[0]});
    try std.testing.expectEqual(@as(f64, 0o600), valueToNumber(dictionaryProperty(stat_value, &.{ 'm', 'o', 'd', 'e' })));

    const readable = try state.lowLevelPosixBuiltin(active, .low_level_file_access, &.{ roots[0], numberValue(foundation.access_mode.r_ok) });
    try std.testing.expectEqual(@intFromEnum(Tag.boolean), readable.tag);
    try std.testing.expect(readable.payload != 0);

    // 型不正はEINVAL。
    try std.testing.expectError(error.NakoException, state.lowLevelPosixBuiltin(active, .low_level_file_chmod, &.{ roots[0], staticStringValue("u+x") }));
    try expectPendingCode(active, "EINVAL");
}

test "AOT低レイヤーのUID/GID取得はnumberを返しumaskは旧値を返す" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    const uid = try state.lowLevelPosixBuiltin(active, .low_level_uid_get, &.{});
    try std.testing.expectEqual(@intFromEnum(Tag.number), uid.tag);
    try std.testing.expectEqual(@as(f64, @floatFromInt(std.c.getuid())), valueToNumber(uid));

    const groups = try state.lowLevelPosixBuiltin(active, .low_level_groups_get, &.{});
    try std.testing.expectEqual(@intFromEnum(Tag.array), groups.tag);

    const previous = try state.lowLevelPosixBuiltin(active, .low_level_umask_set, &.{numberValue(0o022)});
    defer _ = low_level_posix.umask(@intFromFloat(valueToNumber(previous))) catch {};
    try std.testing.expectEqual(@intFromEnum(Tag.number), previous.tag);
    const restored = try state.lowLevelPosixBuiltin(active, .low_level_umask_set, &.{previous});
    try std.testing.expectEqual(@as(f64, 0o022), valueToNumber(restored));
}

test "AOT低レイヤーPOSIX命令の引数境界はEINVALになる" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
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
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "bounds.txt", .data = "" });
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "bounds.txt" });
    defer std.testing.allocator.free(path);

    var roots = [_]Value{.{}};
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);
    roots[0] = try runtimeUtf8String(active, path);

    const expect_code = struct {
        fn callCheck(rt: *Runtime, command: aot_builtin.Command, args: []const Value, expected: []const u8) !void {
            try std.testing.expectError(error.NakoException, state.lowLevelPosixBuiltin(rt, command, args));
            try expectPendingCode(rt, expected);
        }
    }.callCheck;

    // mode境界: 0と0o7777は成功、0o10000・負数・非整数・bigintはEINVAL。
    _ = try state.lowLevelPosixBuiltin(active, .low_level_file_chmod, &.{ roots[0], numberValue(0) });
    _ = try state.lowLevelPosixBuiltin(active, .low_level_file_chmod, &.{ roots[0], numberValue(0o7777) });
    try expect_code(active, .low_level_file_chmod, &.{ roots[0], numberValue(0o10000) }, "EINVAL");
    try expect_code(active, .low_level_file_chmod, &.{ roots[0], numberValue(-1) }, "EINVAL");
    try expect_code(active, .low_level_file_chmod, &.{ roots[0], numberValue(1.5) }, "EINVAL");
    const big_mode = try active.ownBigInt(try BigInt.init(active.allocator, 0o10000));
    var big_roots = [_]Value{big_mode};
    var big_frame = RootFrame{};
    active.pushRoots(&big_frame, &big_roots, big_roots.len);
    defer active.popRoots(&big_frame);
    try expect_code(active, .low_level_file_chmod, &.{ roots[0], big_roots[0] }, "EINVAL");
    try expect_code(active, .low_level_file_chmod, &.{roots[0]}, "EINVAL");

    // access mode境界: 0と7は成功、8はEINVAL。
    _ = try state.lowLevelPosixBuiltin(active, .low_level_file_access, &.{ roots[0], numberValue(0) });
    _ = try state.lowLevelPosixBuiltin(active, .low_level_file_access, &.{ roots[0], numberValue(7) });
    try expect_code(active, .low_level_file_access, &.{ roots[0], numberValue(8) }, "EINVAL");

    // chownのUID/GID: -1は成功、-2・非整数はEINVAL。
    const own_gid = try low_level_posix.id(.gid);
    _ = try state.lowLevelPosixBuiltin(active, .low_level_file_chown, &.{ roots[0], numberValue(@floatFromInt(foundation.unchanged_id)), numberValue(@floatFromInt(own_gid)) });
    try expect_code(active, .low_level_file_chown, &.{ roots[0], numberValue(-2), numberValue(0) }, "EINVAL");
    try expect_code(active, .low_level_file_chown, &.{ roots[0], numberValue(0.5), numberValue(0) }, "EINVAL");

    // 0引数命令の余分な引数はEINVAL。
    try expect_code(active, .low_level_uid_get, &.{numberValue(0)}, "EINVAL");
}

test "AOT低レイヤーPOSIX命令はWindowsで照会false・実行ENOTSUPになる" {
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) return error.SkipZigTest;
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    const capability_name = staticStringValue("chmod");
    var roots = [_]Value{capability_name};
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);
    const supported = try state.lowLevelCapabilitySupportedBuiltin(active, roots[0..1]);
    try std.testing.expectEqual(@intFromEnum(Tag.boolean), supported.tag);
    try std.testing.expect(supported.payload == 0);

    try std.testing.expectError(error.NakoException, state.lowLevelPosixBuiltin(active, .low_level_uid_get, &.{}));
    try expectPendingCode(active, "ENOTSUP");
    try std.testing.expectError(error.NakoException, state.lowLevelPosixBuiltin(active, .low_level_umask_set, &.{numberValue(0o022)}));
    try expectPendingCode(active, "ENOTSUP");
}
