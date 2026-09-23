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

/// `ファイルシステム情報取得` が返す容量・inode統計。カタログ
/// `typeSchemas.fsInfo` の全フィールドを保持する。文字列2本は固定長
/// バッファ＋長さで持ち、呼び出し側にallocatorを要求しない。
pub const FsInfo = struct {
    /// `blocks`/`free`/`available` の単位となるブロックサイズ。
    /// Linuxは `f_frsize`（無ければ `f_bsize`）、macOSは `f_bsize`。
    block_size: u64 = 0,
    /// 全ブロック数（`f_blocks`）。
    blocks: u64 = 0,
    /// 空きブロック数。特権分を含む `f_bfree`。
    free: u64 = 0,
    /// 非特権ユーザが使える空きブロック数（`f_bavail`）。
    available: u64 = 0,
    /// 全inode数（`f_files`）。
    files: u64 = 0,
    /// 空きinode数（`f_ffree`）。
    free_files: u64 = 0,
    filesystem_type_len: usize = 0,
    filesystem_type: [fs_type_max]u8 = [_]u8{0} ** fs_type_max,
    filesystem_id_len: usize = 0,
    filesystem_id: [fs_id_max]u8 = [_]u8{0} ** fs_id_max,

    /// `filesystemType` の有効部分。macOSは `f_fstypename`（"apfs"等）、
    /// LinuxはFS magicの対応名。未知のmagicは `"0x????????"` 表記になる。
    pub fn filesystemType(self: *const FsInfo) []const u8 {
        return self.filesystem_type[0..self.filesystem_type_len];
    }

    /// `filesystemId` の有効部分。`f_fsid` の2本の32bit値を
    /// `"xxxxxxxx:xxxxxxxx"` 形式にしたもの。
    pub fn filesystemId(self: *const FsInfo) []const u8 {
        return self.filesystem_id[0..self.filesystem_id_len];
    }
};

const fs_type_max = 64;
const fs_id_max = 32;

fn setFsType(info: *FsInfo, name: []const u8) void {
    std.debug.assert(name.len <= fs_type_max);
    @memcpy(info.filesystem_type[0..name.len], name);
    info.filesystem_type_len = name.len;
}

fn setFsId(info: *FsInfo, first: i32, second: i32) void {
    const text = std.fmt.bufPrint(&info.filesystem_id, "{x:0>8}:{x:0>8}", .{
        @as(u32, @bitCast(first)),
        @as(u32, @bitCast(second)),
    }) catch unreachable;
    info.filesystem_id_len = text.len;
}

/// POSIXの `statfs` 相当。`path` が属するファイルシステムの容量・inode統計を
/// 返す。Linuxは `statfs(2)`、macOSは `statfs(2)` を使う。Windows/WASIは
/// 契約を満たす共通表現が無いため `error.OperationUnsupported`。
pub fn statfs(io: std.Io, path: []const u8) anyerror!FsInfo {
    _ = io;
    return switch (builtin.os.tag) {
        .linux => statfsLinux(path),
        .macos => statfsDarwin(path),
        else => error.OperationUnsupported,
    };
}

/// Linuxカーネルの `struct statfs`。`__statfs_word` は `long`、
/// fsblkcnt_t/fsfilcnt_t は `unsigned long`（LP64で64bit、ILP32で32bit）。
const LinuxStatfs = extern struct {
    f_type: c_long = 0,
    f_bsize: c_long = 0,
    f_blocks: c_ulong = 0,
    f_bfree: c_ulong = 0,
    f_bavail: c_ulong = 0,
    f_files: c_ulong = 0,
    f_ffree: c_ulong = 0,
    f_fsid: extern struct { val: [2]i32 = .{ 0, 0 } } = .{},
    f_namelen: c_long = 0,
    f_frsize: c_long = 0,
    f_flags: c_long = 0,
    f_spare: [4]c_long = .{ 0, 0, 0, 0 },
};

