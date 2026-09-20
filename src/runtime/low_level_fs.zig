const std = @import("std");
const builtin = @import("builtin");
const foundation = @import("low_level_foundation.zig");

/// `stat` / `lstat` が返すファイル種別。カタログの `stat.kind` の語彙と一致する。
/// `dirEntry.type` と同じ file/directory/symlink/other/unknown を使う。
pub const FileKind = enum {
    file,
    directory,
    symlink,
    other,
    unknown,

    pub fn name(self: FileKind) []const u8 {
        return @tagName(self);
    }
};

/// OSのファイルメタデータ。`stat` と `lstat` の共通表現であり、カタログ
/// `typeSchemas.stat` の全フィールドを保持する。取得できない時刻は `null`、
/// 概念の無いOS（Windowsのuid/gid/dev/rdev/blocks等）は 0 にする
/// （Windowsでは0がroot所有と区別できない点に留意）。
pub const Metadata = struct {
    kind: FileKind,
    size: u64,
    mode: u32,
    uid: u32 = 0,
    gid: u32 = 0,
    dev: u64 = 0,
    rdev: u64 = 0,
    inode: u64 = 0,
    nlink: u64 = 0,
    block_size: u64 = 0,
    blocks: u64 = 0,
    atime_ns: foundation.OptionalTimeNs = null,
    mtime_ns: foundation.OptionalTimeNs = null,
    ctime_ns: foundation.OptionalTimeNs = null,
    birthtime_ns: foundation.OptionalTimeNs = null,
};

/// `stat`（follow=true）と `lstat`（follow=false）の共通実装。OSごとに
/// 1回のstat/lstat（Windowsは1ハンドルからの情報取得）で全フィールドを
/// 組み立て、同一ファイルの一貫したスナップショットを返す。2回の取得を
/// 合成しないため、パス差し替え時に他ファイルのフィールドが混在しない。
///
/// - macOS/POSIX: `fstatat`（`std.c.Stat`）
/// - Linux: `statx`
/// - Windows: `NtQueryInformationFile(FileAllInformation)` + reparse tag
pub fn stat(io: std.Io, path: []const u8, follow: bool) anyerror!Metadata {
    return switch (builtin.os.tag) {
        .windows => statWindows(io, path, follow),
        .linux => statLinux(path, follow),
        .wasi => statPortable(io, path, follow),
        else => statPosix(path, follow),
    };
}

/// シンボリックリンクを作成する。Windowsではリンク先の種別を自動判定して
/// file symlink / directory symlink を選ぶ。POSIXでは `is_directory` は無視される。
/// Windowsのdirectory symlink作成にはsymlink権限が必要で、無い場合はEPERMになる。
///
/// Windowsはリンク種別をtargetのstat結果から決めるため、未作成のtargetや
/// statできないtargetはfile symlinkとして作成する。後からtargetを
/// ディレクトリとして作ってもdirectory symlinkにはならない（POSIXのような
/// 未解決directory symlinkはWindowsのsymlinkモデルでは表現できない）。
pub fn createSymlink(io: std.Io, target: []const u8, link: []const u8) anyerror!void {
    var flags: std.Io.Dir.SymLinkFlags = .{};
    if (builtin.os.tag == .windows) {
        flags.is_directory = try targetIsDirectory(io, target, link);
    }
    try std.Io.Dir.cwd().symLink(io, target, link, flags);
}

/// Windowsのsymlink種別判定。相対targetはリンクの親ディレクトリ基準で解決し、
/// 存在しないdangling targetやstatできないtargetはfileとして扱う（POSIXと
/// 同様に任意のtarget文字列でリンクを作れる）。解決パスが長すぎる場合は
/// 種別を誤判定しないよう `error.NameTooLong` で失敗させる。
fn targetIsDirectory(io: std.Io, target: []const u8, link: []const u8) anyerror!bool {
    // 空targetはリンク親ディレクトリではなく未解決targetとして扱う。
    if (target.len == 0) return false;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const candidate = symlinkTargetPath(&buffer, target, link) orelse return error.NameTooLong;
    const info = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch return false;
    return info.kind == .directory;
}

/// リンク種別判定に使うtargetの実パス。相対targetはリンクの親ディレクトリ
/// 基準で解決する（Windows symlinkの相対targetと同じ意味）。絶対targetは
/// そのまま返す。バッファが不足する場合はnull（呼び出し側がNameTooLongにする）。
fn symlinkTargetPath(buffer: []u8, target: []const u8, link: []const u8) ?[]const u8 {
    // 絶対パスとWindowsのドライブ相対（`C:foo`）は基準を持たないのでそのまま。
    if (std.fs.path.isAbsolute(target) or hasDrivePrefix(target)) return target;
    const base = std.fs.path.dirname(link) orelse ".";
    return std.fmt.bufPrint(buffer, "{s}{c}{s}", .{ base, std.fs.path.sep, target }) catch null;
}

fn hasDrivePrefix(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

/// シンボリックリンクの参照先文字列を返す。対象がsymlinkでない場合は
/// `error.NotLink`（portable code EINVAL）になる。
///
/// POSIXのreadlinkはバッファ不足時に切り詰めて長さを返し、Zigの一部経路は
/// `error.NameTooLong` を返す。どちらでも完全な参照先を返すよう、返却長が
/// バッファ長に達した場合も `error.NameTooLong` の場合もバッファを倍々に
/// 拡張して再取得する（上限到達時は `error.NameTooLong`）。切り詰めた値を
/// 正常値として返さない。その他の失敗はそのまま伝播する。
pub fn readlink(io: std.Io, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
    var size: usize = std.fs.max_path_bytes;
    while (true) {
        const buffer = try allocator.alloc(u8, size);
        defer allocator.free(buffer);
        const length = std.Io.Dir.cwd().readLink(io, path, buffer) catch |failure| {
            // バッファ不足をNameTooLongで通知する経路も拡張して再試行する。
            if (failure != error.NameTooLong) return failure;
            if (size >= 1 << 20) return failure;
            size *= 2;
            continue;
        };
        if (length < buffer.len) return allocator.dupe(u8, buffer[0..length]);
        if (size >= 1 << 20) return error.NameTooLong;
        size *= 2;
    }
}

/// ハードリンクを作成する。シンボリックリンクは追跡しない。
pub fn createHardLink(io: std.Io, target: []const u8, link: []const u8) anyerror!void {
    try std.Io.Dir.hardLink(std.Io.Dir.cwd(), target, std.Io.Dir.cwd(), link, io, .{ .follow_symlinks = false });
}

/// 実体パス（絶対パス、symlink解決済み）を返す。NUL終端sliceを返すので
/// 呼び出し側は同じallocatorで `free` できる。
pub fn realpath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
    return try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
}

