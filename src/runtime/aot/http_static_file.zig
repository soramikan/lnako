const std = @import("std");
const builtin = @import("builtin");

/// 静的配信で開いたファイル。`name`はContent-Type判定に使う相対名で、
/// `aotHttpServeStatic`の`sanitized`か静的リテラルを指す（所有しない）。
pub const AotHttpStaticFile = struct {
    file: std.Io.File,
    name: []const u8,
};

/// docroot配下の静的配信対象を堅牢に開く。
///
/// `std.Io.Dir.openDir`/`openFile`の`follow_symlinks = false`は、POSIXでは
/// `O_NOFOLLOW`、Windowsでは`FILE_OPEN_REPARSE_POINT`に対応する。ただし
/// いずれも指定したパスの最終成分だけが対象なので、多段パスを一度に渡すと
/// 中間成分のsymlinkを辿ってしまう。そのため1成分ずつ親ハンドルからの相対で
/// 開く。各openは既に開いたハンドルを起点に解決されるため、途中で名前を
/// 差し替えられても開いたハンドルの外へは移動しない。
///
/// Windowsの`OPEN_REPARSE_POINT`はreparse point自体のハンドルを返すことが
/// あり、そこからの相対openがlink先へ解決されうる。開いた後に対象の実体が
/// 通常のディレクトリ／ファイルであることを`stat`で確認し、symlinkや
/// reparse point（`unknown`）は配信しない（fail closed）。
pub fn aotHttpOpenStaticFile(io: std.Io, docroot: []const u8, relative: []const u8) !?AotHttpStaticFile {
    var directory = try aotHttpOpenDocRoot(io, docroot) orelse return null;
    defer directory.close(io);

    // 末尾が区切り、または末尾成分が`.`ならディレクトリ指定。通常ファイルに
    // 対して`hello.txt/`や`hello.txt/.`を付けた要求は従来どおり404にする。
    const requires_directory = aotHttpStaticPathRequiresDirectory(relative);
    var components: AotHttpStaticPathIterator = .{ .path = relative };
    const first = components.next() orelse return aotHttpOpenIndexFile(io, directory);
    if (!aotHttpValidStaticComponent(first)) return null;
    var component = first;
    while (components.next()) |next_component| {
        if (!aotHttpValidStaticComponent(next_component)) return null;
        const child = try aotHttpOpenChildDirectory(io, directory, component) orelse return null;
        directory.close(io);
        directory = child;
        component = next_component;
    }
    return aotHttpOpenStaticTarget(io, directory, component, requires_directory);
}

/// docrootを開く。docrootは設定値なのでsymlinkを追従する（従来の
/// `realPathFileAlloc`と同じ）。POSIXでは読み取り権限を要求しない
/// `O_PATH`（Linux）/`O_SEARCH`（Darwin）で開く。
fn aotHttpOpenDocRoot(io: std.Io, docroot: []const u8) !?std.Io.Dir {
    // NULを含むパスは`toPosixPath`のassertでプロセスを停止させるため拒否する。
    if (std.mem.indexOfScalar(u8, docroot, 0) != null) return null;
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        const directory = std.Io.Dir.cwd().openDir(io, docroot, .{}) catch |err| return if (aotHttpIsStaticPathMiss(err)) null else err;
        return aotHttpVerifyDirectory(io, directory);
    }
    const fd = try aotHttpOpenPosixDirectoryFd(std.Io.Dir.cwd(), docroot, true) orelse return null;
    return aotHttpVerifyDirectory(io, .{ .handle = fd });
}

/// 最終成分を開く。ディレクトリなら従来どおり`index.html`を配信する。
fn aotHttpOpenStaticTarget(io: std.Io, directory: std.Io.Dir, component: []const u8, requires_directory: bool) !?AotHttpStaticFile {
    // まずディレクトリとして開く。通常ファイル・FIFO・symlinkはここで
    // 失敗するため、通常ファイル経路へ進む。事前statに依存しないので、
    // statとopenの間で種別が変わってもfd側の確認で拒否できる。
    if (try aotHttpOpenChildDirectory(io, directory, component)) |child| {
        defer child.close(io);
        return aotHttpOpenIndexFile(io, child);
    }
    if (requires_directory) return null;
    return aotHttpOpenRegularFile(io, directory, component);
}