comptime {
    // 手書きのカーネルABIなのでLP64 Linuxターゲットでは宣言サイズを検証する。
    if (builtin.os.tag == .linux and (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64)) {
        std.debug.assert(@sizeOf(LinuxStatfs) == 120);
    }
}

fn statfsLinux(path: []const u8) anyerror!FsInfo {
    const posix_path = try std.posix.toPosixPath(path);
    var raw: LinuxStatfs = std.mem.zeroes(LinuxStatfs);
    while (true) {
        const result = std.os.linux.syscall2(.statfs, @intFromPtr(&posix_path), @intFromPtr(&raw));
        const errno = std.os.linux.errno(result);
        if (errno == .SUCCESS) break;
        if (errno == .INTR) continue;
        return linuxErrno(errno);
    }
    var info = FsInfo{
        // f_blocks/f_bfree/f_bavailはf_frsize単位のため、容量計算と
        // 整合するfrsizeを優先し0ならf_bsizeへ退避する（現行kernelでは
        // 両者一致が普通で、NFS等の一部FSのみ差が出る）。
        .block_size = @intCast(@max(if (raw.f_frsize > 0) raw.f_frsize else raw.f_bsize, 0)),
        .blocks = raw.f_blocks,
        .free = raw.f_bfree,
        .available = raw.f_bavail,
        .files = raw.f_files,
        .free_files = raw.f_ffree,
    };
    const type_name = linuxFsTypeName(raw.f_type);
    if (type_name.len != 0) {
        setFsType(&info, type_name);
    } else {
        // 未知のFS magicは16進数表記で返し、空文字にはしない。
        const text = std.fmt.bufPrint(&info.filesystem_type, "0x{x:0>8}", .{@as(u64, @bitCast(@as(i64, raw.f_type)))}) catch unreachable;
        info.filesystem_type_len = text.len;
    }
    setFsId(&info, raw.f_fsid.val[0], raw.f_fsid.val[1]);
    return info;
}

/// Linux `statfs` の `f_type`（FS magic）をファイルシステム名へ写す。
/// 同一magicを共有するFS群（ext2/3/4等）は識別できないため共通名を返す。
/// 未知は空文字を返し、呼び出し側が16進数表記へする。
fn linuxFsTypeName(magic: i64) []const u8 {
    return switch (@as(u64, @bitCast(magic))) {
        0xEF53 => "ext",
        0x01021994 => "tmpfs",
        0x9123683E => "btrfs",
        0x58465342 => "xfs",
        0x794C7630 => "overlayfs",
        0x9FA0 => "proc",
        0x62656572 => "sysfs",
        0x1CD1 => "devpts",
        0x6969 => "nfs",
        0x2FC12FC1 => "zfs",
        0xF2F52010 => "f2fs",
        0x2011BAB0 => "exfat",
        0x5346544E => "ntfs",
        0x65735546 => "fuse",
        0x4D44 => "vfat",
        0x858458F6 => "ramfs",
        0x73717368 => "squashfs",
        0xFF534D42 => "cifs",
        0x517B => "smb",
        0x63677270 => "cgroup2",
        0x0027E0EB => "cgroup",
        0x0187 => "autofs",
        0x64626720 => "debugfs",
        0x74726163 => "tracefs",
        0x4253584E => "apfs",
        0x482B => "hfsplus",
        0x4244 => "hfs",
        0x958458F6 => "hugetlbfs",
        0x19800202 => "mqueue",
        0xC36400 => "ceph",
        else => "",
    };
}

