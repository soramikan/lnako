const std = @import("std");
const builtin = @import("builtin");
const foundation = @import("low_level_foundation.zig");
const low_level_fs = @import("low_level_fs.zig");

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
        // ILP32 Linuxはf_blocks等が32bit幅でstatfs64側のABIが必要になるため、
        // LP64のみ対応とし他アーチでは失敗側へ倒す。
        .linux => if (builtin.target.ptrBitWidth() == 64) statfsLinux(path) else error.OperationUnsupported,
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
        return low_level_fs.linuxErrno(errno);
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
        return low_level_fs.fsPosixErrno(errno);
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
///
/// lseek相当の契約として、成功時は `file` のfd位置が結果位置へ移動する
/// （emulated経路も同じ副作用を持つ）。失敗時は位置を変えない。
pub fn seekExtent(io: std.Io, file: std.Io.File, offset: i64, extent: SeekExtent) anyerror!i64 {
    // 非対応OSは引数に関わらずENOTSUP（OS判定を先に行う）。
    switch (builtin.os.tag) {
        .windows, .wasi => return error.OperationUnsupported,
        else => {},
    }
    if (offset < 0) return error.InvalidOffset;
    return switch (builtin.os.tag) {
        .linux => seekExtentLinux(io, file, offset, extent),
        .windows, .wasi => unreachable,
        else => seekExtentEmulated(io, file, offset, extent),
    };
}

// asm-generic unistd.h の SEEK_DATA/SEEK_HOLE。
const linux_seek_data: usize = 3;
const linux_seek_hole: usize = 4;

fn seekExtentLinux(io: std.Io, file: std.Io.File, offset: i64, extent: SeekExtent) anyerror!i64 {
    const whence: usize = switch (extent) {
        .data => linux_seek_data,
        .hole => linux_seek_hole,
    };
    while (true) {
        const result = std.os.linux.lseek(file.handle, offset, whence);
        const errno = std.os.linux.errno(result);
        // errno確認済みのため負値は来ず、32bitでもusize→i64が安全に入る。
        if (errno == .SUCCESS) return @intCast(result);
        if (errno == .INTR) continue;
        // SEEK_HOLEでoffset==EOFのとき、固定長llseekの `offset >= size` 分岐を
        // 持つFS（ext4等）はENXIOを返す。POSIXの暗黙の末尾空洞としてemulated
        // 経路と同じくEOF位置を返し、fd位置も成功相当へ揃える。offsetがEOFを
        // 超える場合とSEEK_DATAのENXIOは従来どおりInvalidOffset。
        if (errno == .NXIO and extent == .hole) {
            const end = file.length(io) catch |failure| switch (failure) {
                error.AccessDenied => return error.OperationUnsupported,
                else => return failure,
            };
            if (std.math.cast(i64, end)) |end_i64| {
                if (offset == end_i64) {
                    const pos = std.os.linux.lseek(file.handle, end_i64, std.os.linux.SEEK.SET);
                    if (std.os.linux.errno(pos) == .SUCCESS) return end_i64;
                }
            }
        }
        return low_level_fs.linuxErrno(errno);
    }
}

fn seekExtentEmulated(io: std.Io, file: std.Io.File, offset: i64, extent: SeekExtent) anyerror!i64 {
    const end = file.length(io) catch |failure| switch (failure) {
        error.AccessDenied => return error.OperationUnsupported,
        else => return failure,
    };
    const end_i64 = std.math.cast(i64, end) orelse return error.InvalidOffset;
    const result = switch (extent) {
        // sparse非対応とみなせるFSでは全領域がデータで、空洞はファイル末尾に
        // のみ存在するというPOSIX最小モデル。data検索でoffsetが末尾以降なら
        // SEEK_DATAのENXIO相当（EINVAL）、hole検索は末尾の仮想的な空洞を返す
        // （offsetが末尾を超える場合のみENXIO相当）。
        .data => if (offset >= end_i64) return error.InvalidOffset else offset,
        .hole => if (offset > end_i64) return error.InvalidOffset else end_i64,
    };
    // lseek相当の契約としてfd位置を結果位置へ揃える（Linux経路と同じ副作用）。
    // 失敗時は位置を変えない。
    const posix_result = std.math.cast(std.c.off_t, result) orelse return error.InvalidOffset;
    while (true) {
        const seeked = std.c.lseek(file.handle, posix_result, std.c.SEEK.SET);
        if (seeked >= 0) break;
        const errno = std.c.errno(seeked);
        if (errno == .INTR) continue;
        return low_level_fs.fsPosixErrno(errno);
    }
    return result;
}

