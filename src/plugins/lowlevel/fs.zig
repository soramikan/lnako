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

const throwStructured = shared.throwStructured;
const throwIo = shared.throwIo;
const publicSizeValue = shared.publicSizeValue;
const pathStringFromBytes = shared.pathStringFromBytes;

const captureThrow = shared.captureThrow;
const expectThrownCode = shared.expectThrownCode;
const expectThrownField = shared.expectThrownField;
const expectThrownPathPair = shared.expectThrownPathPair;

fn requirePath(runtime: *Runtime, effects: Effects, value: Value, operation: []const u8) ![]u8 {
    if (value != .string) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "pathは文字列である必要があります");
    }
    // lossy変換は孤立サロゲートをU+FFFDへ化けさせ、実在する同名ファイルへの
    // 誤操作につながるため、可逆なWTF-8変換を使う（AOTのpathArgumentと同じ規則）。
    return foundation.pathBytesFromUtf16(runtime.allocator(), value.string.units);
}

pub fn statPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value, follow: bool) !Value {
    _ = state;
    const operation = if (follow) foundation.filesystem_operations.stat else foundation.filesystem_operations.lstat;
    const capability: foundation.Capability = if (follow) .stat else .lstat;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const metadata = context.stat(path, follow) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, capability);
    };
    return statValue(runtime, metadata);
}

fn statValue(runtime: *Runtime, metadata: low_level_fs.Metadata) !Value {
    var dictionary = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.kind, try runtime.stringUtf8(metadata.kind.name()));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.size, try publicSizeValue(runtime, metadata.size));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.mode, .{ .number = @floatFromInt(metadata.mode) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.uid, .{ .number = @floatFromInt(metadata.uid) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.gid, .{ .number = @floatFromInt(metadata.gid) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.dev, .{ .number = @floatFromInt(metadata.dev) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.rdev, .{ .number = @floatFromInt(metadata.rdev) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.inode, .{ .number = @floatFromInt(metadata.inode) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.nlink, .{ .number = @floatFromInt(metadata.nlink) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.block_size, .{ .number = @floatFromInt(metadata.block_size) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.blocks, .{ .number = @floatFromInt(metadata.blocks) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.atime_ns, try timeValue(runtime, metadata.atime_ns));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.mtime_ns, try timeValue(runtime, metadata.mtime_ns));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.ctime_ns, try timeValue(runtime, metadata.ctime_ns));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.birthtime_ns, try timeValue(runtime, metadata.birthtime_ns));
    return dictionary;
}

fn timeValue(runtime: *Runtime, nanoseconds: foundation.OptionalTimeNs) !Value {
    const value = nanoseconds orelse return .null_value;
    return runtime.ownBigInt(try value_mod.BigInt.init(runtime.allocator(), value));
}

pub fn symlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.symlink;
    const target = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(target);
    const link = try requirePath(runtime, effects, common.argument(arguments, 1), operation);
    defer runtime.allocator().free(link);
    context.createSymlink(target, link) catch |failure| {
        return throwIo(runtime, effects, failure, operation, target, link, .symlink);
    };
    return .undefined;
}

pub fn readlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.readlink;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const destination = context.readlink(runtime.allocator(), path) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .readlink);
    };
    defer runtime.allocator().free(destination);
    return pathStringFromBytes(runtime, destination);
}

pub fn hardlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.hardlink;
    const target = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(target);
    const link = try requirePath(runtime, effects, common.argument(arguments, 1), operation);
    defer runtime.allocator().free(link);
    context.createHardLink(target, link) catch |failure| {
        return throwIo(runtime, effects, failure, operation, target, link, .hardlink);
    };
    return .undefined;
}

pub fn realpathPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.realpath;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const resolved = context.realpath(runtime.allocator(), path) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .realpath);
    };
    defer runtime.allocator().free(resolved);
    return pathStringFromBytes(runtime, resolved);
}