/// 同一ファイルシステム内で名前を変更する。宛先が存在する場合は置き換える。
/// 異なるファイルシステムをまたぐ場合は `error.CrossDevice`（EXDEV）になる。
pub fn rename(io: std.Io, source: []const u8, destination: []const u8) anyerror!void {
    try std.Io.Dir.rename(std.Io.Dir.cwd(), source, std.Io.Dir.cwd(), destination, io);
}

/// ファイルまたはsymlinkを削除する。ディレクトリは `error.IsDir`（EISDIR）になる。
pub fn unlink(io: std.Io, path: []const u8) anyerror!void {
    try std.Io.Dir.cwd().deleteFile(io, path);
}

/// 空のディレクトリを削除する。空でない場合は `error.DirNotEmpty`（ENOTEMPTY）。
pub fn rmdir(io: std.Io, path: []const u8) anyerror!void {
    try std.Io.Dir.cwd().deleteDir(io, path);
}

/// パス指定のtruncate。POSIXの `truncate` と同じくsymlinkを追跡し、write権限を
/// 要求する。grow時は0で埋める（実体はsparseになり得る）。ディレクトリは
/// `error.IsDir`（EISDIR）で拒否する。
///
/// POSIXではパスを直接指定する `truncate(2)` を使う。`open(O_WRONLY)` +
/// `ftruncate` ではFIFOの書込み専用openが読取り側の接続までブロックし、POSIXの
/// `truncate` なら即EINVALになる場面でランタイム全体が停止するため。
/// Windowsは書込みハンドルを開いて
/// `NtSetInformationFile(FileEndOfFileInformation)` を使う。
pub fn truncatePath(io: std.Io, path: []const u8, size: u64) anyerror!void {
    return switch (builtin.os.tag) {
        .windows, .wasi => truncatePathByHandle(io, path, size),
        else => truncatePathPosix(path, size),
    };
}

fn truncatePathByHandle(io: std.Io, path: []const u8, size: u64) anyerror!void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only });
    defer file.close(io);
    try file.setLength(io, size);
}

fn truncatePathPosix(path: []const u8, size: u64) anyerror!void {
    const c_truncate = struct {
        extern "c" fn truncate(pathname: [*:0]const u8, length: std.c.off_t) c_int;
    }.truncate;
    const destination = try std.posix.toPosixPath(path);
    const length = std.math.cast(std.c.off_t, size) orelse return error.InvalidArgument;
    while (true) {
        const result = c_truncate(&destination, length);
        if (result == 0) return;
        const errno = std.c.errno(result);
        // シグナル割込みは一時的なので再試行する（EINTRをEINVALにしない）。
        if (errno == .INTR) continue;
        return fsPosixErrno(errno);
    }
}

/// パス指定の時刻設定（utimes/utimensat相当）。POSIXでは `utimensat`、Windowsでは
/// FILE_WRITE_ATTRIBUTESを持つ書込みハンドルを開いて `NtSetInformationFile` を使う。
/// ATIME/MTIMEは `SetTime` 契約（null=既存値維持 / "now"=現在時刻 / ナノ秒明示）。
pub fn setTimestampsPath(io: std.Io, path: []const u8, atime: foundation.SetTime, mtime: foundation.SetTime) anyerror!void {
    return switch (builtin.os.tag) {
        .windows => setTimestampsPathWindows(io, path, atime, mtime),
        .wasi => error.OperationUnsupported,
        else => setTimestampsPathPosix(io, path, atime, mtime),
    };
}

/// オープン済みハンドルの時刻設定（futimens/SetFileTime相当）。
pub fn setTimestampsHandle(io: std.Io, file: std.Io.File, atime: foundation.SetTime, mtime: foundation.SetTime) anyerror!void {
    return switch (builtin.os.tag) {
        .windows => setTimestampsHandleWindows(io, file, atime, mtime),
        .wasi => error.OperationUnsupported,
        else => setTimestampsHandlePosix(file, atime, mtime),
    };
}

fn setTimestampsPathPosix(io: std.Io, path: []const u8, atime: foundation.SetTime, mtime: foundation.SetTime) anyerror!void {
    // LinuxのutimensatはATIME/MTIMEともUTIME_OMITのときパスを解決せず成功するため、
    // 存在しないパスでもENOENTにならない。macOS/Windowsと揃えて明示的に検証する。
    if (atime.isUnchanged() and mtime.isUnchanged()) {
        _ = try std.Io.Dir.cwd().statFile(io, path, .{});
        return;
    }
    const destination = try std.posix.toPosixPath(path);
    const times = [2]std.c.timespec{
        try timespecFromSetTime(atime),
        try timespecFromSetTime(mtime),
    };
    while (true) {
        const result = std.c.utimensat(std.c.AT.FDCWD, &destination, &times, 0);
        if (result == 0) return;
        const errno = std.c.errno(result);
        // シグナル割込みは一時的なので再試行する（EINTRをEINVALにしない）。
        if (errno == .INTR) continue;
        return fsPosixErrno(errno);
    }
}

fn setTimestampsHandlePosix(file: std.Io.File, atime: foundation.SetTime, mtime: foundation.SetTime) anyerror!void {
    const times = [2]std.c.timespec{
        try timespecFromSetTime(atime),
        try timespecFromSetTime(mtime),
    };
    while (true) {
        const result = std.c.futimens(file.handle, &times);
        if (result == 0) return;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        return fsPosixErrno(errno);
    }
}

/// Windowsのpath指定時刻設定。stdの `Dir.setTimestamps` はWindowsで未実装
/// （`@panic`）のため、`FILE_WRITE_ATTRIBUTES` と `OPEN_FOR_BACKUP_INTENT` で
/// ハンドルを開いて `NtSetInformationFile(FileBasicInformation)` を使う。
/// GENERIC_WRITEを使わないので、read-only属性ファイルとディレクトリにも
/// POSIXの `utimensat` と同様に適用できる。
fn setTimestampsPathWindows(io: std.Io, path: []const u8, atime: foundation.SetTime, mtime: foundation.SetTime) anyerror!void {
    _ = io;
    const windows = std.os.windows;
    const handle = try openWindowsAttributes(path, false);
    defer windows.CloseHandle(handle);

    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    const now_sys = if (atime.isNow() or mtime.isNow()) windows.ntdll.RtlGetSystemTimePrecise() else 0;
    var info = windows.FILE.BASIC_INFORMATION{
        .CreationTime = 0,
        .LastAccessTime = try windowsSysTime(atime, now_sys),
        .LastWriteTime = try windowsSysTime(mtime, now_sys),
        .ChangeTime = 0,
        .FileAttributes = .{},
    };
    const set_status = windows.ntdll.NtSetInformationFile(handle, &io_status_block, &info, @sizeOf(windows.FILE.BASIC_INFORMATION), .Basic);
    if (set_status != .SUCCESS) return ntStatusError(set_status);
}