/// `directory/index.html`を開く。docroot直下と、ディレクトリ指定の両方で使う。
/// 通常ファイル経路と同じ非ブロッキングopen + fd種別確認を共用する。
fn aotHttpOpenIndexFile(io: std.Io, directory: std.Io.Dir) !?AotHttpStaticFile {
    return aotHttpOpenRegularFile(io, directory, "index.html");
}

/// 通常ファイルを開く。POSIXでは読み取りopenの前に副作用のない種別確認を
/// 行い、通常ファイル以外（FIFO・socket・device・ディレクトリ・symlink）を
/// openしない。Linuxでは`O_PATH`で実体を固定してから`/proc/self/fd`経由で
/// 同じinodeを読み取りopenするため、差し替えの競合余地がない。
fn aotHttpOpenRegularFile(io: std.Io, directory: std.Io.Dir, name: []const u8) !?AotHttpStaticFile {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        const file = directory.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = false }) catch |err| return if (aotHttpIsStaticPathMiss(err)) null else err;
        return aotHttpRequireRegularStaticFile(io, file, name);
    }
    const fd = try aotHttpOpenPosixRegularFileFd(io, directory, name) orelse return null;
    return aotHttpRequireRegularStaticFile(io, .{ .handle = fd, .flags = .{ .nonblocking = true } }, name);
}

pub const AotHttpPosixStat = struct {
    kind: std.Io.File.Kind,
    inode: u64,
    device: u64,

    fn matchesRegularFile(self: AotHttpPosixStat, expected: AotHttpPosixStat) bool {
        return self.kind == .file and self.inode == expected.inode and self.device == expected.device;
    }
};

/// POSIXで`name`をsymlink非追従でstatする（open前の副作用のない種別確認）。
pub fn aotHttpPosixStatAt(directory: std.Io.Dir, name: []const u8) !?AotHttpPosixStat {
    if (std.mem.indexOfScalar(u8, name, 0) != null) return null;
    const path = std.posix.toPosixPath(name) catch return null;
    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(directory.handle, &path, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .INO = true }, &stx);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .NOENT, .NOTDIR, .LOOP, .NAMETOOLONG, .NODEV => return null,
            .ACCES => return error.AccessDenied,
            else => return error.Unexpected,
        }
        return aotHttpStatFromStatx(stx);
    }
    var st: std.c.Stat = undefined;
    const rc = std.c.fstatat(directory.handle, &path, &st, std.c.AT.SYMLINK_NOFOLLOW);
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .NOENT, .NOTDIR, .LOOP, .NAMETOOLONG, .NODEV => return null,
        .ACCES => return error.AccessDenied,
        else => return error.Unexpected,
    }
    return .{
        .kind = aotHttpKindFromMode(st.mode),
        .inode = aotHttpUnsignedId(st.ino),
        .device = aotHttpUnsignedId(st.dev),
    };
}

/// 開いたfdの種別・inode・deviceを取得する。
fn aotHttpPosixFstat(fd: std.posix.fd_t) !?AotHttpPosixStat {
    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .INO = true }, &stx);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .NOENT, .NOTDIR, .LOOP, .NAMETOOLONG, .NODEV => return null,
            .ACCES => return error.AccessDenied,
            else => return error.Unexpected,
        }
        return aotHttpStatFromStatx(stx);
    }
    var st: std.c.Stat = undefined;
    const rc = std.c.fstat(fd, &st);
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .NOENT, .NOTDIR, .LOOP, .NAMETOOLONG, .NODEV => return null,
        .ACCES => return error.AccessDenied,
        else => return error.Unexpected,
    }
    return .{
        .kind = aotHttpKindFromMode(st.mode),
        .inode = aotHttpUnsignedId(st.ino),
        .device = aotHttpUnsignedId(st.dev),
    };
}

/// `statx`の結果から種別・inode・deviceを取り出す。`TYPE`/`INO`が
/// 要求どおり返っていない場合はfail closed（null）にする。
pub fn aotHttpStatFromStatx(stx: std.os.linux.Statx) ?AotHttpPosixStat {
    if (!stx.mask.TYPE or !stx.mask.INO) return null;
    return .{
        .kind = aotHttpKindFromMode(stx.mode),
        .inode = stx.ino,
        .device = aotHttpDeviceId(stx.dev_major, stx.dev_minor),
    };
}