/// macOSの `struct statfs`（arm64は64bit inode版のみ存在）。
/// レイアウトはSDKの `sys/mount.h` で実測確認済み。
const DarwinStatfs = extern struct {
    f_bsize: u32 = 0,
    f_iosize: i32 = 0,
    f_blocks: u64 = 0,
    f_bfree: u64 = 0,
    f_bavail: u64 = 0,
    f_files: u64 = 0,
    f_ffree: u64 = 0,
    f_fsid: extern struct { val: [2]i32 = .{ 0, 0 } } = .{},
    f_owner: u32 = 0,
    f_type: u32 = 0,
    f_flags: u32 = 0,
    f_fssubtype: u32 = 0,
    f_fstypename: [16]u8 = [_]u8{0} ** 16,
    f_mntonname: [1024]u8 = [_]u8{0} ** 1024,
    f_mntfromname: [1024]u8 = [_]u8{0} ** 1024,
    f_flags_ext: u32 = 0,
    f_reserved: [7]u32 = .{0} ** 7,
};

comptime {
    std.debug.assert(@sizeOf(DarwinStatfs) == 2168);
}

fn statfsDarwin(path: []const u8) anyerror!FsInfo {
    // `statfs(2)` はZig 0.16 stdに宣言が無いためここで宣言する。
    const c_statfs = struct {
        extern "c" fn statfs(path: [*:0]const u8, buf: *DarwinStatfs) c_int;
    }.statfs;
    const posix_path = try std.posix.toPosixPath(path);
    var raw: DarwinStatfs = std.mem.zeroes(DarwinStatfs);
    while (true) {
        const result = c_statfs(&posix_path, &raw);
        if (result == 0) break;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        return fsPosixErrno(errno);
    }
    var info = FsInfo{
        .block_size = raw.f_bsize,
        .blocks = raw.f_blocks,
        .free = raw.f_bfree,
        .available = raw.f_bavail,
        .files = raw.f_files,
        .free_files = raw.f_ffree,
    };
    setFsType(&info, std.mem.sliceTo(&raw.f_fstypename, 0));
    setFsId(&info, raw.f_fsid.val[0], raw.f_fsid.val[1]);
    return info;
}

/// `ファイルデータ領域検索` / `ファイル空洞領域検索` の対象。
pub const SeekExtent = enum {
    /// `SEEK_DATA` 相当。`offset` 以降で最初にデータがある位置。
    data,
    /// `SEEK_HOLE` 相当。`offset` 以降で最初に空洞がある位置。
    hole,
};

/// オープン済み `file` のsparse領域を検索し、`offset` 以降の `extent`
/// 位置を返す。Linuxは `lseek(SEEK_DATA/SEEK_HOLE)`。macOS等ネイティブAPIを
/// 持たないPOSIXは「ファイル全体がデータ・空洞は末尾のみ」の保守的応答を
/// 返す（sparseをデータとみなすため読み出し結果は正しく、効率のみ落ちる）。
/// Windows/WASIは `error.OperationUnsupported`。負の `offset` や、
/// data検索で `offset` がファイル末尾以降の場合はPOSIXのENXIO相当として
/// `error.InvalidOffset`（EINVAL）。
pub fn seekExtent(io: std.Io, file: std.Io.File, offset: i64, extent: SeekExtent) anyerror!i64 {
    if (offset < 0) return error.InvalidOffset;
    return switch (builtin.os.tag) {
        .linux => seekExtentLinux(file, offset, extent),
        .windows, .wasi => error.OperationUnsupported,
        else => seekExtentEmulated(io, file, offset, extent),
    };
}

// asm-generic unistd.h の SEEK_DATA/SEEK_HOLE。
const linux_seek_data: usize = 3;
const linux_seek_hole: usize = 4;

fn seekExtentLinux(file: std.Io.File, offset: i64, extent: SeekExtent) anyerror!i64 {
    const whence: usize = switch (extent) {
        .data => linux_seek_data,
        .hole => linux_seek_hole,
    };
    while (true) {
        const result = std.os.linux.lseek(file.handle, offset, whence);
        const errno = std.os.linux.errno(result);
        if (errno == .SUCCESS) return @bitCast(result);
        if (errno == .INTR) continue;
        return linuxErrno(errno);
    }
}

