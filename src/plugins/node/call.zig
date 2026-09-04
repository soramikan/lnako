const std = @import("std");
const constants = @import("../system/constants.zig");
const common = @import("../system/common.zig");
const crypto = @import("../crypto.zig");
const shared = @import("shared.zig");
const http = @import("http.zig");
const network = @import("network.zig");
const filesystem = @import("filesystem.zig");
const platform = @import("platform.zig");
const process = @import("process.zig");

pub fn install(runtime: *shared.Runtime, context: shared.Context, installer: constants.Installer) !void {
    var arguments = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&arguments);
    for (context.program_arguments) |argument| _ = try arguments.array.push(try runtime.stringUtf8(argument));
    try installer.set("コマンドライン", arguments);
    try installer.set("ナデシコランタイムパス", try runtime.stringUtf8(context.runtime_path));
    try installer.set("ナデシコランタイム", try runtime.stringUtf8(filesystem.nodeBasename(context.runtime_path)));
    const absolute_source = try filesystem.absolutePath(runtime.allocator(), context, context.source_path);
    defer runtime.allocator().free(absolute_source);
    try installer.set("母艦パス", try runtime.stringUtf8(filesystem.nodeDirname(absolute_source)));
    try installer.set("圧縮解凍ツールパス", try runtime.stringUtf8("7z"));
    try installer.set("ファイルコピーデフォルト動作", try runtime.stringUtf8("上書禁止"));
    try installer.set("AJAXオプション", try runtime.stringUtf8(""));
    try installer.set("AJAX:ONERROR", .null_value);
    if (context.home_directory) |home| {
        const desktop = try std.fs.path.join(runtime.allocator(), &.{ home, "Desktop" });
        defer runtime.allocator().free(desktop);
        try installer.set("デスクトップ", try runtime.stringUtf8(desktop));
        const documents = try std.fs.path.join(runtime.allocator(), &.{ home, "Documents" });
        defer runtime.allocator().free(documents);
        try installer.set("マイドキュメント", try runtime.stringUtf8(documents));
    } else {
        try installer.set("デスクトップ", .undefined);
        try installer.set("マイドキュメント", .undefined);
    }
    try installer.set("テンポラリフォルダ", try runtime.stringUtf8(context.temporary_directory));
}

pub fn call(runtime: *shared.Runtime, state: *shared.State, context: shared.Context, effects: ?shared.Effects, name: []const u8, arguments: []const shared.Value) !?shared.Value {
    const crypto_context: ?crypto.Context = if (context.randomBytesFn) |function| .{ .context = context.context, .randomBytesFn = function } else null;
    if (try crypto.call(runtime, crypto_context, name, arguments)) |value| return value;
    if (try http.callHttp(runtime, state, context, effects, name, arguments)) |value| return value;
    if (try network.callNetwork(runtime, context, name, arguments)) |value| return value;
    const source = common.argument(arguments, 0);
    if (try filesystem.callFilesystem(runtime, state, context, effects, name, arguments, source)) |value| return value;
    if (try platform.callPlatform(runtime, context, name, arguments, source)) |value| return value;
    if (try process.callProcess(runtime, state, context, effects, name, arguments, source)) |value| return value;
    return null;
}

pub fn pollOperations(runtime: *shared.Runtime, state: *shared.State, context: shared.Context, effects: shared.Effects) !bool {
    const poll = context.pollOperationFn orelse return false;
    var index: usize = 0;
    while (index < state.pending_operations.items.len) {
        const token = state.pending_operations.items[index].token;
        var result = (try poll(context.context, runtime.allocator(), token)) orelse {
            index += 1;
            continue;
        };
        defer result.deinit(runtime.allocator());
        var pending = state.pending_operations.orderedRemove(index);
        switch (pending.mode) {
            .command_output => if (result.exit_code == 0) {
                if (result.stdout.len > 0) {
                    try context.writeStdout(result.stdout);
                    try context.writeStdout("\n");
                }
            } else try context.writeStderr(result.stderr),
            .output_callback => {
                if (result.exit_code != 0) return error.CommandFailed;
                var roots = runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&pending.callback);
                var stdout = try runtime.stringUtf8Lossy(result.stdout);
                try roots.protect(&stdout);
                _ = try effects.invoke(pending.callback, &.{stdout});
            },
            .no_argument_callback => {
                if (result.exit_code != 0) return error.FileOperationFailed;
                var roots = runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&pending.callback);
                _ = try effects.invoke(pending.callback, &.{});
            },
            .http_callback => {
                if (result.exit_code != 0) {
                    const handler = effects.getGlobal("AJAX:ONERROR") orelse .null_value;
                    if (handler == .function) {
                        const reason = try runtime.stringUtf8Lossy(result.stderr);
                        _ = try effects.invoke(handler, &.{reason});
                        continue;
                    }
                    return error.HttpRequestFailed;
                }
                var roots = runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&pending.callback);
                var body = try runtime.stringUtf8Lossy(result.stdout);
                try roots.protect(&body);
                try effects.setGlobal("対象", body);
                _ = try effects.invoke(pending.callback, &.{body});
            },
            .http_set_target => {
                const status = result.http_status orelse 0;
                if (result.exit_code != 0 or status < 200 or status >= 300) {
                    try http.writeAjaxReceiveError(context, result);
                    continue;
                }
                const body = try runtime.stringUtf8Lossy(result.stdout);
                try effects.setGlobal("対象", body);
            },
            .http_promise => {
                if (pending.promise != .promise) return error.InvalidPendingPromise;
                const status = result.http_status orelse 0;
                if (result.exit_code != 0 or (pending.require_success and (status < 200 or status >= 300))) {
                    const reason = if (result.stderr.len > 0) try runtime.stringUtf8Lossy(result.stderr) else try runtime.stringUtf8("HTTP request failed");
                    try runtime.rejectPromise(pending.promise.promise, reason);
                    continue;
                }
                var value = if (pending.http_result == .response)
                    try http.httpResponseValue(runtime, result)
                else
                    try http.httpBodyValue(runtime, result.stdout, pending.http_result, status);
                var roots = runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&value);
                try runtime.resolvePromise(pending.promise.promise, value);
            },
        }
    }
    return state.pending_operations.items.len > 0;
}