/// `ファイルクローン`。reflink/CoWクローンを `source` から `destination`
/// へ作る。`destination` が存在する場合は `error.PathAlreadyExists`
/// （EEXIST）。`mode` が null なら `source` の権限を継承し、指定時はその
/// 権限を適用する。複製は `destination` の親ディレクトリ内の一時名へ行い、
/// 権限適用後にno-replaceなrenameで原子的に公開するため、途中失敗しても
/// 既存・第三者の `destination` を破壊しない。非対応OS/FSでは
/// `error.OperationUnsupported`（ENOTSUP）で、通常コピーへのフォール
/// バックは行わない（reflinkでない成功を返さない）。FSを跨ぐ場合は
/// `error.CrossDevice`（EXDEV）。
pub fn reflink(io: std.Io, source: []const u8, destination: []const u8, mode: ?u32) anyerror!void {
    // 非対応OSはSRCの有無・種別・MODEに関わらずENOTSUPとする。低レイヤー
    // POSIX命令と同じくOS判定を先に行い、SRC不在のENOENT等がENOTSUPを
    // 隠さないようにする（statはOS依存のため後置できない）。
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.OperationUnsupported,
    }
    // MODE上限は全OSで共通に検証する。plugin層も検証するが、直接呼出しでは
    // Linuxが下位bitを黙って使いDarwinがInvalidArgumentになる非対称があった。
    if (mode) |value| {
        if (value > foundation.max_permission_mode) return error.InvalidArgument;
    }
    // 不在SRCのENOENTを早く返し、通常ファイル以外（ディレクトリ・fifo・
    // socket・device等）をファイルクローン契約外として開く前に拒否する。
    // FICLONEはEISDIR/EINVALを返し、clonefileはdirも複製する上、fifoの
    // openat(O_RDONLY)はwriter待ちで無限ブロックし得るため種別で事前拒否
    // する（Linux側はopenしたfdのstatxで再検査し、権限継承もfd由来）。
    const metadata = try low_level_fs.stat(io, source, true);
    if (metadata.kind != .file) return error.OperationUnsupported;
    return switch (builtin.os.tag) {
        .linux => cloneFileLinux(source, destination, mode),
        .macos => cloneFileDarwin(source, destination, mode),
        else => unreachable,
    };
}

// 複製中間物に使う一時名の連番。pidと組み合わせて同一ディレクトリ内で
// 他プロセスとも衝突しない名前にする。
var clone_temp_sequence = std.atomic.Value(u32).init(0);

/// DSTの親ディレクトリ内に作る非公開の一時名。同じFS内に置くことで
/// renameでの原子公開が成立し、失敗時のcleanupがこの一意名だけを対象に
/// するため既存・差し替え済みのDSTを誤って消すことがない。
fn cloneTempPath(buffer: []u8, destination: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(destination) orelse ".";
    const sequence = clone_temp_sequence.fetchAdd(1, .monotonic);
    const pid: u32 = switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
    return std.fmt.bufPrint(buffer, "{s}{c}.lnako-clone-{d}-{d}", .{ parent, std.fs.path.sep, pid, sequence }) catch return error.NameTooLong;
}

// Linux `FICLONE` ioctl。dst fdへsrc fdのデータをCoW複製する。
const ficlone: u32 = 0x4004_9409;