fn aotHttpKindFromMode(mode: anytype) std.Io.File.Kind {
    const value: u32 = @intCast(mode);
    return switch (value & std.posix.S.IFMT) {
        std.posix.S.IFREG => .file,
        std.posix.S.IFDIR => .directory,
        std.posix.S.IFLNK => .sym_link,
        std.posix.S.IFIFO => .named_pipe,
        std.posix.S.IFSOCK => .unix_domain_socket,
        std.posix.S.IFCHR => .character_device,
        std.posix.S.IFBLK => .block_device,
        else => .unknown,
    };
}

fn aotHttpDeviceId(major: u32, minor: u32) u64 {
    return (@as(u64, major) << 32) | minor;
}

/// 符号付きの`dev_t`/`ino_t`をビット幅を保ったままu64へ変換する。
/// Darwinの`dev_t`は符号付き32ビットで、負値でも`@intCast`のように
/// ReleaseSafeでトラップしない。
pub fn aotHttpUnsignedId(value: anytype) u64 {
    switch (@typeInfo(@TypeOf(value))) {
        .int => |info| {
            const Unsigned = @Int(.unsigned, info.bits);
            return @as(u64, @as(Unsigned, @bitCast(value)));
        },
        else => return @intCast(value),
    }
}

/// POSIXで通常ファイルを開く。open前に種別を確認し、open後にもfdの
/// 種別と同一inode（device, inode）を検証する。
fn aotHttpOpenPosixRegularFileFd(io: std.Io, directory: std.Io.Dir, name: []const u8) !?std.posix.fd_t {
    const pre = try aotHttpPosixStatAt(directory, name) orelse return null;
    if (pre.kind != .file) return null;

    if (builtin.os.tag == .linux) {
        // O_PATHのopenは副作用がなく、実体をfdで固定できる。/proc/self/fdは
        // パスを再解決せず固定したinodeを開くため、差し替えの競合余地がない。
        const path_fd = std.posix.openat(directory.handle, name, aotHttpPathOpenFlags(), 0) catch |err| return if (aotHttpIsStaticPathMiss(err)) null else err;
        defer (std.Io.File{ .handle = path_fd, .flags = .{ .nonblocking = false } }).close(io);
        const path_stat = try aotHttpPosixFstat(path_fd) orelse return null;
        if (!path_stat.matchesRegularFile(pre)) return null;
        const Hooks = struct {
            io: std.Io,
            directory: std.Io.Dir,
            name: []const u8,
            pre: AotHttpPosixStat,
            fn openProc(self: @This(), proc_fd: std.posix.fd_t) anyerror!std.posix.fd_t {
                _ = self;
                return aotHttpOpenProcFd(proc_fd);
            }
            fn probeProcDir(self: @This()) anyerror!bool {
                return aotHttpProcFdDirectoryAvailable(self.io);
            }
            fn fallback(self: @This()) anyerror!?std.posix.fd_t {
                return aotHttpOpenPosixRegularFileFallback(self.io, self.directory, self.name, self.pre);
            }
        };
        return aotHttpOpenLinuxWithHooks(Hooks{ .io = io, .directory = directory, .name = name, .pre = pre }, path_fd);
    }

    return aotHttpOpenPosixRegularFileFallback(io, directory, name, pre);
}

/// Linuxのprocfs openからパス名openへのフォールバック分岐。
/// `openProc`がprocfs不在（FileNotFound/NotDir）以外ならそのエラーを返す。
/// procfs不在でも`probeProcDir`が利用可能なら元エラーを返し、確認自体の
/// 失敗はそのエラーを伝播する。両方不在のときだけ`fallback`を呼ぶ。
pub fn aotHttpOpenLinuxWithHooks(hooks: anytype, path_fd: std.posix.fd_t) anyerror!?std.posix.fd_t {
    if (hooks.openProc(path_fd)) |fd| {
        return fd;
    } else |err| {
        if (!aotHttpIsProcUnavailable(err)) return err;
        const available = hooks.probeProcDir() catch |probe_err| return probe_err;
        if (available) return err;
    }
    return hooks.fallback();
}