pub fn renamePath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.rename;
    const source = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(source);
    const destination = try requirePath(runtime, effects, common.argument(arguments, 1), operation);
    defer runtime.allocator().free(destination);
    context.rename(source, destination) catch |failure| {
        return throwIo(runtime, effects, failure, operation, source, destination, .rename);
    };
    return .undefined;
}

pub fn unlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.unlink;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    context.unlink(path) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .unlink);
    };
    return .undefined;
}

pub fn rmdirPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.rmdir;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    context.rmdir(path) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .rmdir);
    };
    return .undefined;
}

/// Issue #29のパス操作を実OSで検証するためのContext。InterpreterのHostと同じ
/// `low_level_fs` 実装を共有し、dispatchと値組み立てだけを単体で検査する。
const FsTestHost = struct {
    fn statCallback(_: *anyopaque, path: []const u8, follow: bool) anyerror!low_level_fs.Metadata {
        return low_level_fs.stat(std.testing.io, path, follow);
    }

    fn symlinkCallback(_: *anyopaque, target: []const u8, link: []const u8) anyerror!void {
        return low_level_fs.createSymlink(std.testing.io, target, link);
    }

    fn readlinkCallback(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        return low_level_fs.readlink(std.testing.io, allocator, path);
    }

    fn hardlinkCallback(_: *anyopaque, target: []const u8, link: []const u8) anyerror!void {
        return low_level_fs.createHardLink(std.testing.io, target, link);
    }

    fn realpathCallback(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
        return low_level_fs.realpath(std.testing.io, allocator, path);
    }

    fn renameCallback(_: *anyopaque, source: []const u8, destination: []const u8) anyerror!void {
        return low_level_fs.rename(std.testing.io, source, destination);
    }

    fn unlinkCallback(_: *anyopaque, path: []const u8) anyerror!void {
        return low_level_fs.unlink(std.testing.io, path);
    }

    fn rmdirCallback(_: *anyopaque, path: []const u8) anyerror!void {
        return low_level_fs.rmdir(std.testing.io, path);
    }

    fn context() Context {
        return .{ .fs = .{
            .context = emptyContext().fs.context,
            .statFn = statCallback,
            .symlinkFn = symlinkCallback,
            .readlinkFn = readlinkCallback,
            .hardlinkFn = hardlinkCallback,
            .realpathFn = realpathCallback,
            .renameFn = renameCallback,
            .unlinkFn = unlinkCallback,
            .rmdirFn = rmdirCallback,
        } };
    }
};

test "低レイヤーのstatはContext経由で辞書を返しcapabilityが有効になる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "plain.txt", .data = "hello" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path_bytes = try std.fs.path.join(std.testing.allocator, &.{ directory, "plain.txt" });
    defer std.testing.allocator.free(path_bytes);

    var path = try runtime.stringUtf8(path_bytes);
    try roots.protect(&path);
    const context = FsTestHost.context();

    var capability_name = try runtime.stringUtf8("stat");
    try roots.protect(&capability_name);
    const supported = (try call(&runtime, &state, context, effects, foundation.capability_supported_command, &.{capability_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and supported.boolean);

    var result = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{path})) orelse return error.TestExpectedEqual;
    try roots.protect(&result);
    const kind = node_shared.dictionaryGetAscii(result.dictionary, foundation.stat_field_keys.kind) orelse return error.TestExpectedEqual;
    const kind_text = try node_shared.valueUtf8(&runtime, kind);
    defer runtime.allocator().free(kind_text);
    try std.testing.expectEqualStrings("file", kind_text);
    const size = node_shared.dictionaryGetAscii(result.dictionary, foundation.stat_field_keys.size) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 5), size.number);
    const mtime = node_shared.dictionaryGetAscii(result.dictionary, foundation.stat_field_keys.mtime_ns) orelse return error.TestExpectedEqual;
    try std.testing.expect(mtime == .bigint);
    // カタログ typeSchemas.stat の全15フィールドが辞書に存在する。
    inline for (foundation.stat_field_key_list) |key| {
        try std.testing.expect(node_shared.dictionaryGetAscii(result.dictionary, key) != null);
    }

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{.{ .number = 1 }}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "低レイヤーのunlink/rmdirはContext経由でEISDIRとENOTEMPTYを返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    const context = FsTestHost.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "empty", .default_dir);
    try temporary.dir.createDir(std.testing.io, "full", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "full/child.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    const empty_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "empty" });
    defer std.testing.allocator.free(empty_path);
    const full_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "full" });
    defer std.testing.allocator.free(full_path);

    var empty_dir = try runtime.stringUtf8(empty_path);
    try roots.protect(&empty_dir);
    var full_dir = try runtime.stringUtf8(full_path);
    try roots.protect(&full_dir);

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルリンク削除", &.{empty_dir}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EISDIR");

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "空フォルダ削除", &.{full_dir}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOTEMPTY");

    _ = (try call(&runtime, &state, context, effects, "空フォルダ削除", &.{empty_dir})) orelse return error.TestExpectedEqual;
}