fn cloneFileLinux(source: []const u8, destination: []const u8, mode: ?u32) anyerror!void {
    // statからopenの間にSRCがfifo等へ差し替えられるTOCTOUを塞ぐため、
    // NONBLOCKで開きfd上の種別を再検査する（fifo O_RDONLYのwriter待ち
    // ブロックを防ぐ。通常ファイルではNONBLOCKは無害）。
    const source_fd = try std.posix.openat(std.posix.AT.FDCWD, source, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    defer _ = std.os.linux.close(source_fd);
    var raw: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
    while (true) {
        const result = std.os.linux.statx(source_fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true }, &raw);
        const errno = std.os.linux.errno(result);
        if (errno == .SUCCESS) break;
        if (errno == .INTR) continue;
        return low_level_fs.linuxErrno(errno);
    }
    if (low_level_fs.linuxKind(raw.mode) != .file) return error.OperationUnsupported;
    // MODE省略時は「実際に複製したfd」の権限を継承する。statからopenの間に
    // SRCが別ファイルへ置換された場合でも、内容と権限が別由来にならない。
    const apply: std.os.linux.mode_t = mode orelse @as(u32, raw.mode) & 0o7777;
    // 一時名で作成しrenameat2(NOREPLACE)で原子公開する。途中失敗のcleanupは
    // 一意の一時名だけを対象にするため、差し替え済みの無関係なDSTを消さない。
    // 生成権限は0o600固定で、複製後にSRC権限/明示MODEへ揃える。
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp = try cloneTempPath(&temp_buffer, destination);
    const temp_path = try std.posix.toPosixPath(temp);
    const destination_path = try std.posix.toPosixPath(destination);
    const destination_fd = try std.posix.openat(std.posix.AT.FDCWD, &temp_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
    var keep = false;
    defer {
        _ = std.os.linux.close(destination_fd);
        // 複製・権限適用・公開の途中失敗では自作物の一時名のみ除去する。
        if (!keep) unlinkPosixPath(temp) catch {};
    }
    while (true) {
        const result = std.os.linux.ioctl(destination_fd, ficlone, @intCast(source_fd));
        const errno = std.os.linux.errno(result);
        if (errno == .SUCCESS) break;
        if (errno == .INTR) continue;
        // この時点の引数は検証済みfdのみのため、EINVALはFICLONE未対応
        // （古いkernel/FS）を意味し、契約のENOTSUPへ丸める。
        if (errno == .INVAL) return error.OperationUnsupported;
        return low_level_fs.linuxErrno(errno);
    }
    while (true) {
        const result = std.os.linux.fchmod(destination_fd, apply);
        const errno = std.os.linux.errno(result);
        if (errno == .SUCCESS) break;
        if (errno == .INTR) continue;
        return low_level_fs.linuxErrno(errno);
    }
    while (true) {
        const result = std.os.linux.renameat2(std.posix.AT.FDCWD, &temp_path, std.posix.AT.FDCWD, &destination_path, .{ .NOREPLACE = true });
        const errno = std.os.linux.errno(result);
        if (errno == .SUCCESS) break;
        if (errno == .INTR) continue;
        // NOREPLACEのEEXISTに加え、既存DSTがディレクトリのEISDIRも
        // 「既存DSTがある」契約のEEXISTとして扱う。
        if (errno == .EXIST or errno == .ISDIR) return error.PathAlreadyExists;
        return low_level_fs.linuxErrno(errno);
    }
    keep = true;
}

fn cloneFileDarwin(source: []const u8, destination: []const u8, mode: ?u32) anyerror!void {
    // macOS固有の `clonefile(2)` と `renamex_np(RENAME_EXCL)`。APFSでは
    // CoWクローンを作り、既存DSTはEEXIST、非対応FSはENOTSUPを返す。
    // Zig 0.16 stdに宣言が無いためここで宣言する。
    const c_clonefile = struct {
        extern "c" fn clonefile(source: [*:0]const u8, destination: [*:0]const u8, flags: c_int) c_int;
    }.clonefile;
    const c_renamex = struct {
        extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;
    }.renamex_np;
    const rename_excl: c_uint = 0x0004;
    const source_path = try std.posix.toPosixPath(source);
    const destination_path = try std.posix.toPosixPath(destination);
    // Linux側と同じく一時名へ複製して原子公開する。
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp = try cloneTempPath(&temp_buffer, destination);
    const temp_path = try std.posix.toPosixPath(temp);
    while (true) {
        const result = c_clonefile(&source_path, &temp_path, 0);
        if (result == 0) break;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        // clonefile自体の失敗ではDST・一時名ともに作成されていない。
        return low_level_fs.fsPosixErrno(errno);
    }
    // ここから先はclonefileが作った一時物への操作。権限適用・公開の途中
    // 失敗では自作物の一時名のみ除去する（差し替え済みDSTを消さない）。
    var keep = false;
    defer if (!keep) unlinkPosixPath(temp) catch {};
    // 明示MODEのみ適用する。省略時はclonefileがSRCの権限をそのまま複製する。
    // fchmodatのパス再解決で差し替えsymlinkへchmodしないよう、O_NOFOLLOWで
    // fdを取りfdへfchmodする（Linux側と同じくfdベースで権限を適用する）。
    if (mode) |value| {
        const apply = std.math.cast(std.c.mode_t, value) orelse return error.InvalidArgument;
        const dst_fd = try openDarwinReadOnlyNoFollow(&temp_path);
        defer _ = std.c.close(dst_fd);
        while (true) {
            const result = std.c.fchmod(dst_fd, apply);
            if (result == 0) break;
            const errno = std.c.errno(result);
            if (errno == .INTR) continue;
            return low_level_fs.fsPosixErrno(errno);
        }
    }
    while (true) {
        const result = c_renamex(&temp_path, &destination_path, rename_excl);
        if (result == 0) break;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        // EXCLのEEXISTに加え、既存DSTがディレクトリのEISDIRも「既存DSTが
        // ある」契約のEEXISTとして扱う。
        if (errno == .EXIST or errno == .ISDIR) return error.PathAlreadyExists;
        return low_level_fs.fsPosixErrno(errno);
    }
    keep = true;
}

// O_NOFOLLOWでsymlink差し替えを拒否してfdを取る補助。clonefileが作った
// DSTの権限適用をfdベースで行うために使う。
fn openDarwinReadOnlyNoFollow(path: [*:0]const u8) !std.c.fd_t {
    while (true) {
        const result = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
        if (result >= 0) return result;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        return low_level_fs.fsPosixErrno(errno);
    }
}

fn unlinkPosixPath(path: []const u8) !void {
    const posix_path = try std.posix.toPosixPath(path);
    if (builtin.os.tag == .linux) {
        while (true) {
            const result = std.os.linux.unlink(&posix_path);
            const errno = std.os.linux.errno(result);
            if (errno == .SUCCESS) return;
            if (errno == .INTR) continue;
            return low_level_fs.linuxErrno(errno);
        }
    }
    while (true) {
        const result = std.c.unlink(&posix_path);
        if (result == 0) return;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        return low_level_fs.fsPosixErrno(errno);
    }
}

/// `ファイル領域確保`。`offset` から `size` バイトの領域を事前確保する。
/// 範囲がファイル末尾を超える場合はファイルサイズを伸ばす（fallocate相当）。
/// Linuxは `fallocate(2)`、macOSは `fcntl(F_PREALLOCATE)` で物理領域を確保し
/// `ftruncate` で論理サイズを合わせる。`size == 0` は `error.InvalidSize`
/// （EINVAL）。Windows/WASIは `error.OperationUnsupported`。macOSでは
/// `F_PREALLOCATE` がEOFからの連続確保しか表現できないため、`offset` が
/// 現在のEOFを超えるsparse確保は隙間全域を過剰予約せず
/// `error.OperationUnsupported` で返す。
pub fn allocate(io: std.Io, file: std.Io.File, offset: i64, size: u64) anyerror!void {
    // 非対応OSは引数に関わらずENOTSUP（OS判定を先に行う）。
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.OperationUnsupported,
    }
    if (offset < 0) return error.InvalidOffset;
    if (size == 0) return error.InvalidSize;
    return switch (builtin.os.tag) {
        .linux => allocateLinux(file, offset, size),
        .macos => allocateDarwin(io, file, offset, size),
        else => unreachable,
    };
}

