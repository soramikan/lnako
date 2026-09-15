const std = @import("std");
const builtin = @import("builtin");
const foundation = @import("low_level_foundation.zig");
const string_mod = @import("string.zig");

pub const PortableErrorCode = foundation.PortableErrorCode;
pub const Capability = foundation.Capability;
pub const OsKind = foundation.OsKind;
pub const error_object_keys = foundation.error_object_keys;
pub const cnako_error_keys = foundation.cnako_error_keys;

pub const StructuredError = struct {
    code: PortableErrorCode,
    nativeCode: ?i32 = null,
    operation: ?[]const u8 = null,
    path: ?[]const u8 = null,
    path2: ?[]const u8 = null,
    capability: ?Capability = null,
};

pub fn nativeCodeFromErrno(errno: std.posix.E) i32 {
    return @intFromEnum(errno);
}

pub fn portableCodeFromErrno(errno: std.posix.E) ?PortableErrorCode {
    return switch (errno) {
        .NOENT => .ENOENT,
        .ACCES => .EACCES,
        .PERM => .EPERM,
        .EXIST => .EEXIST,
        .NOTDIR => .ENOTDIR,
        .ISDIR => .EISDIR,
        .NOTEMPTY => .ENOTEMPTY,
        .XDEV => .EXDEV,
        .LOOP => .ELOOP,
        .ROFS => .EROFS,
        .NOSPC => .ENOSPC,
        .MFILE => .EMFILE,
        .NFILE => .ENFILE,
        .INVAL => .EINVAL,
        .PIPE => .EPIPE,
        .BADF => .EBADF,
        .OPNOTSUPP => .ENOTSUP,
        else => portableCodeFromErrnoTail(errno),
    };
}

fn portableCodeFromErrnoTail(errno: std.posix.E) ?PortableErrorCode {
    if (comptime @hasField(std.posix.E, "NOTSUP")) {
        if (errno == .NOTSUP) return .ENOTSUP;
    }
    return null;
}

pub fn portableCodeFromFailure(failure: anyerror) ?PortableErrorCode {
    return switch (failure) {
        error.FileNotFound => .ENOENT,
        error.AccessDenied => .EACCES,
        error.PermissionDenied => .EPERM,
        error.PathAlreadyExists => .EEXIST,
        error.NotDir => .ENOTDIR,
        error.IsDir => .EISDIR,
        error.DirNotEmpty => .ENOTEMPTY,
        error.CrossDevice => .EXDEV,
        error.SymLinkLoop => .ELOOP,
        error.ReadOnlyFileSystem => .EROFS,
        error.NoSpaceLeft => .ENOSPC,
        error.ProcessFdQuotaExceeded => .EMFILE,
        error.SystemFdQuotaExceeded => .ENFILE,
        error.BadPathName, error.InvalidWtf8, error.InvalidArgument => .EINVAL,
        error.BrokenPipe => .EPIPE,
        error.BadFileDescriptor => .EBADF,
        error.Unsupported, error.OperationUnsupported, error.NotSupported => .ENOTSUP,
        error.InvalidOffset, error.InvalidSize, error.InvalidTimestamp => .EINVAL,
        else => null,
    };
}

pub fn classifyNative(
    errno: std.posix.E,
    operation: ?[]const u8,
    path: ?[]const u8,
    path2: ?[]const u8,
    capability: ?Capability,
) ?StructuredError {
    const code = portableCodeFromErrno(errno) orelse return null;
    return .{
        .code = code,
        .nativeCode = nativeCodeFromErrno(errno),
        .operation = operation,
        .path = path,
        .path2 = path2,
        .capability = capability,
    };
}

pub fn classifyFailure(
    failure: anyerror,
    operation: ?[]const u8,
    path: ?[]const u8,
    path2: ?[]const u8,
    capability: ?Capability,
) ?StructuredError {
    const code = portableCodeFromFailure(failure) orelse return null;
    return .{
        .code = code,
        .nativeCode = null,
        .operation = operation,
        .path = path,
        .path2 = path2,
        .capability = capability,
    };
}

