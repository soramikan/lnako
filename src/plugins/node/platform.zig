const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared.zig");
const fs = @import("filesystem.zig");

const Value = shared.Value;
const Runtime = shared.Runtime;
const Context = shared.Context;
const valueUtf8 = shared.valueUtf8;
const nodeFilesystemPath = shared.nodeFilesystemPath;
const setNodeChangeDirectoryFailure = shared.setNodeChangeDirectoryFailure;

pub fn callPlatform(runtime: *Runtime, context: Context, name: []const u8, arguments: []const Value, source: Value) !?Value {
    _ = arguments;
    if (std.mem.eql(u8, name, "OS取得")) return @as(?Value, try runtime.stringUtf8(osName()));
    if (std.mem.eql(u8, name, "OSアーキテクチャ取得")) return @as(?Value, try runtime.stringUtf8(architectureName()));
    if (std.mem.eql(u8, name, "カレントディレクトリ取得") or std.mem.eql(u8, name, "作業フォルダ取得")) {
        const cwd = try context.cwd(runtime.allocator());
        defer runtime.allocator().free(cwd);
        return @as(?Value, try runtime.stringUtf8(cwd));
    }
    if (std.mem.eql(u8, name, "カレントディレクトリ変更") or std.mem.eql(u8, name, "作業フォルダ変更")) {
        const path = try nodeFilesystemPath(runtime, source);
        defer runtime.allocator().free(path);
        context.chdir(path) catch |failure| {
            setNodeChangeDirectoryFailure(runtime, context, path, failure) catch {};
            return failure;
        };
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "ホームディレクトリ取得")) return @as(?Value, if (context.home_directory) |home| try runtime.stringUtf8(home) else .undefined);
    if (std.mem.eql(u8, name, "デスクトップ")) return joinHome(runtime, context.home_directory, "Desktop");
    if (std.mem.eql(u8, name, "マイドキュメント")) return joinHome(runtime, context.home_directory, "Documents");
    if (std.mem.eql(u8, name, "母艦パス取得")) {
        const absolute_source = try fs.absolutePath(runtime.allocator(), context, context.source_path);
        defer runtime.allocator().free(absolute_source);
        return @as(?Value, try runtime.stringUtf8(fs.nodeDirname(absolute_source)));
    }
    if (std.mem.eql(u8, name, "テンポラリフォルダ")) return @as(?Value, try runtime.stringUtf8(context.temporary_directory));
    if (std.mem.eql(u8, name, "環境変数取得")) {
        const key = try valueUtf8(runtime, source);
        defer runtime.allocator().free(key);
        return @as(?Value, if (context.environment(key)) |value| try runtime.stringUtf8(value) else .undefined);
    }
    if (std.mem.eql(u8, name, "環境変数一覧取得")) {
        var result = try runtime.createDictionary();
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        for (context.environment_names, context.environment_values) |key, value| {
            var key_value = try runtime.stringUtf8(key);
            try roots.protect(&key_value);
            try result.dictionary.set(key_value.string, try runtime.stringUtf8(value));
        }
        return @as(?Value, result);
    }
    if (std.mem.eql(u8, name, "ブラウザ起動") or std.mem.eql(u8, name, "エクスプローラー起動")) {
        const target = try valueUtf8(runtime, source);
        defer runtime.allocator().free(target);
        const function = context.openExternalFn orelse return error.OpenExternalUnavailable;
        try function(context.context, runtime.allocator(), target, std.mem.eql(u8, name, "エクスプローラー起動"));
        return @as(?Value, .undefined);
    }
    return null;
}

pub fn joinHome(runtime: *Runtime, home: ?[]const u8, child: []const u8) !?Value {
    const base = home orelse return @as(?Value, .undefined);
    const path = try std.fs.path.join(runtime.allocator(), &.{ base, child });
    defer runtime.allocator().free(path);
    return @as(?Value, try runtime.stringUtf8(path));
}

pub fn osName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        .linux => "linux",
        else => @tagName(builtin.os.tag),
    };
}

pub fn architectureName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        .x86 => "ia32",
        else => @tagName(builtin.cpu.arch),
    };
}