/// `FILE_WRITE_ATTRIBUTES | SYNCHRONIZE`（`read_attributes` が true なら
/// `FILE_READ_ATTRIBUTES` も）と `OPEN_FOR_BACKUP_INTENT` でパスを開く。
/// read-only属性ファイルとディレクトリにも適用でき、reparse pointは追跡する。
///
/// 製品の時刻設定は属性を照会せず `NtSetInformationFile` だけを行うため
/// `read_attributes=false` で開く。WindowsのACLは読取属性と書込属性を別々に
/// 許可できるため、`FILE_READ_ATTRIBUTES` を不要に要求すると書込属性だけを
/// 許可されたファイルで `ACCESS_DENIED` になる。属性queryを行うテストhelper
/// だけが `read_attributes=true` を指定する。呼び出し側が `CloseHandle` する。
fn openWindowsAttributes(path: []const u8, read_attributes: bool) anyerror!std.os.windows.HANDLE {
    const windows = std.os.windows;
    const allocator = std.heap.page_allocator;
    const dos_path = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.BadPathName,
    };
    defer allocator.free(dos_path);

    var nt_path: windows.UNICODE_STRING = undefined;
    if (!windows.ntdll.RtlDosPathNameToNtPathName_U(dos_path.ptr, &nt_path, null, null).toBool()) {
        return error.BadPathName;
    }
    defer windows.ntdll.RtlFreeUnicodeString(&nt_path);

    // 通常のWin32パス解決と同じく大小文字を区別しない。`Flags` の既定値も
    // trueだが、stdの既定値変更に依存しないよう明示する。
    var attributes = windows.OBJECT.ATTRIBUTES{
        .ObjectName = &nt_path,
        .Attributes = .{ .CASE_INSENSITIVE = true },
    };
    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    var handle: windows.HANDLE = undefined;
    const status = windows.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = read_attributes, .WRITE_ATTRIBUTES = true } },
        },
        &attributes,
        &io_status_block,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{ .IO = .SYNCHRONOUS_NONALERT, .OPEN_FOR_BACKUP_INTENT = true },
        null,
        0,
    );
    if (status != .SUCCESS) return ntStatusError(status);
    return handle;
}

fn setTimestampsHandleWindows(io: std.Io, file: std.Io.File, atime: foundation.SetTime, mtime: foundation.SetTime) anyerror!void {
    _ = io;
    const windows = std.os.windows;
    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    const now_sys = if (atime.isNow() or mtime.isNow()) windows.ntdll.RtlGetSystemTimePrecise() else 0;
    var info = windows.FILE.BASIC_INFORMATION{
        .CreationTime = 0,
        .LastAccessTime = try windowsSysTime(atime, now_sys),
        .LastWriteTime = try windowsSysTime(mtime, now_sys),
        .ChangeTime = 0,
        .FileAttributes = .{},
    };
    const status = windows.ntdll.NtSetInformationFile(file.handle, &io_status_block, &info, @sizeOf(windows.FILE.BASIC_INFORMATION), .Basic);
    if (status != .SUCCESS) return ntStatusError(status);
}

/// `BASIC_INFORMATION` 用のWindows時刻（1601年起点・100ns）。0は「変更しない」。
/// 明示値はi128でFILETIMEを計算してからi64へ収まるか検査する（i64を超えると
/// Windowsの `toSysTime` は `@intCast` でpanicするため自前で変換する）。
fn windowsSysTime(time: foundation.SetTime, now_sys: i64) anyerror!i64 {
    return switch (time) {
        .unchanged => 0,
        .now => now_sys,
        .at => |nanoseconds| windowsFiletimeFromNs(nanoseconds),
    };
}

/// Unixナノ秒をWindows FILETIME（1601-01-01起点・100ns）へ変換する。
/// `FILE_BASIC_INFORMATION` の時刻は0が「変更しない」を意味する特別値であり、
/// 負値は符号なしFILETIMEとして不正になるため、0以下とi64範囲外は
/// `InvalidTimestamp`（EINVAL）で拒否する。Windows APIに依存しないので
/// 全プラットフォームで単体テストできる。
fn windowsFiletimeFromNs(nanoseconds: foundation.TimeNs) anyerror!i64 {
    const hundred_ns = @divFloor(nanoseconds, 100);
    const system_time = hundred_ns - @as(i128, std.time.epoch.windows) * (std.time.ns_per_s / 100);
    if (system_time <= 0) return error.InvalidTimestamp;
    return std.math.cast(i64, system_time) orelse return error.InvalidTimestamp;
}

/// `NtCreateFile` / `NtSetInformationFile` のNTSTATUSをportable codeへ写す。
fn ntStatusError(status: std.os.windows.NTSTATUS) anyerror {
    return switch (status) {
        .ACCESS_DENIED, .NETWORK_ACCESS_DENIED => error.AccessDenied,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .OBJECT_NAME_INVALID, .OBJECT_PATH_SYNTAX_BAD, .INVALID_PARAMETER => error.BadPathName,
        .NOT_A_DIRECTORY => error.NotDir,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .INVALID_HANDLE => error.BadFileDescriptor,
        .DISK_FULL => error.NoSpaceLeft,
        .MEDIA_WRITE_PROTECTED => error.ReadOnlyFileSystem,
        else => error.Unexpected,
    };
}