fn allocateLinux(file: std.Io.File, offset: i64, size: u64) anyerror!void {
    const length = std.math.cast(i64, size) orelse return error.InvalidSize;
    while (true) {
        const result = std.os.linux.fallocate(file.handle, 0, offset, length);
        const errno = std.os.linux.errno(result);
        if (errno == .SUCCESS) return;
        if (errno == .INTR) continue;
        return low_level_fs.linuxErrno(errno);
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
    // Linux同様に書込不可fdのEBADFを返す（全経路共通でopenモードを検査）。
    const flags = std.c.fcntl(file.handle, std.c.F.GETFL);
    if (flags < 0) return low_level_fs.fsPosixErrno(std.c.errno(flags));
    // O_ACCMODE==3、O_RDONLY==0。
    if ((flags & 3) == 0) return error.BadFileDescriptor;
    const end = std.math.cast(u64, @as(u128, @intCast(offset)) + @as(u128, size)) orelse return error.InvalidSize;
    const current = file.length(io) catch |failure| switch (failure) {
        error.AccessDenied => return error.OperationUnsupported,
        else => return failure,
    };
    // 範囲がEOF内なら新規確保は不要（fallocate同様に成功のまま返す）。
    // 分岐: macOSのF_PREALLOCATEはF_PEOFPOSMODE（EOF以降）と
    // F_VOLPOSMODE（ボリューム先頭からの確保）しか範囲を指定できず、
    // EOF内の任意位置を指せない。file-position modeは存在しないため
    // 物理確保はno-opとし、契約上の差分として許容する。
    if (end <= current) return;
    // offsetがEOFを超えるsparse確保はF_PREALLOCATEで表現できない。
    // EOFからの連続確保しか指せず、要求範囲を覆うには隙間全域
    // [current, end) を予約するしかないが、大きな隙間では要求sizeを
    // 大きく超過しENOSPCになり得るため、契約を満たせずENOTSUPへ倒す。
    if (offset > current) return error.OperationUnsupported;
    const extra = std.math.cast(i64, end - current) orelse return error.InvalidSize;
    var store = DarwinFstore{
        .fst_flags = f_allocateall,
        .fst_posmode = f_peofposmode,
        .fst_offset = 0,
        .fst_length = extra,
        .fst_bytesalloc = 0,
    };
    while (true) {
        const result = std.c.fcntl(file.handle, std.c.F.PREALLOCATE, &store);
        if (result == 0) break;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        return low_level_fs.fsPosixErrno(errno);
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
        return low_level_fs.fsPosixErrno(errno);
    }
}

// Zig 0.16 std.cに宣言が無いためテスト用にここで宣言する。
const test_mkfifo = struct {
    extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
}.mkfifo;

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
    // inode管理を持たないFS（FAT等）はfiles=0を返すため、厳密な正値ではなく
    // free_files <= filesの不変条件のみを確認する。
    try std.testing.expect(info.free_files <= info.files);
    try std.testing.expect(info.filesystemType().len > 0);
    try std.testing.expect(info.filesystemId().len > 0);
    if (builtin.os.tag == .macos) {
        // APFS/HFS+ではfstypenameが埋まる。
        try std.testing.expect(std.mem.eql(u8, info.filesystemType(), "apfs") or
            std.mem.eql(u8, info.filesystemType(), "hfs"));
    }

    // 不在パスはENOENT、ファイルの中を潜るパスはENOTDIR。
    const missing = try low_level_fs.tmpPath(&temporary, "missing-dir");
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, statfs(std.testing.io, missing));
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "leaf.txt", .data = "x" });
    const leaf = try low_level_fs.tmpPath(&temporary, "leaf.txt");
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
    const source = try low_level_fs.tmpPath(&temporary, "src.txt");
    defer std.testing.allocator.free(source);
    const destination = try low_level_fs.tmpPath(&temporary, "dst.txt");
    defer std.testing.allocator.free(destination);

    reflink(std.testing.io, source, destination, null) catch |failure| {
        // tmpfs等のCoW非対応FSではENOTSUPになる。
        if (failure == error.OperationUnsupported) return error.SkipZigTest;
        return failure;
    };
    const original = try low_level_fs.stat(std.testing.io, source, true);
    const cloned = try low_level_fs.stat(std.testing.io, destination, true);
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
    const missing = try low_level_fs.tmpPath(&temporary, "missing.txt");
    defer std.testing.allocator.free(missing);
    const other = try low_level_fs.tmpPath(&temporary, "other.txt");
    defer std.testing.allocator.free(other);
    try std.testing.expectError(error.FileNotFound, reflink(std.testing.io, missing, other, null));
    // ディレクトリSRCはファイルクローン契約外のためENOTSUP。
    const dir_path = try low_level_fs.tmpPath(&temporary, ".");
    defer std.testing.allocator.free(dir_path);
    const dir_dst = try low_level_fs.tmpPath(&temporary, "dir-clone");
    defer std.testing.allocator.free(dir_dst);
    try std.testing.expectError(error.OperationUnsupported, reflink(std.testing.io, dir_path, dir_dst, null));
    // fifo等の通常ファイル以外もENOTSUP。Linuxのopenat(O_RDONLY)はfifoで
    // writer待ちに無限ブロックするため、種別で事前拒否する必要がある。
    const fifo_path = try low_level_fs.tmpPath(&temporary, "pipe.fifo");
    defer std.testing.allocator.free(fifo_path);
    const posix_fifo = try std.posix.toPosixPath(fifo_path);
    try std.testing.expectEqual(@as(c_int, 0), test_mkfifo(&posix_fifo, 0o600));
    const fifo_dst = try low_level_fs.tmpPath(&temporary, "fifo-clone");
    defer std.testing.allocator.free(fifo_dst);
    try std.testing.expectError(error.OperationUnsupported, reflink(std.testing.io, fifo_path, fifo_dst, null));

    // 明示MODEはSRCの権限を上書きする。
    const third = try low_level_fs.tmpPath(&temporary, "third.txt");
    defer std.testing.allocator.free(third);
    reflink(std.testing.io, source, third, 0o777) catch |failure| {
        if (failure == error.OperationUnsupported) return error.SkipZigTest;
        return failure;
    };
    try std.testing.expectEqual(@as(u32, 0o777), (try low_level_fs.stat(std.testing.io, third, true)).mode);
}