pub fn descriptionFor(code: PortableErrorCode) []const u8 {
    return switch (code) {
        .ENOENT => "no such file or directory",
        .EACCES => "permission denied",
        .EPERM => "operation not permitted",
        .EEXIST => "file already exists",
        .ENOTDIR => "not a directory",
        .EISDIR => "illegal operation on a directory",
        .ENOTEMPTY => "directory not empty",
        .EXDEV => "cross-device link not permitted",
        .ELOOP => "too many levels of symbolic links",
        .EROFS => "read-only file system",
        .ENOSPC => "no space left on device",
        .EMFILE => "too many open files",
        .ENFILE => "too many open files in system",
        .EINVAL => "invalid argument",
        .EPIPE => "broken pipe",
        .EBADF => "bad file descriptor",
        .ENOTSUP => "operation not supported",
    };
}

pub fn displayPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (comptime builtin.os.tag == .windows) {
        if (std.unicode.wtf8ToUtf8LossyAlloc(allocator, path)) |display| return display else |_| {}
    }
    var text = try string_mod.String.fromUtf8Lossy(allocator, path);
    defer text.deinit();
    return text.toUtf8Lossy(allocator);
}

pub fn formatMessage(
    allocator: std.mem.Allocator,
    code: PortableErrorCode,
    operation: ?[]const u8,
    path: ?[]const u8,
    path2: ?[]const u8,
) ![]u8 {
    const description = descriptionFor(code);
    const code_name = code.name();
    const has_operation = operation != null;
    const has_path = path != null;
    const has_path2 = path2 != null;
    if (!has_operation and !has_path and !has_path2) {
        return std.fmt.allocPrint(allocator, "{s}: {s}", .{ code_name, description });
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}: {s}{s}{s}{s}{s}{s}{s}{s}{s}{s}",
        .{
            code_name,
            description,
            if (has_operation or has_path or has_path2) ", " else "",
            operation orelse "",
            if (has_operation and (has_path or has_path2)) " " else "",
            if (has_path) "'" else "",
            path orelse "",
            if (has_path) "'" else "",
            if (has_path2) " -> '" else "",
            path2 orelse "",
            if (has_path2) "'" else "",
        },
    );
}

pub const NativeEntry = struct {
    code: PortableErrorCode,
    native: i32,
};

pub const native_linux = [_]NativeEntry{
    .{ .code = .ENOENT, .native = 2 },
    .{ .code = .EACCES, .native = 13 },
    .{ .code = .EPERM, .native = 1 },
    .{ .code = .EEXIST, .native = 17 },
    .{ .code = .ENOTDIR, .native = 20 },
    .{ .code = .EISDIR, .native = 21 },
    .{ .code = .ENOTEMPTY, .native = 39 },
    .{ .code = .EXDEV, .native = 18 },
    .{ .code = .ELOOP, .native = 40 },
    .{ .code = .EROFS, .native = 30 },
    .{ .code = .ENOSPC, .native = 28 },
    .{ .code = .EMFILE, .native = 24 },
    .{ .code = .ENFILE, .native = 23 },
    .{ .code = .EINVAL, .native = 22 },
    .{ .code = .EPIPE, .native = 32 },
    .{ .code = .EBADF, .native = 9 },
    .{ .code = .ENOTSUP, .native = 95 },
};

pub const native_macos = [_]NativeEntry{
    .{ .code = .ENOENT, .native = 2 },
    .{ .code = .EACCES, .native = 13 },
    .{ .code = .EPERM, .native = 1 },
    .{ .code = .EEXIST, .native = 17 },
    .{ .code = .ENOTDIR, .native = 20 },
    .{ .code = .EISDIR, .native = 21 },
    .{ .code = .ENOTEMPTY, .native = 66 },
    .{ .code = .EXDEV, .native = 18 },
    .{ .code = .ELOOP, .native = 62 },
    .{ .code = .EROFS, .native = 30 },
    .{ .code = .ENOSPC, .native = 28 },
    .{ .code = .EMFILE, .native = 24 },
    .{ .code = .ENFILE, .native = 23 },
    .{ .code = .EINVAL, .native = 22 },
    .{ .code = .EPIPE, .native = 32 },
    .{ .code = .EBADF, .native = 9 },
    .{ .code = .ENOTSUP, .native = 45 },
};

