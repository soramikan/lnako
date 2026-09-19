const std = @import("std");
const builtin = @import("builtin");
const state = @import("state.zig");
const shared = @import("low_level/shared.zig");
const stream = @import("low_level/stream.zig");
const stdio = @import("low_level/stdio.zig");
const hash = @import("low_level/hash.zig");
const fs = @import("low_level/fs.zig");
const process = @import("low_level/process.zig");
const foundation = @import("../low_level_foundation.zig");
const low_level_context = @import("../low_level/context.zig");

const aot_builtin = shared.aot_builtin;
const Runtime = shared.Runtime;
const Value = shared.Value;
const Tag = shared.Tag;
const RootFrame = shared.RootFrame;
const runtimeUtf8String = shared.runtimeUtf8String;
const throwStructured = shared.throwStructured;

pub fn pluginContext(runtime: *Runtime) low_level_context.Context {
    return .{
        .stream = .{
            .context = runtime,
            .openFileFn = stream.pluginOpenFile,
            .closeFileFn = stream.pluginCloseFile,
            .readFileBytesFn = stream.pluginReadFileBytes,
            .writeFileBytesFn = stream.pluginWriteFileBytes,
            .syncFileFn = stream.pluginSyncFile,
            .truncateFileFn = stream.pluginTruncateFile,
        },
        .hash = .{
            .context = runtime,
            .createHashFn = hash.pluginCreateHash,
            .updateHashFn = hash.pluginUpdateHash,
            .digestHashFn = hash.pluginDigestHash,
            .discardHashFn = hash.pluginDiscardHash,
        },
        .fs = .{
            .context = runtime,
            .statFn = fs.pluginStat,
            .symlinkFn = fs.pluginSymlink,
            .readlinkFn = fs.pluginReadlink,
            .hardlinkFn = fs.pluginHardlink,
            .realpathFn = fs.pluginRealpath,
            .renameFn = fs.pluginRename,
            .unlinkFn = fs.pluginUnlink,
            .rmdirFn = fs.pluginRmdir,
        },
        .stdio = .{
            .context = runtime,
            .peekStdinSourceFn = stdio.pluginPeekStdinSource,
            .stdinSourceFn = stdio.pluginStdinSource,
            .writeStdoutBytesFn = stdio.pluginWriteStdoutBytes,
            .writeStderrBytesFn = stdio.pluginWriteStderrBytes,
            .syncStdoutFn = stdio.pluginSyncStdout,
            .syncStderrFn = stdio.pluginSyncStderr,
        },
        .process = .{
            .context = runtime,
            .spawnFn = process.pluginSpawnProcess,
            .waitFn = process.pluginWaitProcess,
            .discardFn = process.pluginDiscardProcess,
            .getpidFn = process.pluginGetpid,
            .getppidFn = process.pluginGetppid,
            .signalFn = process.pluginSignal,
            .priorityGetFn = process.pluginPriorityGet,
            .prioritySetFn = process.pluginPrioritySet,
            .isattyFn = process.pluginIsatty,
            .ttySizeFn = process.pluginTtySize,
        },
    };
}