test "seekExtentはsparseファイルのデータ・空洞位置を返す" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // 先頭4byteにデータ、[4, 8192)が空洞、8192以降にデータのsparseファイル。
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "sparse.bin", .data = "data" });
    const path = try low_level_fs.tmpPath(&temporary, "sparse.bin");
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
    // hole検索でoffsetがEOFを超える場合はENXIO相当（ちょうどEOFは末尾の
    // 仮想空洞としてEOFを返す契約）。
    try std.testing.expectError(error.InvalidOffset, seekExtent(std.testing.io, file, 8197, .hole));
    // 負のoffsetはEINVAL。
    try std.testing.expectError(error.InvalidOffset, seekExtent(std.testing.io, file, -1, .data));
    try std.testing.expectError(error.InvalidOffset, seekExtent(std.testing.io, file, -1, .hole));
}

test "seekExtentは空ファイルのhole検索でEOFを返しfd位置を揃える" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "empty.bin", .data = "" });
    const path = try low_level_fs.tmpPath(&temporary, "empty.bin");
    defer std.testing.allocator.free(path);
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    // 空ファイルのoffset 0はちょうどEOF。POSIXの暗黙の末尾空洞としてEOF=0
    // を返す（FSによってはENXIOになるLinux経路もこの結果に正規化する）。
    try std.testing.expectEqual(@as(i64, 0), try seekExtent(std.testing.io, file, 0, .hole));
    // offsetがEOFを超える場合はENXIO相当。data検索はoffset 0でもENXIO相当。
    try std.testing.expectError(error.InvalidOffset, seekExtent(std.testing.io, file, 1, .hole));
    try std.testing.expectError(error.InvalidOffset, seekExtent(std.testing.io, file, 0, .data));
}