fn seekExtentEmulated(io: std.Io, file: std.Io.File, offset: i64, extent: SeekExtent) anyerror!i64 {
    const end = file.length(io) catch |failure| switch (failure) {
        error.AccessDenied => return error.OperationUnsupported,
        else => return failure,
    };
    const end_i64 = std.math.cast(i64, end) orelse return error.InvalidOffset;
    return switch (extent) {
        // sparse非対応とみなせるFSでは全領域がデータで、空洞はファイル末尾に
        // のみ存在するというPOSIX最小モデル。data検索でoffsetが末尾以降なら
        // SEEK_DATAのENXIO相当（EINVAL）、hole検索は末尾の仮想的な空洞を返す
        // （offsetが末尾を超える場合のみENXIO相当）。
        .data => if (offset >= end_i64) error.InvalidOffset else offset,
        .hole => if (offset > end_i64) error.InvalidOffset else end_i64,
    };
}

/// `ファイルクローン`。reflink/CoWクローンを `source` から `destination`
/// へ作る。`destination` が存在する場合は `error.PathAlreadyExists`
/// （EEXIST）。`mode` が null なら `source` の権限を継承し、指定時はその
/// 権限を適用する。非対応OS/FSでは `error.OperationUnsupported`（ENOTSUP）
/// で、通常コピーへのフォールバックは行わない（reflinkでない成功を返さ
/// ない）。FSを跨ぐ場合は `error.CrossDevice`（EXDEV）。
pub fn reflink(io: std.Io, source: []const u8, destination: []const u8, mode: ?u32) anyerror!void {
    // 「MODE省略時はSRCの権限」をLinux FICLONE（DSTは生成時modeのまま）でも
    // 満たすため先にstatを取る。
    const metadata = try stat(io, source, true);
    // 通常ファイル以外（ディレクトリ・fifo・socket・device等）はファイル
    // クローン契約外のためENOTSUPとする。FICLONEはEISDIR/EINVALを返し、
    // clonefileはdirも複製する上、fifoのopenat(O_RDONLY)はwriter待ちで
    // 無限ブロックし得るため、開く前に種別で拒否する。
    if (metadata.kind != .file) return error.OperationUnsupported;
    return switch (builtin.os.tag) {
        .linux => cloneFileLinux(source, destination, mode orelse metadata.mode),
        .macos => cloneFileDarwin(source, destination, mode),
        else => error.OperationUnsupported,
    };
}

// Linux `FICLONE` ioctl。dst fdへsrc fdのデータをCoW複製する。
const ficlone: u32 = 0x4004_9409;