/// カタログ掲載済みで実装済みのincremental hash命令。arity検査は
/// `lowLevelFileBuiltin` と同じ契約（実装済み命令の下限未満はEINVAL）で行う。
pub fn lowLevelHashBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (aot_builtin.lowLevelCatalogCommand(command)) |spec| {
        if (arguments.len > spec.max) {
            return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
        if (spec.implemented and arguments.len < spec.min) {
            return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
    }
    return switch (command) {
        .low_level_hash_create => hash.hashCreateBuiltin(runtime, arguments),
        .low_level_hash_update => hash.hashUpdateBuiltin(runtime, arguments),
        .low_level_hash_digest => hash.hashDigestBuiltin(runtime, arguments),
        .low_level_hash_discard => hash.hashDiscardBuiltin(runtime, arguments),
        else => lowLevelUnsupportedBuiltin(runtime, command, arguments),
    };
}

pub fn lowLevelProcessBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (aot_builtin.lowLevelCatalogCommand(command)) |spec| {
        if (arguments.len > spec.max) {
            return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
        if (spec.implemented and arguments.len < spec.min) {
            return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
    }
    return switch (command) {
        .low_level_process_spawn => process.spawnBuiltin(runtime, arguments),
        .low_level_process_wait => process.waitBuiltin(runtime, arguments),
        .low_level_pid_get => process.pidGetBuiltin(runtime, arguments),
        .low_level_ppid_get => process.ppidGetBuiltin(runtime, arguments),
        .low_level_signal_send => process.signalSendBuiltin(runtime, arguments),
        .low_level_process_priority_get => process.priorityGetBuiltin(runtime, arguments),
        .low_level_process_priority_set => process.prioritySetBuiltin(runtime, arguments),
        .low_level_tty_isatty => process.ttyIsattyBuiltin(runtime, arguments),
        .low_level_tty_size => process.ttySizeBuiltin(runtime, arguments),
        else => lowLevelUnsupportedBuiltin(runtime, command, arguments),
    };
}

pub fn lowLevelFileBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (aot_builtin.lowLevelCatalogCommand(command)) |spec| {
        if (arguments.len > spec.max) {
            return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
        // 実装済み命令の引数不足は引数数エラー（Interpreterのcallと同じ契約）。
        // 未実装命令はENOTSUPが「未実装」の通知を兼ねるためmin未満もENOTSUP。
        if (spec.implemented and arguments.len < spec.min) {
            return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
    }
    return switch (command) {
        .low_level_file_open => stream.openBuiltin(runtime, arguments),
        .low_level_file_close => stream.closeBuiltin(runtime, arguments),
        .low_level_file_read_bytes => stream.readBytesBuiltin(runtime, arguments),
        .low_level_file_write_bytes => stream.writeBytesBuiltin(runtime, arguments),
        .low_level_file_sync => stream.syncBuiltin(runtime, arguments),
        .low_level_file_truncate => stream.truncateBuiltin(runtime, arguments),
        .low_level_file_stat => fs.statBuiltin(runtime, arguments, true),
        .low_level_file_lstat => fs.statBuiltin(runtime, arguments, false),
        .low_level_symlink_create => fs.symlinkBuiltin(runtime, arguments),
        .low_level_symlink_read => fs.readlinkBuiltin(runtime, arguments),
        .low_level_hardlink_create => fs.hardlinkBuiltin(runtime, arguments),
        .low_level_path_realpath => fs.realpathBuiltin(runtime, arguments),
        .low_level_path_rename => fs.renameBuiltin(runtime, arguments),
        .low_level_path_unlink => fs.unlinkBuiltin(runtime, arguments),
        .low_level_path_rmdir => fs.rmdirBuiltin(runtime, arguments),
        .low_level_stdin_read => stdio.stdinReadBuiltin(runtime, arguments),
        .low_level_stdout_write => stdio.stdioWriteBuiltin(runtime, arguments, false),
        .low_level_stderr_write => stdio.stdioWriteBuiltin(runtime, arguments, true),
        .low_level_stdout_sync => stdio.stdioSyncBuiltin(runtime, false),
        .low_level_stderr_sync => stdio.stdioSyncBuiltin(runtime, true),
        // dispatchは未実装命令を `lowLevelUnsupportedBuiltin` へ振り分けるため
        // 通常は到達しない。仮に到達しても構造化エラーの契約を維持する。
        else => lowLevelUnsupportedBuiltin(runtime, command, arguments),
    };
}

pub fn lowLevelCapabilitySupportedBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const spec = aot_builtin.lowLevelCatalogCommand(.low_level_capability_supported) orelse return error.UnknownCommand;
    // 実装済み命令の引数不足は引数数エラー（Interpreterのcallと同じ契約）。
    if (arguments.len > spec.max or arguments.len < spec.min) {
        return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
    }
    const supported = shared.capabilitySupported(arguments[0]);
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(supported) };
}

/// カタログ掲載済みだが未実装の低レイヤー命令。カタログ定義のarityを超える
/// 呼び出しはEINVAL、範囲内は `capability` と `operation` を持つ構造化
/// ENOTSUP を投げる（`aot_compiles_unsupported_calls`）。min未満の呼び出しも
/// ENOTSUP とする: 実装済み命令と異なりENOTSUPが「未実装」の通知を兼ねるため、
/// 引数不足をEINVALへ分けると呼び出し側が未実装と引数不正を区別できなくなる
/// （助詞呼出はコンパイル時のarity検査を通らず実行時へ到達する）。
pub fn lowLevelUnsupportedBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const spec = aot_builtin.lowLevelCatalogCommand(command) orelse return error.UnknownCommand;
    // 実装済み命令がここへ到達するのはdispatch caseの配置ずれなので、
    // 開発時に検出する（`plugins/lowlevel.zig` のフォールバックと同じ防御）。
    std.debug.assert(!spec.implemented);
    if (arguments.len > spec.max) {
        return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
    }
    const capability: ?[]const u8 = if (spec.capability) |cap| cap.id() else null;
    return throwStructured(runtime, .ENOTSUP, spec.operation, null, capability, "この低レイヤー命令はまだ実装されていません");
}

pub fn lowLevelCapabilityListBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len > 0) {
        return throwStructured(runtime, .EINVAL, "capability", null, null, "引数の数が不正です");
    }
    const result = try runtime.createArray(&.{});
    var rooted = [_]Value{ result, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);
    inline for (std.meta.tags(foundation.Capability)) |capability| {
        rooted[1] = try runtimeUtf8String(runtime, capability.id());
        try rooted[0].object().?.payload.array.append(runtime.allocator, rooted[1]);
    }
    return rooted[0];
}

test "AOT pluginContextはRuntimeのハンドル表へ開く" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "plugin-context.txt" });
    defer std.testing.allocator.free(path);

    const context = pluginContext(&runtime);
    const raw = try context.openFile(path, .write_create_truncate, false, false);
    try std.testing.expectEqual(@as(usize, 2), try context.writeFileBytes(raw, "ok"));
    try context.closeFile(raw);
    try std.testing.expectEqual(@as(usize, 0), runtime.low_level_handles.?.len());

    const output = try temporary.dir.readFileAlloc(std.testing.io, "plugin-context.txt", std.testing.allocator, .limited(8));
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, "ok", output);
}

/// 既存の `state.zig` / `dynamic.zig` 参照のため再輸出する。
pub const handleIdFor = shared.handleIdFor;
pub const handleValueForId = shared.handleValueForId;
pub const rememberHandle = shared.rememberHandle;
pub const forgetHandleId = shared.forgetHandleId;
pub const ensureAotStdinSource = stdio.ensureAotStdinSource;
pub const stdioStdinFile = stdio.stdioStdinFile;
pub const stdioStdoutFile = stdio.stdioStdoutFile;
pub const stdioStderrFile = stdio.stdioStderrFile;

test {
    _ = @import("low_level/shared.zig");
    _ = @import("low_level/stream.zig");
    _ = @import("low_level/stdio.zig");
    _ = @import("low_level/hash.zig");
    _ = @import("low_level/fs.zig");
    _ = @import("low_level/process.zig");
}