test "seekExtentは成功時にfd位置を結果位置へ揃える" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "cursor.bin", .data = "0123456789" });
    const path = try low_level_fs.tmpPath(&temporary, "cursor.bin");
    defer std.testing.allocator.free(path);
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_write });
    defer file.close(std.testing.io);

    // 非denseファイルのdata検索はoffsetをそのまま返し、fd位置もそこへ
    // 移る。直後のシーケンシャルreadが結果位置から始まることを確認する。
    try std.testing.expectEqual(@as(i64, 4), try seekExtent(std.testing.io, file, 4, .data));
    var buffer: [3]u8 = undefined;
    const read_count = std.c.read(file.handle, &buffer, buffer.len);
    try std.testing.expectEqual(@as(isize, 3), read_count);
    try std.testing.expectEqualStrings("456", &buffer);
    // hole検索で末尾へ揃った場合はEOFとしてreadが0を返す。
    try std.testing.expectEqual(@as(i64, 10), try seekExtent(std.testing.io, file, 0, .hole));
    try std.testing.expectEqual(@as(isize, 0), std.c.read(file.handle, &buffer, buffer.len));
    // 失敗時はfd位置を変えない（直前のEOF位置のまま）。
    try std.testing.expectError(error.InvalidOffset, seekExtent(std.testing.io, file, 99, .data));
    try std.testing.expectEqual(@as(isize, 0), std.c.read(file.handle, &buffer, buffer.len));
}