/// `/proc/self/fd`が無いことによるエラーか。それ以外はフォールバックしない。
pub fn aotHttpIsProcUnavailable(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.NotDir => true,
        else => false,
    };
}

/// `/proc/self/fd`ディレクトリが利用可能か。不在（FileNotFound/NotDir）だけ
/// falseを返し、権限等のエラーは呼び出し元へ伝播する。
fn aotHttpProcFdDirectoryAvailable(io: std.Io) !bool {
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    flags.DIRECTORY = true;
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "PATH")) flags.PATH = true;
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/fd", flags, 0) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => false,
        else => err,
    };
    (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).close(io);
    return true;
}

/// procfsが使えない場合のフォールバック。事前statの種別・(dev, ino)と
/// open後のfstatが一致する通常ファイルだけを受け付ける。
pub fn aotHttpOpenPosixRegularFileFallback(io: std.Io, directory: std.Io.Dir, name: []const u8, pre: AotHttpPosixStat) !?std.posix.fd_t {
    const fd = std.posix.openat(directory.handle, name, aotHttpRegularFileOpenFlags(), 0) catch |err| return if (aotHttpIsStaticPathMiss(err)) null else err;
    const post = aotHttpPosixFstat(fd) catch |err| {
        (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = true } }).close(io);
        return err;
    };
    if (post == null or !post.?.matchesRegularFile(pre)) {
        (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = true } }).close(io);
        return null;
    }
    return fd;
}

/// Linuxで`/proc/self/fd/<fd>`を読み取りopenする。`path_fd`が固定した
/// inodeをそのまま開くため、パスの差し替えに影響されない。
fn aotHttpOpenProcFd(path_fd: std.posix.fd_t) !std.posix.fd_t {
    var buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "/proc/self/fd/{d}", .{path_fd});
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    flags.NONBLOCK = true;
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    return std.posix.openat(std.posix.AT.FDCWD, path, flags, 0);
}

fn aotHttpPathOpenFlags() std.posix.O {
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    flags.NOFOLLOW = true;
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "PATH")) flags.PATH = true;
    return flags;
}

/// 開いたファイルが通常ファイルであることをfdから確認する。所有権は常に
/// この関数が引き取り、失敗時はcloseしてnull/エラーを返す。
fn aotHttpRequireRegularStaticFile(io: std.Io, file: std.Io.File, name: []const u8) !?AotHttpStaticFile {
    const stat = file.stat(io) catch |err| {
        file.close(io);
        return err;
    };
    if (stat.kind != .file) {
        file.close(io);
        return null;
    }
    return .{ .file = file, .name = name };
}

/// 中間ディレクトリを1成分だけ、symlinkを辿らずに開く。
fn aotHttpOpenChildDirectory(io: std.Io, parent: std.Io.Dir, component: []const u8) !?std.Io.Dir {
    const child = if (builtin.os.tag == .windows or builtin.os.tag == .wasi)
        parent.openDir(io, component, .{ .follow_symlinks = false }) catch |err| return if (aotHttpIsStaticPathMiss(err)) null else err
    else blk: {
        const fd = try aotHttpOpenPosixDirectoryFd(parent, component, false) orelse return null;
        break :blk std.Io.Dir{ .handle = fd };
    };
    return aotHttpVerifyDirectory(io, child);
}

/// 開いたディレクトリの実体が通常のディレクトリであることを確認する。
/// Windowsのreparse point（`.sym_link`/`.unknown`）はここで拒否する。
fn aotHttpVerifyDirectory(io: std.Io, directory: std.Io.Dir) !?std.Io.Dir {
    const stat = directory.stat(io) catch |err| {
        directory.close(io);
        return err;
    };
    if (stat.kind != .directory) {
        directory.close(io);
        return null;
    }
    return directory;
}