/// `SetTime` をPOSIXの `timespec` へ変換する。UTIME_NOW / UTIME_OMIT は
/// `std.c.UTIME` を正本とし、OSごとの表現差（Linuxの `(1<<30)-n` や
/// BSDの負値）を吸収する。明示値はナノ秒を秒とナノ秒へ分解する。
fn timespecFromSetTime(time: foundation.SetTime) anyerror!std.c.timespec {
    const seconds_type = @TypeOf(@as(std.c.timespec, undefined).sec);
    const nanoseconds_type = @TypeOf(@as(std.c.timespec, undefined).nsec);
    return switch (time) {
        .unchanged => std.c.UTIME.OMIT,
        .now => std.c.UTIME.NOW,
        .at => |nanoseconds| blk: {
            const seconds = @divFloor(nanoseconds, foundation.ns_per_s);
            const subsecond = nanoseconds - seconds * foundation.ns_per_s;
            break :blk .{
                .sec = std.math.cast(seconds_type, seconds) orelse return error.InvalidTimestamp,
                .nsec = std.math.cast(nanoseconds_type, subsecond) orelse return error.InvalidTimestamp,
            };
        },
    };
}

fn fsPosixErrno(errno: std.c.E) anyerror {
    return switch (errno) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .INVAL, .FAULT => error.InvalidArgument,
        .ROFS => error.ReadOnlyFileSystem,
        .BADF => error.BadFileDescriptor,
        .FBIG => error.FileTooBig,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        .NOSYS => error.Unsupported,
        .OPNOTSUPP => error.OperationUnsupported,
        else => error.Unexpected,
    };
}

pub fn kindFrom(kind: std.Io.File.Kind) FileKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .symlink,
        .unknown => .unknown,
        else => .other,
    };
}

/// POSIX（macOS等）の単一 `fstatat` から全フィールドを組み立てる。
fn statPosix(path: []const u8, follow: bool) anyerror!Metadata {
    const posix_path = try std.posix.toPosixPath(path);
    var raw: std.c.Stat = std.mem.zeroes(std.c.Stat);
    const flags: u32 = if (follow) 0 else std.c.AT.SYMLINK_NOFOLLOW;
    while (true) {
        const result = std.c.fstatat(std.c.AT.FDCWD, &posix_path, &raw, flags);
        if (result == 0) break;
        const errno = std.c.errno(result);
        // シグナル割込みは一時的なので再試行する（EINTRをEINVALにしない）。
        if (errno == .INTR) continue;
        return posixErrno(errno);
    }
    var metadata = Metadata{
        .kind = posixKind(raw.mode),
        .size = @bitCast(raw.size),
        .mode = @as(u32, @intCast(toU64(raw.mode) & 0o7777)),
        .uid = @intCast(raw.uid),
        .gid = @intCast(raw.gid),
        .dev = toU64(raw.dev),
        .rdev = toU64(raw.rdev),
        .inode = toU64(raw.ino),
        .nlink = toU64(raw.nlink),
        .block_size = toU64(raw.blksize),
        .blocks = toU64(raw.blocks),
        .atime_ns = timespecNs(raw.atime()),
        .mtime_ns = timespecNs(raw.mtime()),
        .ctime_ns = timespecNs(raw.ctime()),
    };
    if (comptime @hasDecl(std.c.Stat, "birthtime")) {
        metadata.birthtime_ns = timespecNs(raw.birthtime());
    }
    return metadata;
}

fn posixKind(mode: std.c.mode_t) FileKind {
    return switch (mode & std.c.S.IFMT) {
        std.c.S.IFDIR => .directory,
        std.c.S.IFREG => .file,
        std.c.S.IFLNK => .symlink,
        else => .other,
    };
}

fn posixErrno(errno: std.c.E) anyerror {
    return switch (errno) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        .INVAL => error.InvalidArgument,
        else => error.Unexpected,
    };
}

/// Linuxの単一 `statx` から全フィールドを組み立てる。statx非対応環境
/// （古いカーネルやseccomp制限）はENOTSUPへ写す。Zig 0.16の
/// `std.Io.Dir.statFile` もstatxベースで、libcの `fstatat` はLinuxでは
/// 提供されない（`std.c.fstatat = {}` / `std.c.Stat = void`）ため、
/// 代替経路へフォールバックしても同じ失敗になる。
fn statLinux(path: []const u8, follow: bool) anyerror!Metadata {
    const posix_path = try std.posix.toPosixPath(path);
    var raw: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
    const flags: u32 = std.os.linux.AT.NO_AUTOMOUNT |
        (if (follow) @as(u32, 0) else std.os.linux.AT.SYMLINK_NOFOLLOW);
    const mask: std.os.linux.STATX = .{
        .TYPE = true,
        .MODE = true,
        .NLINK = true,
        .UID = true,
        .GID = true,
        .INO = true,
        .SIZE = true,
        .BLOCKS = true,
        .ATIME = true,
        .MTIME = true,
        .CTIME = true,
        .BTIME = true,
    };
    while (true) {
        const result = std.os.linux.statx(std.os.linux.AT.FDCWD, &posix_path, flags, mask, &raw);
        const errno = std.os.linux.errno(result);
        if (errno == .SUCCESS) break;
        // シグナル割込みは一時的なので再試行する（EINTRをEINVALにしない）。
        if (errno == .INTR) continue;
        return linuxErrno(errno);
    }
    var metadata = Metadata{
        .kind = linuxKind(raw.mode),
        .size = raw.size,
        .mode = @as(u32, raw.mode) & 0o7777,
        .uid = raw.uid,
        .gid = raw.gid,
        // statxはmajor/minorを分けて返すため、glibcの `makedev` と同じ
        // 符号化にまとめてPOSIXの `st_dev` 相当にする。
        .dev = linuxDevice(raw.dev_major, raw.dev_minor),
        .rdev = linuxDevice(raw.rdev_major, raw.rdev_minor),
        .inode = raw.ino,
        .nlink = raw.nlink,
        .block_size = raw.blksize,
        .blocks = raw.blocks,
    };
    if (raw.mask.ATIME) metadata.atime_ns = statxTimeNs(raw.atime);
    if (raw.mask.MTIME) metadata.mtime_ns = statxTimeNs(raw.mtime);
    if (raw.mask.CTIME) metadata.ctime_ns = statxTimeNs(raw.ctime);
    if (raw.mask.BTIME) metadata.birthtime_ns = statxTimeNs(raw.btime);
    return metadata;
}

fn linuxKind(mode: u16) FileKind {
    return switch (mode & std.os.linux.S.IFMT) {
        std.os.linux.S.IFDIR => .directory,
        std.os.linux.S.IFREG => .file,
        std.os.linux.S.IFLNK => .symlink,
        else => .other,
    };
}