test "孤立サロゲートのパスはU+FFFD名へ置換されず別ファイルを削除しない" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    const context = FsTestHost.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // 置換文字U+FFFDという名前の実在ファイル。
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "\u{FFFD}", .data = "keep" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const replacement_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "\u{FFFD}" });
    defer std.testing.allocator.free(replacement_path);

    // "<dir>/<孤立サロゲート>" を作る。lossy変換だと"<dir>/�"になり実在ファイルを消す。
    const units = try std.testing.allocator.alloc(u16, directory.len + 2);
    defer std.testing.allocator.free(units);
    for (directory, 0..) |byte, index| units[index] = byte;
    units[directory.len] = '/';
    units[directory.len + 1] = 0xD800;
    var path = try runtime.stringCodeUnits(units);
    try roots.protect(&path);

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルリンク削除", &.{path}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOENT");
    // 失敗した元のパスを識別できる（孤立サロゲートを保持）。
    const error_path = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.path) orelse return error.TestExpectedEqual;
    try std.testing.expect(error_path == .string);
    try std.testing.expectEqualSlices(u16, units, error_path.string.units);

    // U+FFFD名のファイルは残っている。
    _ = try low_level_fs.stat(std.testing.io, replacement_path, true);
}

test "readlinkは孤立サロゲートを含むリンク先を可逆に返す" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    const context = FsTestHost.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const link_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "surrogate-link" });
    defer std.testing.allocator.free(link_path);

    // 孤立サロゲート1個だけをtargetにする（dangling）。
    var target = try runtime.stringCodeUnits(&[_]u16{0xD800});
    try roots.protect(&target);
    var link = try runtime.stringUtf8(link_path);
    try roots.protect(&link);

    _ = (try call(&runtime, &state, context, effects, "シンボリックリンク作成", &.{ target, link })) orelse return error.TestExpectedEqual;
    var destination = (try call(&runtime, &state, context, effects, "シンボリックリンク先取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&destination);
    try std.testing.expect(destination == .string);
    // lossy変換ならU+FFFDになるが、可逆変換では元の孤立サロゲートのまま。
    try std.testing.expectEqualSlices(u16, &[_]u16{0xD800}, destination.string.units);
}

test "低レイヤーのsymlink/lstat/hardlink/readlink/realpath/renameはContext経由で動作する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    const context = FsTestHost.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target.txt", .data = "abc" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    const target_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "target.txt" });
    defer std.testing.allocator.free(target_path);
    const link_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "link.txt" });
    defer std.testing.allocator.free(link_path);
    const hard_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "hard.txt" });
    defer std.testing.allocator.free(hard_path);
    const renamed_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "renamed.txt" });
    defer std.testing.allocator.free(renamed_path);

    var target = try runtime.stringUtf8(target_path);
    try roots.protect(&target);
    var link = try runtime.stringUtf8(link_path);
    try roots.protect(&link);
    var hard = try runtime.stringUtf8(hard_path);
    try roots.protect(&hard);
    var renamed = try runtime.stringUtf8(renamed_path);
    try roots.protect(&renamed);

    _ = (try call(&runtime, &state, context, effects, "シンボリックリンク作成", &.{ target, link })) orelse return error.TestExpectedEqual;

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "シンボリックリンク作成", &.{ target, link }));
    try roots.protect(&thrown);
    try expectThrownPathPair(&runtime, thrown, "EEXIST", "symlink", target_path, link_path);

    // lstatはsymlink自身、statは参照先を返す。
    var link_info = (try call(&runtime, &state, context, effects, "シンボリックリンク情報取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&link_info);
    const link_kind = node_shared.dictionaryGetAscii(link_info.dictionary, foundation.stat_field_keys.kind) orelse return error.TestExpectedEqual;
    const link_kind_text = try node_shared.valueUtf8(&runtime, link_kind);
    defer runtime.allocator().free(link_kind_text);
    try std.testing.expectEqualStrings("symlink", link_kind_text);

    var followed_info = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&followed_info);
    const followed_kind = node_shared.dictionaryGetAscii(followed_info.dictionary, foundation.stat_field_keys.kind) orelse return error.TestExpectedEqual;
    const followed_kind_text = try node_shared.valueUtf8(&runtime, followed_kind);
    defer runtime.allocator().free(followed_kind_text);
    try std.testing.expectEqualStrings("file", followed_kind_text);

    // ハードリンクは同一inode・nlink=2。
    _ = (try call(&runtime, &state, context, effects, "ハードリンク作成", &.{ target, hard })) orelse return error.TestExpectedEqual;
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハードリンク作成", &.{ target, hard }));
    try roots.protect(&thrown);
    try expectThrownPathPair(&runtime, thrown, "EEXIST", "link", target_path, hard_path);
    var hard_info = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{hard})) orelse return error.TestExpectedEqual;
    try roots.protect(&hard_info);
    const nlink = node_shared.dictionaryGetAscii(hard_info.dictionary, foundation.stat_field_keys.nlink) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 2), nlink.number);
    const hard_inode = node_shared.dictionaryGetAscii(hard_info.dictionary, foundation.stat_field_keys.inode) orelse return error.TestExpectedEqual;
    const target_inode = node_shared.dictionaryGetAscii(followed_info.dictionary, foundation.stat_field_keys.inode) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(target_inode.number, hard_inode.number);

    var destination = (try call(&runtime, &state, context, effects, "シンボリックリンク先取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&destination);
    const destination_text = try node_shared.valueUtf8(&runtime, destination);
    defer runtime.allocator().free(destination_text);
    try std.testing.expectEqualStrings(target_path, destination_text);

    // 非symlinkへのreadlinkはEINVAL。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "シンボリックリンク先取得", &.{target}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");

    var resolved = (try call(&runtime, &state, context, effects, "実体パス取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&resolved);
    const resolved_text = try node_shared.valueUtf8(&runtime, resolved);
    defer runtime.allocator().free(resolved_text);
    try std.testing.expectEqualStrings(target_path, resolved_text);

    _ = (try call(&runtime, &state, context, effects, "パス名変更", &.{ link, renamed })) orelse return error.TestExpectedEqual;
    _ = (try call(&runtime, &state, context, effects, "ファイルリンク削除", &.{renamed})) orelse return error.TestExpectedEqual;

    // symlinkループのstatはELOOPへ写る。
    try temporary.dir.symLink(std.testing.io, "loop", "loop", .{});
    const loop_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "loop" });
    defer std.testing.allocator.free(loop_path);
    var loop = try runtime.stringUtf8(loop_path);
    try roots.protect(&loop);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{loop}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ELOOP");
}