pub const native_windows = [_]NativeEntry{
    .{ .code = .ENOENT, .native = 2 },
    .{ .code = .EACCES, .native = 13 },
    .{ .code = .EPERM, .native = 1 },
    .{ .code = .EEXIST, .native = 17 },
    .{ .code = .ENOTDIR, .native = 20 },
    .{ .code = .EISDIR, .native = 21 },
    .{ .code = .ENOTEMPTY, .native = 41 },
    .{ .code = .EXDEV, .native = 18 },
    .{ .code = .ELOOP, .native = 114 },
    .{ .code = .EROFS, .native = 30 },
    .{ .code = .ENOSPC, .native = 28 },
    .{ .code = .EMFILE, .native = 24 },
    .{ .code = .ENFILE, .native = 23 },
    .{ .code = .EINVAL, .native = 22 },
    .{ .code = .EPIPE, .native = 32 },
    .{ .code = .EBADF, .native = 9 },
    .{ .code = .ENOTSUP, .native = 130 },
};

/// WindowsはENOTSUPを`NOTSUP`(129)と`OPNOTSUPP`(130)の2値で表す。
/// 正本tableは130とし、129は別名として同一portable codeへ写す。
pub const native_windows_aliases = [_]NativeEntry{
    .{ .code = .ENOTSUP, .native = 129 },
};

pub fn currentOs() OsKind {
    return switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        .windows => .windows,
        else => @compileError("unsupported os"),
    };
}

pub fn nativeCodeFromPortable(os: OsKind, code: PortableErrorCode) ?i32 {
    const table: []const NativeEntry = switch (os) {
        .linux => &native_linux,
        .macos => &native_macos,
        .windows => &native_windows,
    };
    for (table) |entry| {
        if (entry.code == code) return entry.native;
    }
    return null;
}

pub fn portableCodeFromNative(os: OsKind, native: i32) ?PortableErrorCode {
    const table: []const NativeEntry = switch (os) {
        .linux => &native_linux,
        .macos => &native_macos,
        .windows => &native_windows,
    };
    for (table) |entry| {
        if (entry.native == native) return entry.code;
    }
    const aliases: []const NativeEntry = switch (os) {
        .windows => &native_windows_aliases,
        else => &.{},
    };
    for (aliases) |entry| {
        if (entry.native == native) return entry.code;
    }
    return null;
}

test "portableCodeFromErrnoは全portable codeを正しく写像する" {
    try std.testing.expectEqual(PortableErrorCode.ENOENT, portableCodeFromErrno(.NOENT).?);
    try std.testing.expectEqual(PortableErrorCode.EACCES, portableCodeFromErrno(.ACCES).?);
    try std.testing.expectEqual(PortableErrorCode.EPERM, portableCodeFromErrno(.PERM).?);
    try std.testing.expectEqual(PortableErrorCode.EEXIST, portableCodeFromErrno(.EXIST).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTDIR, portableCodeFromErrno(.NOTDIR).?);
    try std.testing.expectEqual(PortableErrorCode.EISDIR, portableCodeFromErrno(.ISDIR).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTEMPTY, portableCodeFromErrno(.NOTEMPTY).?);
    try std.testing.expectEqual(PortableErrorCode.EXDEV, portableCodeFromErrno(.XDEV).?);
    try std.testing.expectEqual(PortableErrorCode.ELOOP, portableCodeFromErrno(.LOOP).?);
    try std.testing.expectEqual(PortableErrorCode.EROFS, portableCodeFromErrno(.ROFS).?);
    try std.testing.expectEqual(PortableErrorCode.ENOSPC, portableCodeFromErrno(.NOSPC).?);
    try std.testing.expectEqual(PortableErrorCode.EMFILE, portableCodeFromErrno(.MFILE).?);
    try std.testing.expectEqual(PortableErrorCode.ENFILE, portableCodeFromErrno(.NFILE).?);
    try std.testing.expectEqual(PortableErrorCode.EINVAL, portableCodeFromErrno(.INVAL).?);
    try std.testing.expectEqual(PortableErrorCode.EPIPE, portableCodeFromErrno(.PIPE).?);
    try std.testing.expectEqual(PortableErrorCode.EBADF, portableCodeFromErrno(.BADF).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, portableCodeFromErrno(.OPNOTSUPP).?);
}