fn cloneFileLinux(source: []const u8, destination: []const u8, mode: u32) anyerror!void {
    const source_fd = try std.posix.openat(std.posix.AT.FDCWD, source, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer _ = std.os.linux.close(source_fd);
    // O_EXCLで既存DSTをEEXISTにする。生成権限は0o600固定で、複製後に
    // SRC権限/明示MODEへ揃える（生成時のumaskに結果を左右させない）。
    const destination_fd = try std.posix.openat(std.posix.AT.FDCWD, destination, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
    var keep = false;
    defer {
        _ = std.os.linux.close(destination_fd);
        // 複製・権限適用の途中失敗では半端なDSTを残さない。
        if (!keep) unlinkPosixPath(destination) catch {};
    }
    while (true) {
        const result = std.os.linux.ioctl(destination_fd, ficlone, @intCast(source_fd));
        const errno = std.os.linux.errno(result);
        if (errno == .SUCCESS) break;
        if (errno == .INTR) continue;
        // この時点の引数は検証済みfdのみのため、EINVALはFICLONE未対応
        // （古いkernel/FS）を意味し、契約のENOTSUPへ丸める。
        if (errno == .INVAL) return error.OperationUnsupported;
        return linuxErrno(errno);
    }
    const apply: std.os.linux.mode_t = @intCast(mode);
    while (true) {
        const result = std.os.linux.fchmod(destination_fd, apply);
        const errno = std.os.linux.errno(result);
        if (errno == .SUCCESS) break;
        if (errno == .INTR) continue;
        return linuxErrno(errno);
    }
    keep = true;
}

fn cloneFileDarwin(source: []const u8, destination: []const u8, mode: ?u32) anyerror!void {
    // macOS固有の `clonefile(2)`。APFSではCoWクローンを作り、既存DSTは
    // EEXIST、非対応FSはENOTSUPを返す。Zig 0.16 stdに宣言が無いためここで
    // 宣言する。
    const c_clonefile = struct {
        extern "c" fn clonefile(source: [*:0]const u8, destination: [*:0]const u8, flags: c_int) c_int;
    }.clonefile;
    const source_path = try std.posix.toPosixPath(source);
    const destination_path = try std.posix.toPosixPath(destination);
    while (true) {
        const result = c_clonefile(&source_path, &destination_path, 0);
        if (result == 0) break;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        // clonefile自体の失敗（既存DSTのEEXIST等）ではDSTに触れない。
        return fsPosixErrno(errno);
    }
    // ここから先はclonefileが作ったDSTへの操作。権限適用の途中失敗では
    // 半端なDSTを残さない（Linux側と同じ）。
    var keep = false;
    defer if (!keep) unlinkPosixPath(destination) catch {};
    // 明示MODEのみ適用する。省略時はclonefileがSRCの権限をそのまま複製する。
    if (mode) |value| {
        const apply = std.math.cast(std.c.mode_t, value) orelse return error.InvalidArgument;
        while (true) {
            const result = std.c.fchmodat(std.c.AT.FDCWD, &destination_path, apply, 0);
            if (result == 0) break;
            const errno = std.c.errno(result);
            if (errno == .INTR) continue;
            return fsPosixErrno(errno);
        }
    }
    keep = true;
}

fn unlinkPosixPath(path: []const u8) !void {
    const posix_path = try std.posix.toPosixPath(path);
    while (true) {
        const result = std.c.unlink(&posix_path);
        if (result == 0) return;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        return fsPosixErrno(errno);
    }
}

/// `ファイル領域確保`。`offset` から `size` バイトの領域を事前確保する。
/// 範囲がファイル末尾を超える場合はファイルサイズを伸ばす（fallocate相当）。
/// Linuxは `fallocate(2)`、macOSは `fcntl(F_PREALLOCATE)` で物理領域を確保し
/// `ftruncate` で論理サイズを合わせる。`size == 0` は `error.InvalidSize`
/// （EINVAL）。Windows/WASIは `error.OperationUnsupported`。
pub fn allocate(io: std.Io, file: std.Io.File, offset: i64, size: u64) anyerror!void {
    if (offset < 0) return error.InvalidOffset;
    if (size == 0) return error.InvalidSize;
    return switch (builtin.os.tag) {
        .linux => allocateLinux(file, offset, size),
        .macos => allocateDarwin(io, file, offset, size),
        else => error.OperationUnsupported,
    };
}

fn allocateLinux(file: std.Io.File, offset: i64, size: u64) anyerror!void {
    const length = std.math.cast(i64, size) orelse return error.InvalidSize;
    while (true) {
        const result = std.os.linux.fallocate(file.handle, 0, offset, length);
        const errno = std.os.linux.errno(result);
        if (errno == .SUCCESS) return;
        if (errno == .INTR) continue;
        return linuxErrno(errno);
    }
}

// `fcntl(F_PREALLOCATE)` の `fstore_t`。
const DarwinFstore = extern struct {
    fst_flags: u32 = 0,
    fst_posmode: i32 = 0,
    fst_offset: i64 = 0,
    fst_length: i64 = 0,
    fst_bytesalloc: i64 = 0,
};

// fcntl.h の F_PREALLOCATE 用定数。
const f_allocateall: u32 = 0x00000004;
const f_peofposmode: i32 = 3;

fn allocateDarwin(io: std.Io, file: std.Io.File, offset: i64, size: u64) anyerror!void {
    const end = std.math.cast(u64, @as(u128, @intCast(offset)) + @as(u128, size)) orelse return error.InvalidSize;
    const current = file.length(io) catch |failure| switch (failure) {
        error.AccessDenied => return error.OperationUnsupported,
        else => return failure,
    };
    // 範囲がEOF内なら新規確保は不要（fallocate同様に成功のまま返す）。
    // 分岐: LinuxはEOF内のholeにもブロックを確保し、読取専用handleは
    // EBADFを返すが、macOSのF_PREALLOCATEはF_PEOFPOSMODE（EOF以降）と
    // F_VOLPOSMODE（ボリューム先頭からの確保）しか範囲を指定できず、
    // EOF内の任意位置を指せない。file-position modeは存在しないため
    // ここはno-opとし、契約上の差分として許容する。
    if (end <= current) return;
    const extra = std.math.cast(i64, end - current) orelse return error.InvalidSize;
    var store = DarwinFstore{
        .fst_flags = f_allocateall,
        .fst_posmode = f_peofposmode,
        .fst_offset = 0,
        .fst_length = extra,
        .fst_bytesalloc = 0,
    };
    while (true) {
        const result = std.c.fcntl(file.handle, std.c.F.PREALLOCATE, @intFromPtr(&store));
        if (result == 0) break;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        return fsPosixErrno(errno);
    }
    // F_ALLOCATEALLでも不足し得るため、実確保量を確認する。
    if (store.fst_bytesalloc < extra) return error.NoSpaceLeft;
    // F_PREALLOCATEは論理EOFを動かさないため、fallocateと同じく範囲末尾まで
    // 論理サイズを伸ばす。
    const new_length = std.math.cast(std.c.off_t, end) orelse return error.InvalidSize;
    while (true) {
        const result = std.c.ftruncate(file.handle, new_length);
        if (result == 0) return;
        const errno = std.c.errno(result);
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
        .EXIST => error.PathAlreadyExists,
        .XDEV => error.CrossDevice,
        .MLINK => error.LinkQuotaExceeded,
        .TXTBSY => error.FileBusy,
        .NOMEM => error.SystemResources,
        .INVAL, .FAULT => error.InvalidArgument,
        .ROFS => error.ReadOnlyFileSystem,
        .BADF => error.BadFileDescriptor,
        .FBIG => error.FileTooBig,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        .NOSYS => error.Unsupported,
        .OPNOTSUPP, .NOTTY => error.OperationUnsupported,
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
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .EXIST => error.PathAlreadyExists,
        .XDEV => error.CrossDevice,
        .MLINK => error.LinkQuotaExceeded,
        .TXTBSY => error.FileBusy,
        .NOMEM => error.SystemResources,
        .INVAL => error.InvalidArgument,
        .ROFS => error.ReadOnlyFileSystem,
        .BADF => error.BadFileDescriptor,
        .FBIG => error.FileTooBig,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        .NOSYS => error.Unsupported,
        .OPNOTSUPP, .NOTTY => error.OperationUnsupported,
        // lseek SEEK_DATA/HOLEのENXIO（offsetが末尾以降）やESPIPEはEINVAL相当。
        .SPIPE, .NXIO, .OVERFLOW => error.InvalidArgument,
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

// Zig 0.16 std.cに宣言が無いためテスト用にここで宣言する。
const test_mkfifo = struct {
    extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
}.mkfifo;

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

test "statfsは実在パスのファイルシステム統計を返し、不正パスを拒否する" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    const info = try statfs(std.testing.io, directory);
    try std.testing.expect(info.block_size > 0);
    try std.testing.expect(info.blocks > 0);
    try std.testing.expect(info.free > 0);
    // 非特権ユーザの空きは特権分を含む空き以下になる。
    try std.testing.expect(info.available <= info.free);
    try std.testing.expect(info.files > 0);
    try std.testing.expect(info.filesystemType().len > 0);
    try std.testing.expect(info.filesystemId().len > 0);
    if (builtin.os.tag == .macos) {
        // APFS/HFS+ではfstypenameが埋まる。
        try std.testing.expect(std.mem.eql(u8, info.filesystemType(), "apfs") or
            std.mem.eql(u8, info.filesystemType(), "hfs"));
    }

    // 不在パスはENOENT、ファイルの中を潜るパスはENOTDIR。
    const missing = try tmpPath(&temporary, "missing-dir");
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, statfs(std.testing.io, missing));
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "leaf.txt", .data = "x" });
    const leaf = try tmpPath(&temporary, "leaf.txt");
    defer std.testing.allocator.free(leaf);
    const under_file = try std.fs.path.join(std.testing.allocator, &.{ leaf, "child" });
    defer std.testing.allocator.free(under_file);
    try std.testing.expectError(error.NotDir, statfs(std.testing.io, under_file));
}