/// POSIXでディレクトリを1成分だけ開く。Linuxは`O_PATH`、Darwinは
/// `O_SEARCH`（= `O_EXEC | O_DIRECTORY`）を使い、読み取り権限を要求しない。
/// どちらも使えない環境では`O_RDONLY`にフォールバックする。
fn aotHttpOpenPosixDirectoryFd(parent: std.Io.Dir, component: []const u8, follow_symlinks: bool) !?std.posix.fd_t {
    if (std.mem.indexOfScalar(u8, component, 0) != null) return null;
    const flags = aotHttpDirectoryOpenFlags(follow_symlinks);
    const fd = std.posix.openat(parent.handle, component, flags, 0) catch |err| {
        if (aotHttpIsDarwin() and err == error.BadPathName) {
            // O_SEARCH非対応の環境では従来のO_RDONLYで開き直す。
            const fallback_flags = aotHttpDirectoryOpenFlagsFallback(follow_symlinks);
            return std.posix.openat(parent.handle, component, fallback_flags, 0) catch |fallback_err| return if (aotHttpIsStaticPathMiss(fallback_err)) null else fallback_err;
        }
        return if (aotHttpIsStaticPathMiss(err)) null else err;
    };
    return fd;
}

fn aotHttpIsDarwin() bool {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => true,
        else => false,
    };
}

/// ディレクトリ用のopenフラグ。Linuxの`O_PATH`は読み取り権限を要求せず、
/// `openat`の起点として使える。Darwinの`O_SEARCH`は`O_EXEC | O_DIRECTORY`
/// で、Zigの`std.posix.O`に`SEARCH`フィールドが無いため同梱の
/// `sys/fcntl.h`の値をビットで立てる。
fn aotHttpDirectoryOpenFlags(follow_symlinks: bool) std.posix.O {
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    flags.DIRECTORY = true;
    flags.NOFOLLOW = !follow_symlinks;
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "PATH")) {
        flags.PATH = true;
    } else if (aotHttpIsDarwin()) {
        flags = @bitCast(@as(u32, @bitCast(flags)) | 0x40000000);
    }
    return flags;
}

/// `O_PATH`/`O_SEARCH`を使わないディレクトリopenフラグ（フォールバック）。
fn aotHttpDirectoryOpenFlagsFallback(follow_symlinks: bool) std.posix.O {
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    flags.DIRECTORY = true;
    flags.NOFOLLOW = !follow_symlinks;
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    return flags;
}

/// 通常ファイル用のopenフラグ。`O_NONBLOCK`でFIFOのopen停止を防ぎ、
/// `O_NOFOLLOW`で最終成分のsymlinkを拒否する。
fn aotHttpRegularFileOpenFlags() std.posix.O {
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    flags.NOFOLLOW = true;
    flags.NONBLOCK = true;
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;
    return flags;
}

/// 静的配信の読み込み上限。旧`readFileAlloc(.limited(N))`は「N以上」で
/// `StreamTooLong`だったため、境界を変えないようfdのサイズが上限以上なら
/// 読み取り前に413相当を返す。
pub fn aotHttpReadStaticFile(io: std.Io, file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    const stat = try file.stat(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return aotHttpReadStaticFromReader(&reader.interface, stat.size, allocator, max_bytes) catch |err| {
        return aotHttpRestoreReadError(err, reader.err);
    };
}

/// `File.Reader`は実エラーを`reader.err`へ保存して`error.ReadFailed`を返す。
/// 要求スコープの404/500分類に使えるよう元エラーを復元する。
pub fn aotHttpRestoreReadError(err: anyerror, reader_err: ?anyerror) anyerror {
    if (err == error.ReadFailed) return reader_err orelse error.ReadFailed;
    return err;
}

/// 事前statのサイズと実際の読み取り結果の両方に排他的上限を適用する。
/// `stat_size`が上限未満でも、読み取りが上限ちょうどに達したら413相当。
pub fn aotHttpReadStaticFromReader(reader: *std.Io.Reader, stat_size: u64, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    if (stat_size >= @as(u64, max_bytes)) return error.StreamTooLong;
    const data = try reader.allocRemaining(allocator, .limited(max_bytes));
    return aotHttpEnforceStaticReadLimit(allocator, data, max_bytes);
}

/// 実際に読み取ったバイト数にも旧`readFileAlloc`と同じ排他的上限を適用する。
/// stat時点で上限未満でも、読み取り中に上限ちょうどまで伸びた場合は413相当。
pub fn aotHttpEnforceStaticReadLimit(allocator: std.mem.Allocator, data: []u8, max_bytes: usize) ![]u8 {
    if (data.len >= max_bytes) {
        allocator.free(data);
        return error.StreamTooLong;
    }
    return data;
}

fn aotHttpStaticPathRequiresDirectory(relative: []const u8) bool {
    var index = relative.len;
    var trailing_separator = false;
    while (index > 0 and aotHttpIsStaticPathSeparator(relative[index - 1])) {
        index -= 1;
        trailing_separator = true;
    }
    if (index == 0) return true;
    const end = index;
    while (index > 0 and !aotHttpIsStaticPathSeparator(relative[index - 1])) index -= 1;
    return trailing_separator or std.mem.eql(u8, relative[index..end], ".");
}

/// 経路が存在しない／配信対象でない（クライアント起因）エラーを404にする。
/// 権限やデバイス等のホスト側障害は404に隠さず、要求1件の500として伝播させる
/// （Interpreter側`serveStatic`の分類に合わせる）。
pub fn aotHttpIsStaticPathMiss(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.IsDir,
        // POSIXのO_NOFOLLOW / WindowsのOPEN_REPARSE_POINTがsymlinkを検出した場合。
        error.SymLinkLoop,
        error.BadPathName,
        error.NameTooLong,
        // socket等のopenはENXIO（NoDevice）になる。種別違いとして404。
        error.NoDevice,
        // Darwinはソケットの読み取りopenにEOPNOTSUPPを返し、Zigは
        // error.FileLocksUnsupportedへ変換する。種別違いとして404。
        error.FileLocksUnsupported,
        => true,
        else => false,
    };
}