test "renameのEXDEVをportable codeで識別できる" {
    const error_value = classifyNative(.XDEV, "rename", "/src", "/dst", null).?;
    try std.testing.expectEqual(PortableErrorCode.EXDEV, error_value.code);
    try std.testing.expectEqualStrings("rename", error_value.operation.?);
    try std.testing.expectEqualStrings("/src", error_value.path.?);
    try std.testing.expectEqualStrings("/dst", error_value.path2.?);
    try std.testing.expectEqual(@as(i32, 18), error_value.nativeCode.?);
}

test "permission denied / not found / exists / not-empty / broken pipeを識別できる" {
    try std.testing.expectEqual(PortableErrorCode.EACCES, classifyNative(.ACCES, null, null, null, null).?.code);
    try std.testing.expectEqual(PortableErrorCode.EPERM, classifyNative(.PERM, null, null, null, null).?.code);
    try std.testing.expectEqual(PortableErrorCode.ENOENT, classifyNative(.NOENT, null, null, null, null).?.code);
    try std.testing.expectEqual(PortableErrorCode.EEXIST, classifyNative(.EXIST, null, null, null, null).?.code);
    try std.testing.expectEqual(PortableErrorCode.ENOTEMPTY, classifyNative(.NOTEMPTY, null, null, null, null).?.code);
    try std.testing.expectEqual(PortableErrorCode.EPIPE, classifyNative(.PIPE, null, null, null, null).?.code);
}

test "Zigエラーからも同一のportable codeへ写像する" {
    try std.testing.expectEqual(PortableErrorCode.EXDEV, portableCodeFromFailure(error.CrossDevice).?);
    try std.testing.expectEqual(PortableErrorCode.ENOENT, portableCodeFromFailure(error.FileNotFound).?);
    try std.testing.expectEqual(PortableErrorCode.EACCES, portableCodeFromFailure(error.AccessDenied).?);
    try std.testing.expectEqual(PortableErrorCode.EPERM, portableCodeFromFailure(error.PermissionDenied).?);
    try std.testing.expectEqual(PortableErrorCode.EEXIST, portableCodeFromFailure(error.PathAlreadyExists).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTEMPTY, portableCodeFromFailure(error.DirNotEmpty).?);
    try std.testing.expectEqual(PortableErrorCode.EPIPE, portableCodeFromFailure(error.BrokenPipe).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTDIR, portableCodeFromFailure(error.NotDir).?);
    try std.testing.expectEqual(PortableErrorCode.EISDIR, portableCodeFromFailure(error.IsDir).?);
    try std.testing.expectEqual(PortableErrorCode.ELOOP, portableCodeFromFailure(error.SymLinkLoop).?);
    try std.testing.expectEqual(PortableErrorCode.EROFS, portableCodeFromFailure(error.ReadOnlyFileSystem).?);
    try std.testing.expectEqual(PortableErrorCode.ENOSPC, portableCodeFromFailure(error.NoSpaceLeft).?);
    try std.testing.expectEqual(PortableErrorCode.EMFILE, portableCodeFromFailure(error.ProcessFdQuotaExceeded).?);
    try std.testing.expectEqual(PortableErrorCode.ENFILE, portableCodeFromFailure(error.SystemFdQuotaExceeded).?);
    try std.testing.expectEqual(PortableErrorCode.EINVAL, portableCodeFromFailure(error.BadPathName).?);
    try std.testing.expectEqual(PortableErrorCode.EINVAL, portableCodeFromFailure(error.InvalidWtf8).?);
    try std.testing.expectEqual(PortableErrorCode.EBADF, portableCodeFromFailure(error.BadFileDescriptor).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, portableCodeFromFailure(error.Unsupported).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, portableCodeFromFailure(error.OperationUnsupported).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, portableCodeFromFailure(error.NotSupported).?);
}