test "reflinkはCoW複製を作り、既存DST・不在SRC・ディレクトリを拒否する" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "src.txt", .data = "clone me" });
    const source = try tmpPath(&temporary, "src.txt");
    defer std.testing.allocator.free(source);
    const destination = try tmpPath(&temporary, "dst.txt");
    defer std.testing.allocator.free(destination);

    reflink(std.testing.io, source, destination, null) catch |failure| {
        // tmpfs等のCoW非対応FSではENOTSUPになる。
        if (failure == error.OperationUnsupported) return error.SkipZigTest;
        return failure;
    };
    const original = try stat(std.testing.io, source, true);
    const cloned = try stat(std.testing.io, destination, true);
    try std.testing.expectEqual(@as(u64, 8), cloned.size);
    // MODE省略時はSRCの権限を継承する。
    try std.testing.expectEqual(original.mode, cloned.mode);
    // 複製は独立したinode（CoW共有はextent単位で、inodeは別）。
    try std.testing.expect(cloned.inode != original.inode);
    const data = try temporary.dir.readFileAlloc(std.testing.io, "dst.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("clone me", data);

    // 既存DSTはEEXIST。失敗しても既存DSTの内容は破壊されない。
    try std.testing.expectError(error.PathAlreadyExists, reflink(std.testing.io, source, destination, null));
    const surviving = try temporary.dir.readFileAlloc(std.testing.io, "dst.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(surviving);
    try std.testing.expectEqualStrings("clone me", surviving);
    // 不在SRCはENOENT。
    const missing = try tmpPath(&temporary, "missing.txt");
    defer std.testing.allocator.free(missing);
    const other = try tmpPath(&temporary, "other.txt");
    defer std.testing.allocator.free(other);
    try std.testing.expectError(error.FileNotFound, reflink(std.testing.io, missing, other, null));
    // ディレクトリSRCはファイルクローン契約外のためENOTSUP。
    const dir_path = try tmpPath(&temporary, ".");
    defer std.testing.allocator.free(dir_path);
    const dir_dst = try tmpPath(&temporary, "dir-clone");
    defer std.testing.allocator.free(dir_dst);
    try std.testing.expectError(error.OperationUnsupported, reflink(std.testing.io, dir_path, dir_dst, null));
    // fifo等の通常ファイル以外もENOTSUP。Linuxのopenat(O_RDONLY)はfifoで
    // writer待ちに無限ブロックするため、種別で事前拒否する必要がある。
    const fifo_path = try tmpPath(&temporary, "pipe.fifo");
    defer std.testing.allocator.free(fifo_path);
    const posix_fifo = try std.posix.toPosixPath(fifo_path);
    try std.testing.expectEqual(@as(c_int, 0), test_mkfifo(&posix_fifo, 0o600));
    const fifo_dst = try tmpPath(&temporary, "fifo-clone");
    defer std.testing.allocator.free(fifo_dst);
    try std.testing.expectError(error.OperationUnsupported, reflink(std.testing.io, fifo_path, fifo_dst, null));

    // 明示MODEはSRCの権限を上書きする。
    const third = try tmpPath(&temporary, "third.txt");
    defer std.testing.allocator.free(third);
    reflink(std.testing.io, source, third, 0o777) catch |failure| {
        if (failure == error.OperationUnsupported) return error.SkipZigTest;
        return failure;
    };
    try std.testing.expectEqual(@as(u32, 0o777), (try stat(std.testing.io, third, true)).mode);
}

test "seekExtentはsparseファイルのデータ・空洞位置を返す" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // 先頭4byteにデータ、[4, 8192)が空洞、8192以降にデータのsparseファイル。
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "sparse.bin", .data = "data" });
    const path = try tmpPath(&temporary, "sparse.bin");
    defer std.testing.allocator.free(path);
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "tail", 8192);

    // data: offset 0ではデータ開始0を返す。offsetが末尾以降はENXIO相当。
    try std.testing.expectEqual(@as(i64, 0), try seekExtent(std.testing.io, file, 0, .data));
    try std.testing.expectError(error.InvalidOffset, seekExtent(std.testing.io, file, 8196, .data));
    try std.testing.expectError(error.InvalidOffset, seekExtent(std.testing.io, file, 99999, .data));
    // hole: Linuxの実holeはブロック境界（4KiB）に揃うため[4, 8196]の範囲で検証し、
    // emulated経路（macOS等）は末尾の仮想空洞8196を返す。
    const hole_at = try seekExtent(std.testing.io, file, 0, .hole);
    if (builtin.os.tag == .linux) {
        try std.testing.expect(hole_at >= 4 and hole_at <= 8196);
    } else {
        try std.testing.expectEqual(@as(i64, 8196), hole_at);
    }
    try std.testing.expectEqual(@as(i64, 8196), try seekExtent(std.testing.io, file, 8196, .hole));
    // 負のoffsetはEINVAL。
    try std.testing.expectError(error.InvalidOffset, seekExtent(std.testing.io, file, -1, .data));
    try std.testing.expectError(error.InvalidOffset, seekExtent(std.testing.io, file, -1, .hole));
}

