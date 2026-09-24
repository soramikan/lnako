const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../../runtime/value.zig");
const foundation = @import("../../runtime/low_level_foundation.zig");
const low_level_posix = @import("../../runtime/low_level_posix.zig");
const low_level_fs = @import("../../runtime/low_level_fs.zig");
const low_level_context = @import("../../runtime/low_level/context.zig");
const common = @import("../system/common.zig");
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

const throwStructured = shared.throwStructured;
const throwIo = shared.throwIo;
const requirePath = shared.pathArgument;

const captureThrow = shared.captureThrow;
const expectThrownCode = shared.expectThrownCode;

pub fn chmodPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.posix_operations.chmod;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const mode = try permissionModeArgument(runtime, effects, common.argument(arguments, 1), operation);
    context.chmod(path, mode) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .chmod);
    };
    return .undefined;
}

pub fn chownPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value, follow: bool) !Value {
    _ = state;
    const operation = if (follow) foundation.posix_operations.chown else foundation.posix_operations.lchown;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const uid = try idArgument(runtime, effects, common.argument(arguments, 1), operation);
    const gid = try idArgument(runtime, effects, common.argument(arguments, 2), operation);
    context.chown(path, uid, gid, follow) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .chown);
    };
    return .undefined;
}

pub fn accessPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.posix_operations.access;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const mode = try accessModeArgument(runtime, effects, common.argument(arguments, 1), operation);
    const allowed = context.access(path, mode) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .access);
    };
    return .{ .boolean = allowed };
}

pub fn idPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value, kind: low_level_posix.IdKind) !Value {
    _ = state;
    _ = arguments;
    const operation = operationForId(kind);
    const result = context.id(kind) catch |failure| {
        return throwIo(runtime, effects, failure, operation, null, null, .uid_gid);
    };
    return .{ .number = @floatFromInt(result) };
}

pub fn groupsPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    _ = arguments;
    const operation = foundation.posix_operations.groups;
    const list = context.groups(runtime.allocator()) catch |failure| {
        return throwIo(runtime, effects, failure, operation, null, null, .uid_gid);
    };
    defer runtime.allocator().free(list);
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (list) |group| {
        _ = try result.array.push(.{ .number = @floatFromInt(group) });
    }
    return result;
}

pub fn umaskPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.posix_operations.umask;
    const mode = try permissionModeArgument(runtime, effects, common.argument(arguments, 0), operation);
    const previous = context.umask(mode) catch |failure| {
        return throwIo(runtime, effects, failure, operation, null, null, .uid_gid);
    };
    return .{ .number = @floatFromInt(previous) };
}

fn operationForId(kind: low_level_posix.IdKind) []const u8 {
    return switch (kind) {
        .uid => foundation.posix_operations.uid,
        .euid => foundation.posix_operations.euid,
        .gid => foundation.posix_operations.gid,
        .egid => foundation.posix_operations.egid,
    };
}

fn permissionModeArgument(runtime: *Runtime, effects: Effects, value: Value, operation: []const u8) !u32 {
    return shared.unsignedArgument(runtime, effects, value, operation, foundation.max_permission_mode, "modeは0〜0o7777の整数である必要があります");
}

fn accessModeArgument(runtime: *Runtime, effects: Effects, value: Value, operation: []const u8) !u32 {
    return shared.unsignedArgument(runtime, effects, value, operation, foundation.access_mode.all, "modeはF_OK/R_OK/W_OK/X_OKのビット和である必要があります");
}

/// chown/lchownのUID/GID引数。`-1` は「変更しない」を表す `null` へ写す。
fn idArgument(runtime: *Runtime, effects: Effects, value: Value, operation: []const u8) !?u32 {
    const message = "UID/GIDは-1またはu32の整数である必要があります";
    const signed: i128 = switch (value) {
        .number => |number| blk: {
            if (!foundation.isSafeInteger(number)) {
                return throwStructured(runtime, effects, .EINVAL, operation, null, null, message);
            }
            break :blk @intFromFloat(number);
        },
        .bigint => |bigint| bigint.toI128() catch {
            return throwStructured(runtime, effects, .EINVAL, operation, null, null, message);
        },
        else => return throwStructured(runtime, effects, .EINVAL, operation, null, null, message),
    };
    if (signed == foundation.unchanged_id) return null;
    if (signed < 0 or signed > std.math.maxInt(u32)) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, message);
    }
    return @intCast(signed);
}