/// Linux `statx` のerrnoをZigエラーへ写す。カタログのstat系エラー
/// (ENOENT/EACCES/EPERM/ENOTDIR/ELOOP/EINVAL/ENOTSUP) を網羅する。statxが
/// 返し得る残り（EFAULT/EOVERFLOW等）はportable codeに対応が無いため、
/// 呼び出し側の `portableCodeForFailure` でEINVALへ丸める（G0の未写像エラー方針）。
fn linuxErrno(errno: std.os.linux.E) anyerror {
    return switch (errno) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        .INVAL => error.InvalidArgument,
        .NOSYS => error.Unsupported,
        .OPNOTSUPP => error.OperationUnsupported,
        else => error.Unexpected,
    };
}

/// glibc `makedev(major, minor)` と同じdev_t符号化。statxが返すmajor/minorを
/// POSIXの `st_dev` / `st_rdev` と比較できる表現へまとめる。
fn linuxDevice(major: u32, minor: u32) u64 {
    const major64: u64 = major;
    const minor64: u64 = minor;
    return ((major64 & 0xfffff000) << 32) |
        ((major64 & 0x00000fff) << 8) |
        ((minor64 & 0xffffff00) << 12) |
        (minor64 & 0x000000ff);
}

/// Windowsの単一ハンドル（`NtQueryInformationFile(FileAllInformation)`）から
/// 全フィールドを組み立てる。lstat相当では `follow_symlinks=false` で
/// reparse point自身のハンドルを開き、reparse tagでsymlinkを判定する。
/// 同一ハンドルの情報だけを使うため、パス差し替えでも混在しない。
/// uid/gid/dev/rdev/blocks はWindowsに概念が無いため0のまま。
fn statWindows(io: std.Io, path: []const u8, follow: bool) anyerror!Metadata {
    // `.allow_directory = true`（既定値）を明示し、ディレクトリも開けるように
    // する。これはZigの `Dir.statFile` が内部で使うのと同じ開き方である。
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = follow, .allow_directory = true });
    defer file.close(io);
    var status_block: std.os.windows.IO_STATUS_BLOCK = undefined;
    var info: std.os.windows.FILE.ALL_INFORMATION = undefined;
    const status = std.os.windows.ntdll.NtQueryInformationFile(
        file.handle,
        &status_block,
        &info,
        @sizeOf(std.os.windows.FILE.ALL_INFORMATION),
        .All,
    );
    if (status != .SUCCESS and status != .BUFFER_OVERFLOW) return error.Unexpected;
    const attributes = info.BasicInformation.FileAttributes;
    var kind: FileKind = if (attributes.DIRECTORY) .directory else .file;
    if (attributes.REPARSE_POINT) {
        var tag_info: std.os.windows.FILE.ATTRIBUTE_TAG_INFO = undefined;
        const tag_status = std.os.windows.ntdll.NtQueryInformationFile(
            file.handle,
            &status_block,
            &tag_info,
            @sizeOf(std.os.windows.FILE.ATTRIBUTE_TAG_INFO),
            .AttributeTag,
        );
        if (tag_status == .SUCCESS and tag_info.ReparseTag.IsSurrogate) kind = .symlink;
    }
    return .{
        .kind = kind,
        .size = @bitCast(info.StandardInformation.EndOfFile),
        .mode = if (attributes.READONLY) 0o444 else 0o666,
        .inode = @bitCast(info.InternalInformation.IndexNumber),
        .nlink = info.StandardInformation.NumberOfLinks,
        .atime_ns = fromWindowsTime(info.BasicInformation.LastAccessTime),
        .mtime_ns = fromWindowsTime(info.BasicInformation.LastWriteTime),
        .ctime_ns = fromWindowsTime(info.BasicInformation.ChangeTime),
        .birthtime_ns = fromWindowsTime(info.BasicInformation.CreationTime),
    };
}

/// Windows FILETIME（1601年起点・100ns単位）をUnix epochナノ秒へ変換する。
/// 変換はG0の `timeNsFromWindowsFileTime` を正本として使う。
fn fromWindowsTime(filetime: i64) foundation.TimeNs {
    return foundation.timeNsFromWindowsFileTime(@bitCast(filetime));
}

/// ポータブルAPIのみで構成するフォールバック（wasiとLinuxのstatx非対応時）。
/// kind/size/mode/時刻のみ取得し、uid/gid/dev/rdev/blocksは0のままになる。
fn statPortable(io: std.Io, path: []const u8, follow: bool) anyerror!Metadata {
    const info = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = follow });
    return .{
        .kind = kindFrom(info.kind),
        .size = info.size,
        .mode = 0o666,
        .inode = @intCast(info.inode),
        .nlink = @intCast(info.nlink),
        .block_size = info.block_size,
        .atime_ns = if (info.atime) |value| value.nanoseconds else null,
        .mtime_ns = info.mtime.nanoseconds,
        .ctime_ns = info.ctime.nanoseconds,
    };
}

fn timespecNs(timespec: std.c.timespec) foundation.TimeNs {
    return @as(i128, timespec.sec) * std.time.ns_per_s + @as(i128, timespec.nsec);
}

fn statxTimeNs(timestamp: std.os.linux.statx_timestamp) foundation.TimeNs {
    return @as(i128, timestamp.sec) * std.time.ns_per_s + @as(i128, timestamp.nsec);
}

fn toU64(value: anytype) u64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int => |info| if (info.signedness == .signed)
            @bitCast(@as(i64, @intCast(value)))
        else
            @intCast(value),
        else => @compileError("整数型ではありません"),
    };
}

fn currentUid() u32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getuid(),
        .windows, .wasi => 0,
        else => std.c.getuid(),
    };
}

fn currentGid() u32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getgid(),
        .windows, .wasi => 0,
        else => std.c.getgid(),
    };
}

/// Symlinkを解決せずにテスト用一時ディレクトリ内の絶対パスを作る。
fn tmpPath(temporary: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    return std.fs.path.join(std.testing.allocator, &.{ directory, name });
}