test "allocateは領域を確保し末尾以降の範囲でサイズを伸ばす" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "alloc.bin", .data = "xy" });
    const path = try tmpPath(&temporary, "alloc.bin");
    defer std.testing.allocator.free(path);
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_write });
    defer file.close(std.testing.io);

    // EOF内の確保はサイズを変えない。
    try allocate(std.testing.io, file, 0, 2);
    try std.testing.expectEqual(@as(u64, 2), try file.length(std.testing.io));
    // EOFを超える範囲の確保はサイズを伸ばす（fallocate相当）。
    try allocate(std.testing.io, file, 0, 4096);
    try std.testing.expectEqual(@as(u64, 4096), try file.length(std.testing.io));
    try allocate(std.testing.io, file, 8192, 128);
    try std.testing.expectEqual(@as(u64, 8320), try file.length(std.testing.io));
    // 確保した領域は0埋めで読める。
    var buffer: [8]u8 = undefined;
    const read_count = try file.readPositionalAll(std.testing.io, &buffer, 4096);
    try std.testing.expectEqual(@as(usize, 8), read_count);
    for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    // 負のoffsetとsize=0はEINVAL。
    try std.testing.expectError(error.InvalidOffset, allocate(std.testing.io, file, -1, 8));
    try std.testing.expectError(error.InvalidSize, allocate(std.testing.io, file, 0, 0));
}