/// Issue #34のPOSIX命令を実OSで検証するためのContext。InterpreterのHostと同じ
/// `low_level_posix` 実装を共有し、dispatchと値組み立てだけを単体で検査する。
const PosixTestHost = struct {
    fn chmodCallback(_: *anyopaque, path: []const u8, mode: u32) anyerror!void {
        return low_level_posix.chmod(path, mode);
    }

    fn chownCallback(_: *anyopaque, path: []const u8, uid: ?u32, gid: ?u32, follow: bool) anyerror!void {
        return low_level_posix.chown(path, uid, gid, follow);
    }

    fn accessCallback(_: *anyopaque, path: []const u8, mode: u32) anyerror!bool {
        return low_level_posix.access(path, mode);
    }

    fn idCallback(_: *anyopaque, kind: low_level_posix.IdKind) anyerror!u32 {
        return low_level_posix.id(kind);
    }

    fn groupsCallback(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u32 {
        return low_level_posix.groups(allocator);
    }

    fn umaskCallback(_: *anyopaque, mode: u32) anyerror!u32 {
        return low_level_posix.umask(mode);
    }

    fn context() Context {
        return .{ .posix = .{
            .context = emptyContext().posix.context,
            .chmodFn = chmodCallback,
            .chownFn = chownCallback,
            .accessFn = accessCallback,
            .idFn = idCallback,
            .groupsFn = groupsCallback,
            .umaskFn = umaskCallback,
        } };
    }
};

test "低レイヤーのchmod/access/uid_gidはContext経由で動作する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    const context = PosixTestHost.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "perm.txt", .data = "x" });
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "perm.txt" });
    defer std.testing.allocator.free(path);

    var path_value = try runtime.stringUtf8(path);
    try roots.protect(&path_value);

    var capability_name = try runtime.stringUtf8("chmod");
    try roots.protect(&capability_name);
    const supported = (try call(&runtime, &state, context, effects, foundation.capability_supported_command, &.{capability_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and supported.boolean);

    _ = (try call(&runtime, &state, context, effects, foundation.posix_commands.chmod, &.{ path_value, .{ .number = 0o600 } })) orelse return error.TestExpectedEqual;
    const metadata = try low_level_fs.stat(std.testing.io, path, true);
    try std.testing.expectEqual(@as(u32, 0o600), metadata.mode & 0o777);

    var access_value = (try call(&runtime, &state, context, effects, foundation.posix_commands.access, &.{ path_value, .{ .number = foundation.access_mode.r_ok } })) orelse return error.TestExpectedEqual;
    try std.testing.expect(access_value == .boolean and access_value.boolean);
    // root（euid=0）は実行ビット無しでもaccess(X_OK)が成功し得るため検証しない。
    if (std.c.geteuid() != 0) {
        access_value = (try call(&runtime, &state, context, effects, foundation.posix_commands.access, &.{ path_value, .{ .number = foundation.access_mode.x_ok } })) orelse return error.TestExpectedEqual;
        try std.testing.expect(access_value == .boolean and !access_value.boolean);
    }

    var uid_value = (try call(&runtime, &state, context, effects, foundation.posix_commands.uid, &.{})) orelse return error.TestExpectedEqual;
    try roots.protect(&uid_value);
    try std.testing.expectEqual(@as(f64, @floatFromInt(std.c.getuid())), uid_value.number);

    var groups_value = (try call(&runtime, &state, context, effects, foundation.posix_commands.groups, &.{})) orelse return error.TestExpectedEqual;
    try roots.protect(&groups_value);
    try std.testing.expect(groups_value == .array);

    // 型不正（symbolic mode文字列）はEINVAL。
    var symbolic_mode = try runtime.stringUtf8("u+x");
    try roots.protect(&symbolic_mode);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, foundation.posix_commands.chmod, &.{ path_value, symbolic_mode }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "低レイヤーPOSIX命令の引数境界はInterpreterでEINVALになる" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    const context = PosixTestHost.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "bounds.txt", .data = "" });
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "bounds.txt" });
    defer std.testing.allocator.free(path);
    var path_value = try runtime.stringUtf8(path);
    try roots.protect(&path_value);

    const expect_code = struct {
        fn callCheck(rt: *Runtime, st: *State, ctx: Context, eff: Effects, thrown_ref: *Value, name: []const u8, args: []const Value, expected: []const u8) !void {
            thrown_ref.* = .undefined;
            try std.testing.expectError(error.NakoException, call(rt, st, ctx, eff, name, args));
            try expectThrownCode(rt, thrown_ref.*, expected);
        }
    }.callCheck;

    // modeの境界: 0と0o7777は成功、範囲外・非整数・文字列はEINVAL。
    _ = (try call(&runtime, &state, context, effects, foundation.posix_commands.chmod, &.{ path_value, .{ .number = 0 } })) orelse return error.TestExpectedEqual;
    _ = (try call(&runtime, &state, context, effects, foundation.posix_commands.chmod, &.{ path_value, .{ .number = 0o7777 } })) orelse return error.TestExpectedEqual;
    try expect_code(&runtime, &state, context, effects, &thrown, foundation.posix_commands.chmod, &.{ path_value, .{ .number = 0o10000 } }, "EINVAL");
    try expect_code(&runtime, &state, context, effects, &thrown, foundation.posix_commands.chmod, &.{ path_value, .{ .number = -1 } }, "EINVAL");
    try expect_code(&runtime, &state, context, effects, &thrown, foundation.posix_commands.chmod, &.{ path_value, .{ .number = 1.5 } }, "EINVAL");
    var big_mode = try runtime.ownBigInt(try value_mod.BigInt.init(runtime.allocator(), 0o10000));
    try roots.protect(&big_mode);
    try expect_code(&runtime, &state, context, effects, &thrown, foundation.posix_commands.chmod, &.{ path_value, big_mode }, "EINVAL");
    // 引数不足はEINVAL。
    try expect_code(&runtime, &state, context, effects, &thrown, foundation.posix_commands.chmod, &.{path_value}, "EINVAL");

    // accessのmode境界: 0と7は成功、8はEINVAL。
    _ = (try call(&runtime, &state, context, effects, foundation.posix_commands.access, &.{ path_value, .{ .number = 0 } })) orelse return error.TestExpectedEqual;
    _ = (try call(&runtime, &state, context, effects, foundation.posix_commands.access, &.{ path_value, .{ .number = 7 } })) orelse return error.TestExpectedEqual;
    try expect_code(&runtime, &state, context, effects, &thrown, foundation.posix_commands.access, &.{ path_value, .{ .number = 8 } }, "EINVAL");

    // chownのUID/GID: -1とu32最大は成功、負の-2や非整数はEINVAL。
    const own_uid = try low_level_posix.id(.uid);
    const own_gid = try low_level_posix.id(.gid);
    _ = (try call(&runtime, &state, context, effects, foundation.posix_commands.chown, &.{ path_value, .{ .number = @floatFromInt(foundation.unchanged_id) }, .{ .number = @floatFromInt(own_gid) } })) orelse return error.TestExpectedEqual;
    _ = (try call(&runtime, &state, context, effects, foundation.posix_commands.chown, &.{ path_value, .{ .number = @floatFromInt(own_uid) }, .{ .number = @floatFromInt(foundation.unchanged_id) } })) orelse return error.TestExpectedEqual;
    try expect_code(&runtime, &state, context, effects, &thrown, foundation.posix_commands.chown, &.{ path_value, .{ .number = -2 }, .{ .number = 0 } }, "EINVAL");
    try expect_code(&runtime, &state, context, effects, &thrown, foundation.posix_commands.chown, &.{ path_value, .{ .number = 0.5 }, .{ .number = 0 } }, "EINVAL");

    // 0引数命令の余分な引数はEINVAL。
    try expect_code(&runtime, &state, context, effects, &thrown, foundation.posix_commands.uid, &.{.{ .number = 0 }}, "EINVAL");
}