/// テスト用にread-only属性/権限を切り替える。POSIXはwrite bit、Windowsは
/// `FILE_ATTRIBUTE_READONLY` を操作する。Windowsは現在の属性をqueryするため
/// `FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES` で開く。
fn setFileReadOnly(path: []const u8, read_only: bool) !void {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const handle = try openWindowsAttributes(path, true);
        defer windows.CloseHandle(handle);
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        var info: windows.FILE.BASIC_INFORMATION = undefined;
        const query_status = windows.ntdll.NtQueryInformationFile(handle, &io_status_block, &info, @sizeOf(windows.FILE.BASIC_INFORMATION), .Basic);
        if (query_status != .SUCCESS) return ntStatusError(query_status);
        info.CreationTime = 0;
        info.LastAccessTime = 0;
        info.LastWriteTime = 0;
        info.ChangeTime = 0;
        info.FileAttributes.READONLY = read_only;
        const set_status = windows.ntdll.NtSetInformationFile(handle, &io_status_block, &info, @sizeOf(windows.FILE.BASIC_INFORMATION), .Basic);
        if (set_status != .SUCCESS) return ntStatusError(set_status);
        return;
    }
    if (builtin.os.tag == .wasi) return error.OperationUnsupported;
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_only });
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, std.Io.File.Permissions.default_file.setReadOnly(read_only));
}

test "statとlstatは通常ファイルのメタデータを区別なく取得する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "plain.txt", .data = "hello" });
    const path = try tmpPath(&temporary, "plain.txt");
    defer std.testing.allocator.free(path);

    const followed = try stat(std.testing.io, path, true);
    const not_followed = try stat(std.testing.io, path, false);
    try std.testing.expectEqual(FileKind.file, followed.kind);
    try std.testing.expectEqual(FileKind.file, not_followed.kind);
    try std.testing.expectEqual(@as(u64, 5), followed.size);
    try std.testing.expectEqual(@as(u64, 5), not_followed.size);
    try std.testing.expectEqual(@as(u64, 1), followed.nlink);
    try std.testing.expect(followed.mtime_ns != null);
    try std.testing.expect((followed.mode & 0o7777) != 0);
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        try std.testing.expect(followed.inode != 0);
        // OS固有の追加メタデータが実際に取れていること（no-opでないこと）を
        // 実プロセスのuid/gidと比較して確認する。
        try std.testing.expectEqual(currentUid(), followed.uid);
        try std.testing.expectEqual(currentGid(), followed.gid);
        try std.testing.expectEqual(followed.uid, not_followed.uid);
        if (builtin.os.tag == .macos) {
            try std.testing.expect(followed.birthtime_ns != null);
        }
    }
}

test "statはsymlinkを追跡しlstatはsymlink自身を返す" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target.txt", .data = "abc" });
    try temporary.dir.symLink(std.testing.io, "target.txt", "link.txt", .{});

    const target_path = try tmpPath(&temporary, "target.txt");
    defer std.testing.allocator.free(target_path);
    const link_path = try tmpPath(&temporary, "link.txt");
    defer std.testing.allocator.free(link_path);

    const followed = try stat(std.testing.io, link_path, true);
    const not_followed = try stat(std.testing.io, link_path, false);
    try std.testing.expectEqual(FileKind.file, followed.kind);
    try std.testing.expectEqual(@as(u64, 3), followed.size);
    try std.testing.expectEqual(FileKind.symlink, not_followed.kind);
    // stat is the target's inode, lstat is the link's own inode.
    try std.testing.expect(followed.inode != not_followed.inode);
}

test "broken symlinkはlstatでのみ存在しstatはENOENTになる" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.symLink(std.testing.io, "missing.txt", "dangling.txt", .{});
    const link_path = try tmpPath(&temporary, "dangling.txt");
    defer std.testing.allocator.free(link_path);

    const not_followed = try stat(std.testing.io, link_path, false);
    try std.testing.expectEqual(FileKind.symlink, not_followed.kind);
    try std.testing.expectError(error.FileNotFound, stat(std.testing.io, link_path, true));
}

test "symlinkループのstatはSymLinkLoopになりlstatはlink自身を返す" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.symLink(std.testing.io, "loop", "loop", .{});
    const loop_path = try tmpPath(&temporary, "loop");
    defer std.testing.allocator.free(loop_path);

    try std.testing.expectError(error.SymLinkLoop, stat(std.testing.io, loop_path, true));
    const link_info = try stat(std.testing.io, loop_path, false);
    try std.testing.expectEqual(FileKind.symlink, link_info.kind);
}

test "readlinkは参照先文字列を返し非symlinkはNotLinkになる" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target.txt", .data = "" });
    try temporary.dir.symLink(std.testing.io, "target.txt", "link.txt", .{});
    const link_path = try tmpPath(&temporary, "link.txt");
    defer std.testing.allocator.free(link_path);
    const target_path = try tmpPath(&temporary, "target.txt");
    defer std.testing.allocator.free(target_path);

    const destination = try readlink(std.testing.io, std.testing.allocator, link_path);
    defer std.testing.allocator.free(destination);
    try std.testing.expectEqualStrings("target.txt", destination);
    try std.testing.expectError(error.NotLink, readlink(std.testing.io, std.testing.allocator, target_path));
}

test "シンボリックリンク作成は既存リンクを上書きしない" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target.txt", .data = "" });
    const target_path = try tmpPath(&temporary, "target.txt");
    defer std.testing.allocator.free(target_path);
    const link_path = try tmpPath(&temporary, "link.txt");
    defer std.testing.allocator.free(link_path);

    try createSymlink(std.testing.io, target_path, link_path);
    try std.testing.expectError(error.PathAlreadyExists, createSymlink(std.testing.io, target_path, link_path));
}

test "相対targetはリンクの親ディレクトリ基準で解決する" {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    // 絶対targetはそのまま返る（ホスト非依存）。
    const absolute = if (builtin.os.tag == .windows) "C:\\x\\y" else "/x/y";
    try std.testing.expect(std.fs.path.isAbsolute(absolute));
    try std.testing.expectEqualStrings(absolute, symlinkTargetPath(&buffer, absolute, "link").?);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("C:\\a\\b\\child", symlinkTargetPath(&buffer, "child", "C:\\a\\b\\link").?);
        try std.testing.expectEqualStrings("C:\\a\\b\\sub\\child", symlinkTargetPath(&buffer, "sub\\child", "C:\\a\\b\\link").?);
        try std.testing.expectEqualStrings(".\\child", symlinkTargetPath(&buffer, "child", "link").?);
        // ドライブ相対targetは結合せずそのまま扱う。
        try std.testing.expectEqualStrings("C:b", symlinkTargetPath(&buffer, "C:b", "C:\\a\\link").?);
    } else {
        try std.testing.expectEqualStrings("/a/b/child", symlinkTargetPath(&buffer, "child", "/a/b/link").?);
        try std.testing.expectEqualStrings("/a/b/sub/child", symlinkTargetPath(&buffer, "sub/child", "/a/b/link").?);
        try std.testing.expectEqualStrings("./child", symlinkTargetPath(&buffer, "child", "link").?);
    }
}