/// 静的配信の読み込みI/Oエラーを要求スコープのstatusへ分類する。
/// 解決後に消えた・種別が変わったファイルは404、容量超過は413、
/// 権限等のホスト側障害は500。OOMだけは伝播させる（null）。
pub fn aotHttpStaticReadErrorStatus(err: anyerror) ?u16 {
    return switch (err) {
        error.OutOfMemory => null,
        error.StreamTooLong => 413,
        error.FileNotFound, error.NotDir, error.IsDir => 404,
        else => 500,
    };
}

const AotHttpStaticPathIterator = struct {
    path: []const u8,
    index: usize = 0,

    fn next(self: *AotHttpStaticPathIterator) ?[]const u8 {
        while (self.index < self.path.len) {
            while (self.index < self.path.len and aotHttpIsStaticPathSeparator(self.path[self.index])) self.index += 1;
            if (self.index == self.path.len) return null;
            const start = self.index;
            while (self.index < self.path.len and !aotHttpIsStaticPathSeparator(self.path[self.index])) self.index += 1;
            const component = self.path[start..self.index];
            // `.`は現在のディレクトリなので無視する（従来のパス解決と同じ）。
            if (std.mem.eql(u8, component, ".")) continue;
            return component;
        }
        return null;
    }
};

fn aotHttpIsStaticPathSeparator(byte: u8) bool {
    if (byte == '/') return true;
    // Windowsでは`\`も区切り。成分へ分割しないと`openDir`が多段パスとして
    // 中間のsymlinkを辿ってしまう。
    return switch (builtin.os.tag) {
        .windows => byte == '\\',
        else => false,
    };
}

fn aotHttpValidStaticComponent(component: []const u8) bool {
    if (component.len == 0) return false;
    if (std.mem.eql(u8, component, "..")) return false;
    if (std.mem.indexOfScalar(u8, component, 0) != null) return false;
    if (builtin.os.tag == .windows) {
        // `C:`等のドライブ指定は親ハンドルからの相対解決を迂回しうるため拒否する。
        // Windowsのファイル名に`:`は使えないので既存の配信対象は失われない。
        if (std.mem.indexOfScalar(u8, component, ':') != null) return false;
    }
    return true;
}

test "AOT静的配信は事前検査と種別・デバイス・inodeが一致する通常ファイルを受け付ける" {
    const pre: AotHttpPosixStat = .{ .kind = .file, .device = 1, .inode = 2 };
    try std.testing.expect(pre.matchesRegularFile(pre));

    var opened = pre;
    opened.inode += 1;
    try std.testing.expect(!opened.matchesRegularFile(pre));

    opened = pre;
    opened.device += 1;
    try std.testing.expect(!opened.matchesRegularFile(pre));

    opened = pre;
    opened.kind = .directory;
    try std.testing.expect(!opened.matchesRegularFile(pre));
}