test "Node互換のパス・OS・環境変数命令を処理する" {
    const TestHost = struct {
        fn cwd(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, "/work/project");
        }
    };
    var host = TestHost{};
    var runtime = shared.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = shared.State{};
    defer state.deinit(std.testing.allocator);
    const context = shared.Context{
        .context = &host,
        .cwdFn = TestHost.cwd,
        .environment_names = &.{"LNAKO_TEST"},
        .environment_values = &.{"ok"},
        .home_directory = "/home/test",
    };
    const file = (try call(&runtime, &state, context, null, "ファイル名抽出", &.{try runtime.stringUtf8("a/b.txt")})).?;
    const file_utf8 = try file.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(file_utf8);
    try std.testing.expectEqualStrings("b.txt", file_utf8);
    const env = (try call(&runtime, &state, context, null, "環境変数取得", &.{try runtime.stringUtf8("LNAKO_TEST")})).?;
    const env_utf8 = try env.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(env_utf8);
    try std.testing.expectEqualStrings("ok", env_utf8);
}

test "Nodeカレントディレクトリ変更は失敗時にchdir診断を保持する" {
    const TestHost = struct {
        fn cwd(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, "/work/project");
        }

        fn chdir(_: *anyopaque, _: []const u8) !void {
            return error.FileNotFound;
        }
    };
    var host = TestHost{};
    var runtime = shared.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = shared.State{};
    defer state.deinit(std.testing.allocator);
    var path = try runtime.stringUtf8("missing-日本語-7f4b");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&path);
    const context = shared.Context{ .context = &host, .cwdFn = TestHost.cwd, .chdirFn = TestHost.chdir };
    _ = call(&runtime, &state, context, null, "カレントディレクトリ変更", &.{path}) catch |failure| {
        try std.testing.expectEqual(error.FileNotFound, failure);
        try std.testing.expectEqualStrings(
            "ENOENT: no such file or directory, chdir '/work/project' -> 'missing-日本語-7f4b'",
            runtime.failureMessage().?,
        );
        runtime.clearFailureMessage();
        return;
    };
    return error.ExpectedFailure;
}

test "ブラウザとファイルマネージャーの起動をホストへ委譲する" {
    const TestHost = struct {
        calls: usize = 0,
        first_target: [128]u8 = undefined,
        first_target_length: usize = 0,
        first_reveal: bool = false,
        last_target: [128]u8 = undefined,
        last_target_length: usize = 0,
        last_reveal: bool = false,

        fn cwd(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, "/work");
        }

        fn open(context: *anyopaque, _: std.mem.Allocator, target: []const u8, reveal: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.calls == 0) {
                @memcpy(self.first_target[0..target.len], target);
                self.first_target_length = target.len;
                self.first_reveal = reveal;
            }
            @memcpy(self.last_target[0..target.len], target);
            self.last_target_length = target.len;
            self.last_reveal = reveal;
            self.calls += 1;
        }
    };
    var host = TestHost{};
    var runtime = shared.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = shared.State{};
    defer state.deinit(std.testing.allocator);
    const context = shared.Context{ .context = &host, .cwdFn = TestHost.cwd, .openExternalFn = TestHost.open };
    _ = try call(&runtime, &state, context, null, "ブラウザ起動", &.{try runtime.stringUtf8("https://example.invalid/")});
    _ = try call(&runtime, &state, context, null, "エクスプローラー起動", &.{try runtime.stringUtf8("file.txt")});
    try std.testing.expectEqual(@as(usize, 2), host.calls);
    try std.testing.expect(!host.first_reveal);
    try std.testing.expectEqualStrings("https://example.invalid/", host.first_target[0..host.first_target_length]);
    try std.testing.expect(host.last_reveal);
    try std.testing.expectEqualStrings("file.txt", host.last_target[0..host.last_target_length]);
}

test "一時フォルダの空指定はテンポラリパス自体を接頭辞にする" {
    const TestHost = struct {
        seen: [64]u8 = undefined,
        seen_length: usize = 0,

        fn cwd(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, "/work");
        }

        fn create(context: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            @memcpy(self.seen[0..prefix.len], prefix);
            self.seen_length = prefix.len;
            return std.fmt.allocPrint(allocator, "{s}ABC123", .{prefix});
        }
    };
    var host = TestHost{};
    var runtime = shared.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = shared.State{};
    defer state.deinit(std.testing.allocator);
    const context = shared.Context{
        .context = &host,
        .cwdFn = TestHost.cwd,
        .temporary_directory = "/tmp/lnako-test",
        .createTemporaryDirectoryFn = TestHost.create,
    };
    const empty = try runtime.stringUtf8("");
    const result = (try call(&runtime, &state, context, null, "一時フォルダ作成", &.{empty})).?;
    try std.testing.expectEqualStrings("/tmp/lnako-test", host.seen[0..host.seen_length]);
    const result_utf8 = try result.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(result_utf8);
    try std.testing.expectEqualStrings("/tmp/lnako-testABC123", result_utf8);
}