test "ハードリンク作成はリンク数を増やし同一inodeを共有する" {
    // WindowsはZig 0.16 stdのDir.hardLinkが未対応でENOTSUPになる
    // （capability hardlink の os.windows はfalse。Issue #78で対応予定）。
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target.txt", .data = "xyz" });
    const target_path = try tmpPath(&temporary, "target.txt");
    defer std.testing.allocator.free(target_path);
    const link_path = try tmpPath(&temporary, "hard.txt");
    defer std.testing.allocator.free(link_path);

    try createHardLink(std.testing.io, target_path, link_path);
    const original = try stat(std.testing.io, target_path, true);
    const linked = try stat(std.testing.io, link_path, true);
    try std.testing.expectEqual(original.inode, linked.inode);
    try std.testing.expectEqual(@as(u64, 2), linked.nlink);
    try std.testing.expectError(error.PathAlreadyExists, createHardLink(std.testing.io, target_path, link_path));
}

test "realpathは絶対実体パスを返しsymlinkを解決する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target.txt", .data = "" });
    try temporary.dir.symLink(std.testing.io, "target.txt", "link.txt", .{});
    const link_path = try tmpPath(&temporary, "link.txt");
    defer std.testing.allocator.free(link_path);
    const target_path = try tmpPath(&temporary, "target.txt");
    defer std.testing.allocator.free(target_path);

    const resolved = try realpath(std.testing.io, std.testing.allocator, link_path);
    defer std.testing.allocator.free(resolved);
    try std.testing.expect(std.fs.path.isAbsolute(resolved));
    try std.testing.expectEqualStrings(target_path, resolved);

    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing-file.txt" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, realpath(std.testing.io, std.testing.allocator, missing));
}

test "renameは同一FSで上書きし、存在しない場合はENOENTになる" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "from.txt", .data = "one" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "to.txt", .data = "two" });
    const from_path = try tmpPath(&temporary, "from.txt");
    defer std.testing.allocator.free(from_path);
    const to_path = try tmpPath(&temporary, "to.txt");
    defer std.testing.allocator.free(to_path);

    try rename(std.testing.io, from_path, to_path);
    const renamed = try stat(std.testing.io, to_path, true);
    try std.testing.expectEqual(@as(u64, 3), renamed.size);
    try std.testing.expectError(error.FileNotFound, stat(std.testing.io, from_path, true));
    try std.testing.expectError(error.FileNotFound, rename(std.testing.io, from_path, to_path));
}

test "unlinkはディレクトリをEISDIRで拒否しrmdirは非空をENOTEMPTYで拒否する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "empty", .default_dir);
    try temporary.dir.createDir(std.testing.io, "full", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "full/child.txt", .data = "" });
    const empty_path = try tmpPath(&temporary, "empty");
    defer std.testing.allocator.free(empty_path);
    const full_path = try tmpPath(&temporary, "full");
    defer std.testing.allocator.free(full_path);

    try std.testing.expectError(error.IsDir, unlink(std.testing.io, empty_path));
    try std.testing.expectError(error.DirNotEmpty, rmdir(std.testing.io, full_path));
    try rmdir(std.testing.io, empty_path);
    try std.testing.expectError(error.FileNotFound, stat(std.testing.io, empty_path, true));
}

test "unlinkはsymlink自身を削除し参照先を残す" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target.txt", .data = "keep" });
    try temporary.dir.symLink(std.testing.io, "target.txt", "link.txt", .{});
    const link_path = try tmpPath(&temporary, "link.txt");
    defer std.testing.allocator.free(link_path);
    const target_path = try tmpPath(&temporary, "target.txt");
    defer std.testing.allocator.free(target_path);

    try unlink(std.testing.io, link_path);
    try std.testing.expectError(error.FileNotFound, stat(std.testing.io, link_path, false));
    _ = try stat(std.testing.io, target_path, true);
}

test "truncatePathは縮小・拡大・0サイズを反映し不足パスとディレクトリを拒否する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "data.bin", .data = "hello world" });
    const path = try tmpPath(&temporary, "data.bin");
    defer std.testing.allocator.free(path);

    // shrink: 11 -> 5 byte。末尾は切り捨てる。
    try truncatePath(std.testing.io, path, 5);
    const shrunk = try temporary.dir.readFileAlloc(std.testing.io, "data.bin", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(shrunk);
    try std.testing.expectEqualSlices(u8, "hello", shrunk);
    try std.testing.expectEqual(@as(u64, 5), (try stat(std.testing.io, path, true)).size);

    // grow: 5 -> 12 byte。拡張分は0埋め（sparse）。
    try truncatePath(std.testing.io, path, 12);
    const grown = try temporary.dir.readFileAlloc(std.testing.io, "data.bin", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(grown);
    try std.testing.expectEqual(@as(usize, 12), grown.len);
    try std.testing.expectEqualSlices(u8, "hello", grown[0..5]);
    for (grown[5..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    // zero-size: 中身を空にする。
    try truncatePath(std.testing.io, path, 0);
    try std.testing.expectEqual(@as(u64, 0), (try stat(std.testing.io, path, true)).size);

    const missing = try tmpPath(&temporary, "missing.bin");
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, truncatePath(std.testing.io, missing, 1));

    try temporary.dir.createDir(std.testing.io, "folder", .default_dir);
    const folder = try tmpPath(&temporary, "folder");
    defer std.testing.allocator.free(folder);
    try std.testing.expectError(error.IsDir, truncatePath(std.testing.io, folder, 1));

    // EACCES: 所有者でもwrite権限が無ければ拒否される。POSIXはroot以外で、
    // Windowsはread-only属性で再現する。
    if (builtin.os.tag == .windows or currentUid() != 0) {
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "readonly.bin", .data = "x" });
        const readonly_path = try tmpPath(&temporary, "readonly.bin");
        defer std.testing.allocator.free(readonly_path);
        try setFileReadOnly(readonly_path, true);
        // Windowsはread-onlyのままだと後片付けの削除に失敗するため戻す。
        defer setFileReadOnly(readonly_path, false) catch {};
        try std.testing.expectError(error.AccessDenied, truncatePath(std.testing.io, readonly_path, 1));
    }

    // FIFOは `truncate(2)` で即EINVALになる。open(O_WRONLY)を使う実装だと
    // 書込みopenが読取り側の接続までブロックし、この呼び出しが返らない。
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        const fifo_path = try tmpPath(&temporary, "pipe.fifo");
        defer std.testing.allocator.free(fifo_path);
        const mkfifo_fn = struct {
            extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
        }.mkfifo;
        const fifo_z = try std.testing.allocator.dupeZ(u8, fifo_path);
        defer std.testing.allocator.free(fifo_z);
        try std.testing.expectEqual(@as(c_int, 0), mkfifo_fn(fifo_z.ptr, 0o600));
        try std.testing.expectError(error.InvalidArgument, truncatePath(std.testing.io, fifo_path, 0));
    }
}