test "低レイヤーPOSIX命令はWindowsで照会false・実行ENOTSUPになる" {
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    const context = PosixTestHost.context();

    var capability_name = try runtime.stringUtf8("chmod");
    try roots.protect(&capability_name);
    const supported = (try call(&runtime, &state, context, effects, foundation.capability_supported_command, &.{capability_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and !supported.boolean);

    var path_value = try runtime.stringUtf8("whatever");
    try roots.protect(&path_value);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, foundation.posix_commands.chmod, &.{ path_value, .{ .number = 0o644 } }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOTSUP");
}

test "低レイヤーのchown/lchown/umaskはContext経由で動作する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    const context = PosixTestHost.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "owner.txt", .data = "" });
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "owner.txt" });
    defer std.testing.allocator.free(path);
    var path_value = try runtime.stringUtf8(path);
    try roots.protect(&path_value);

    const own_uid = std.c.getuid();
    const own_gid = std.c.getgid();
    _ = (try call(&runtime, &state, context, effects, foundation.posix_commands.chown, &.{ path_value, .{ .number = @floatFromInt(own_uid) }, .{ .number = @floatFromInt(own_gid) } })) orelse return error.TestExpectedEqual;
    _ = (try call(&runtime, &state, context, effects, foundation.posix_commands.lchown, &.{ path_value, .{ .number = @floatFromInt(foundation.unchanged_id) }, .{ .number = @floatFromInt(own_gid) } })) orelse return error.TestExpectedEqual;

    // 未解決symlinkで follow の配線を検証する: chown は参照先を解決してENOENT、
    // lchown はリンク自身を対象にして成功する。
    try temporary.dir.symLink(std.testing.io, "dangling-target", "dangling", .{});
    const dangling = try std.fs.path.join(std.testing.allocator, &.{ directory, "dangling" });
    defer std.testing.allocator.free(dangling);
    var dangling_value = try runtime.stringUtf8(dangling);
    try roots.protect(&dangling_value);
    const own_uid_value: Value = .{ .number = @floatFromInt(own_uid) };
    const own_gid_value: Value = .{ .number = @floatFromInt(own_gid) };
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, foundation.posix_commands.chown, &.{ dangling_value, own_uid_value, own_gid_value }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOENT");
    _ = (try call(&runtime, &state, context, effects, foundation.posix_commands.lchown, &.{ dangling_value, own_uid_value, own_gid_value })) orelse return error.TestExpectedEqual;

    const previous = (try call(&runtime, &state, context, effects, foundation.posix_commands.umask, &.{.{ .number = 0o022 }})) orelse return error.TestExpectedEqual;
    defer _ = low_level_posix.umask(@intFromFloat(previous.number)) catch {};
    try std.testing.expect(previous == .number);
    const restored = (try call(&runtime, &state, context, effects, foundation.posix_commands.umask, &.{previous})) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 0o022), restored.number);
}