test "allocateは領域を確保し末尾以降の範囲でサイズを伸ばす" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "alloc.bin", .data = "xy" });
    const path = try low_level_fs.tmpPath(&temporary, "alloc.bin");
    defer std.testing.allocator.free(path);
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_write });
    defer file.close(std.testing.io);

    // EOF内の確保はサイズを変えない。
    try allocate(std.testing.io, file, 0, 2);
    try std.testing.expectEqual(@as(u64, 2), try file.length(std.testing.io));
    // EOFを超える範囲の確保はサイズを伸ばす（fallocate相当）。
    try allocate(std.testing.io, file, 0, 4096);
    try std.testing.expectEqual(@as(u64, 4096), try file.length(std.testing.io));
    // offsetがEOFを超えるsparse確保: macOSのF_PREALLOCATEはEOFからの連続
    // 確保しか表現できず、隙間全域を過剰予約しない契約としたためENOTSUP。
    // Linux等のfallocateはsparse範囲をそのまま確保しサイズを伸ばす。
    const sparse = allocate(std.testing.io, file, 8192, 128);
    if (builtin.os.tag == .macos) {
        try std.testing.expectError(error.OperationUnsupported, sparse);
    } else {
        try sparse;
        try std.testing.expectEqual(@as(u64, 8320), try file.length(std.testing.io));
        // 確保した領域は0埋めで読める。
        var buffer: [8]u8 = undefined;
        const read_count = try file.readPositionalAll(std.testing.io, &buffer, 4096);
        try std.testing.expectEqual(@as(usize, 8), read_count);
        for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }

    // 負のoffsetとsize=0はEINVAL。
    try std.testing.expectError(error.InvalidOffset, allocate(std.testing.io, file, -1, 8));
    try std.testing.expectError(error.InvalidSize, allocate(std.testing.io, file, 0, 0));
}