test "setTimestampsPathは明示時刻・now・既存値維持を反映する" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "times.txt", .data = "abc" });
    const path = try tmpPath(&temporary, "times.txt");
    defer std.testing.allocator.free(path);

    // サブ秒部を0.5秒にして、1秒粒度のFSなら1µs許容から外れるようにする。
    const atime: foundation.TimeNs = 1_600_000_000_500_000_000;
    const mtime: foundation.TimeNs = 1_600_000_005_750_000_000;
    try setTimestampsPath(std.testing.io, path, .{ .at = atime }, .{ .at = mtime });
    const updated = try stat(std.testing.io, path, true);
    try std.testing.expect(@abs(updated.atime_ns.? - atime) < std.time.ns_per_us);
    try std.testing.expect(@abs(updated.mtime_ns.? - mtime) < std.time.ns_per_us);

    // mtimeは既存値維持（UTIME_OMIT）、atimeだけ現在時刻へ。NOWがno-opなら
    // 2017年の既存値のままなので、実時刻（2026年以降）との差で検出できる。
    const old: foundation.TimeNs = 1_500_000_000_000_000_000;
    try setTimestampsPath(std.testing.io, path, .{ .at = old }, .{ .at = old });
    try setTimestampsPath(std.testing.io, path, .now, .unchanged);
    const after_now = try stat(std.testing.io, path, true);
    try std.testing.expect(@abs(after_now.mtime_ns.? - old) < std.time.ns_per_us);
    try std.testing.expect(after_now.atime_ns.? > old + std.time.ns_per_day);

    // read-only属性/権限のファイルにも時刻設定は成功する（write属性のみ必要。
    // truncateのEACCESとは対照的）。
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "readonly-utime.txt", .data = "x" });
    const readonly_path = try tmpPath(&temporary, "readonly-utime.txt");
    defer std.testing.allocator.free(readonly_path);
    try setFileReadOnly(readonly_path, true);
    defer setFileReadOnly(readonly_path, false) catch {};
    try setTimestampsPath(std.testing.io, readonly_path, .{ .at = atime }, .{ .at = mtime });
    const readonly_info = try stat(std.testing.io, readonly_path, true);
    try std.testing.expect(@abs(readonly_info.atime_ns.? - atime) < std.time.ns_per_us);
    try std.testing.expect(@abs(readonly_info.mtime_ns.? - mtime) < std.time.ns_per_us);

    // ディレクトリにも時刻設定できる（Windowsはbackup intentで開く）。
    try temporary.dir.createDir(std.testing.io, "times-dir", .default_dir);
    const dir_path = try tmpPath(&temporary, "times-dir");
    defer std.testing.allocator.free(dir_path);
    try setTimestampsPath(std.testing.io, dir_path, .{ .at = atime }, .{ .at = mtime });
    const dir_info = try stat(std.testing.io, dir_path, true);
    try std.testing.expect(@abs(dir_info.atime_ns.? - atime) < std.time.ns_per_us);
    try std.testing.expect(@abs(dir_info.mtime_ns.? - mtime) < std.time.ns_per_us);

    // 範囲外の明示時刻はEINVAL（POSIXのtime_t/WindowsのFILETIMEに収まらない）。
    try std.testing.expectError(error.InvalidTimestamp, setTimestampsPath(std.testing.io, path, .{ .at = std.math.maxInt(i128) }, .{ .at = 0 }));

    const missing = try tmpPath(&temporary, "missing-times.txt");
    defer std.testing.allocator.free(missing);
    // ATIME/MTIMEともnull（UTIME_OMIT）でもパス検証は行われ、ENOENTになる。
    try std.testing.expectError(error.FileNotFound, setTimestampsPath(std.testing.io, missing, .unchanged, .unchanged));
    try std.testing.expectError(error.FileNotFound, setTimestampsPath(std.testing.io, missing, .now, .now));
}

test "setTimestampsHandleはオープン中ハンドルの時刻を更新する" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "handle-times.txt", .data = "abc" });
    const path = try tmpPath(&temporary, "handle-times.txt");
    defer std.testing.allocator.free(path);

    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .write_only });
    defer file.close(std.testing.io);

    const atime: foundation.TimeNs = 1_500_000_000_500_000_000;
    const mtime: foundation.TimeNs = 1_500_000_010_750_000_000;
    try setTimestampsHandle(std.testing.io, file, .{ .at = atime }, .{ .at = mtime });
    const updated = try stat(std.testing.io, path, true);
    try std.testing.expect(@abs(updated.atime_ns.? - atime) < std.time.ns_per_us);
    try std.testing.expect(@abs(updated.mtime_ns.? - mtime) < std.time.ns_per_us);

    // ハンドル経路でもNOWと既存値維持が効く。
    try setTimestampsHandle(std.testing.io, file, .now, .unchanged);
    const after_now = try stat(std.testing.io, path, true);
    try std.testing.expect(@abs(after_now.mtime_ns.? - mtime) < std.time.ns_per_us);
    try std.testing.expect(after_now.atime_ns.? > mtime + std.time.ns_per_day);
}

test "windowsFiletimeFromNsは1601以前と範囲外をInvalidTimestampにする" {
    // 1970-01-01T00:00:00Z は FILETIME 116444736000000000。
    try std.testing.expectEqual(@as(i64, 116444736000000000), try windowsFiletimeFromNs(0));
    // 1601-01-01T00:00:00Z は FILETIME 0（「変更しない」の特別値）なので拒否する。
    try std.testing.expectError(error.InvalidTimestamp, windowsFiletimeFromNs(-11644473600000000000));
    try std.testing.expectError(error.InvalidTimestamp, windowsFiletimeFromNs(std.math.minInt(i128)));
    try std.testing.expectError(error.InvalidTimestamp, windowsFiletimeFromNs(std.math.maxInt(i128)));
}