test "3 OSのnative差分があってもportable分類が安定する" {
    for (native_linux) |entry| {
        try std.testing.expectEqual(entry.code, portableCodeFromNative(.linux, entry.native).?);
        try std.testing.expectEqual(entry.native, nativeCodeFromPortable(.linux, entry.code).?);
    }
    for (native_macos) |entry| {
        try std.testing.expectEqual(entry.code, portableCodeFromNative(.macos, entry.native).?);
        try std.testing.expectEqual(entry.native, nativeCodeFromPortable(.macos, entry.code).?);
    }
    for (native_windows) |entry| {
        try std.testing.expectEqual(entry.code, portableCodeFromNative(.windows, entry.native).?);
        try std.testing.expectEqual(entry.native, nativeCodeFromPortable(.windows, entry.code).?);
    }
    inline for (std.meta.tags(PortableErrorCode)) |code| {
        const linux_native = nativeCodeFromPortable(.linux, code).?;
        const macos_native = nativeCodeFromPortable(.macos, code).?;
        const windows_native = nativeCodeFromPortable(.windows, code).?;
        // native値はOS差を許すがportable codeは同一である。
        try std.testing.expectEqual(code, portableCodeFromNative(.linux, linux_native).?);
        try std.testing.expectEqual(code, portableCodeFromNative(.macos, macos_native).?);
        try std.testing.expectEqual(code, portableCodeFromNative(.windows, windows_native).?);
    }
    // WindowsはENOTSUPの別名native値(129)も同一portable codeへ写す。
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, portableCodeFromNative(.windows, 129).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, portableCodeFromNative(.windows, 130).?);
    try std.testing.expectEqual(@as(i32, 130), nativeCodeFromPortable(.windows, .ENOTSUP).?);
}

test "現行OSのnativeコード表はstd.posix.Eの実値と一致する" {
    const os = currentOs();
    const table: []const NativeEntry = switch (os) {
        .linux => &native_linux,
        .macos => &native_macos,
        .windows => &native_windows,
    };
    for (table) |entry| {
        const errno: std.posix.E = @enumFromInt(entry.native);
        try std.testing.expectEqual(entry.code, portableCodeFromErrno(errno).?);
        try std.testing.expectEqual(entry.native, nativeCodeFromErrno(errno));
    }
}

test "エラー情報は値そのものに紐付き、成功操作で再利用されない" {
    const first = classifyNative(.XDEV, "rename", "/a", "/b", null).?;
    const second = classifyNative(.NOENT, "open", "/missing", null, null).?;
    // 前のエラー値は不変であり、後続の別操作が前回情報を保持しない。
    try std.testing.expectEqual(PortableErrorCode.EXDEV, first.code);
    try std.testing.expectEqualStrings("rename", first.operation.?);
    try std.testing.expectEqual(PortableErrorCode.ENOENT, second.code);
    try std.testing.expectEqualStrings("open", second.operation.?);
    try std.testing.expectEqual(@as(i32, 2), second.nativeCode.?);
    // nativeCodeはclassifyFailureではnull（Zigエラーにはerrnoが無い）
    const via_failure = classifyFailure(error.FileNotFound, "open", "/missing", null, null).?;
    try std.testing.expect(via_failure.nativeCode == null);
    try std.testing.expectEqual(PortableErrorCode.ENOENT, via_failure.code);
}

test "messageはNode SystemError形式で組み立てる" {
    const allocator = std.testing.allocator;
    const message = try formatMessage(allocator, .EXDEV, "rename", "/src", "/dst");
    defer allocator.free(message);
    try std.testing.expectEqualStrings("EXDEV: cross-device link not permitted, rename '/src' -> '/dst'", message);

    const no_path = try formatMessage(allocator, .ENOENT, null, null, null);
    defer allocator.free(no_path);
    try std.testing.expectEqualStrings("ENOENT: no such file or directory", no_path);

    const path_only = try formatMessage(allocator, .ENOENT, null, "/missing", null);
    defer allocator.free(path_only);
    try std.testing.expectEqualStrings("ENOENT: no such file or directory, '/missing'", path_only);

    const operation_only = try formatMessage(allocator, .EACCES, "open", null, null);
    defer allocator.free(operation_only);
    try std.testing.expectEqualStrings("EACCES: permission denied, open", operation_only);
}

test "displayPathAllocは不正UTF-8を置換する" {
    const allocator = std.testing.allocator;
    const display = try displayPathAlloc(allocator, &.{ 'a', 0xff, 'b' });
    defer allocator.free(display);
    try std.testing.expect(std.mem.indexOfScalar(u8, display, 0xff) == null);
    try std.testing.expect(display.len > 0);
}
