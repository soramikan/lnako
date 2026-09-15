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
/// 概念の無いOSや取得に失敗した場合の所有者・デバイス・ブロック数は 0 にする
/// （0はroot所有と区別できないため、uid/gidは0を「取得不可」としても扱う）。
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

/// `stat`（follow=true）と `lstat`（follow=false）の共通実装。まずポータブルな
/// `std.Io.Dir.statFile` で種別・サイズ・権限・時刻を取得し、その上でOS固有の
/// uid/gid/dev/rdev/blocks/birthtime を重ねる。OS固有値が取れない環境でも
/// ポータブル値だけで成功する。
///
/// 2回のpathベースsyscallを使うため、その間にパスが差し替わるとフィールドが
/// 混在し得る（例: lstatでkind=symlinkなのにinodeが差し替え後の実体を指す）。
/// これはpathベースAPI一般の性質であり、原子的なスナップショットが必要な場合は
/// handleベースの高度API（Issue #36）を使う。
pub fn stat(io: std.Io, path: []const u8, follow: bool) anyerror!Metadata {
    const info = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = follow });
    var metadata = Metadata{
        .kind = kindFrom(info.kind),
        .size = info.size,
        .mode = modeBits(info.permissions),
        .inode = @intCast(info.inode),
        .nlink = @intCast(info.nlink),
        .block_size = info.block_size,
        .atime_ns = if (info.atime) |value| value.nanoseconds else null,
        .mtime_ns = info.mtime.nanoseconds,
        .ctime_ns = info.ctime.nanoseconds,
    };
    applyRawExtras(io, path, follow, &metadata);
    return metadata;
}

/// シンボリックリンクを作成する。Windowsではリンク先の種別を自動判定して
/// file symlink / directory symlink を選ぶ。POSIXでは `is_directory` は無視される。
/// Windowsのdirectory symlink作成にはsymlink権限が必要で、無い場合はEPERMになる。
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
/// `error.NotLink`（portable code EINVAL）になる。参照先が初期バッファより
/// 長い場合はバッファを倍々に拡張して完全な文字列を返す（切り詰めない）。
pub fn readlink(io: std.Io, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
    var size: usize = std.fs.max_path_bytes;
    while (true) {
        const buffer = try allocator.alloc(u8, size);
        defer allocator.free(buffer);
        const length = try std.Io.Dir.cwd().readLink(io, path, buffer);
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

fn kindFrom(kind: std.Io.File.Kind) FileKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .symlink,
        .unknown => .unknown,
        else => .other,
    };
}

fn modeBits(permissions: std.Io.File.Permissions) u32 {
    return switch (builtin.os.tag) {
        // WindowsのpermissionsはPOSIX modeではなくattributesであり、mode相当は
        // 定義されない。既存 `ファイル情報取得` と同じく既定の読み書き可を返す。
        .windows => 0o666,
        .wasi => 0o666,
        else => @intCast(permissions.toMode() & 0o7777),
    };
}

/// OS固有フィールド（uid/gid/dev/rdev/blocks/birthtime）は `std.Io.Dir.statFile`
/// が公開しないため、raw syscallを直接使う。std.Ioの非同期executorを介さない
/// ブロッキング呼び出しであり、追加メタデータの取得だけに限定している。
fn applyRawExtras(io: std.Io, path: []const u8, follow: bool, metadata: *Metadata) void {
    switch (builtin.os.tag) {
        .windows => applyWindowsExtras(io, path, follow, metadata),
        .linux => applyLinuxExtras(path, follow, metadata),
        .wasi => {},
        else => applyPosixExtras(path, follow, metadata),
    }
}

fn applyPosixExtras(path: []const u8, follow: bool, metadata: *Metadata) void {
    const posix_path = std.posix.toPosixPath(path) catch return;
    var raw: std.c.Stat = std.mem.zeroes(std.c.Stat);
    const flags: u32 = if (follow) 0 else std.c.AT.SYMLINK_NOFOLLOW;
    const result = std.c.fstatat(std.c.AT.FDCWD, &posix_path, &raw, flags);
    if (result != 0) return;
    metadata.uid = @intCast(raw.uid);
    metadata.gid = @intCast(raw.gid);
    metadata.dev = toU64(raw.dev);
    metadata.rdev = toU64(raw.rdev);
    metadata.inode = toU64(raw.ino);
    metadata.nlink = toU64(raw.nlink);
    metadata.blocks = toU64(raw.blocks);
    metadata.mode = @as(u32, @intCast(toU64(raw.mode) & 0o7777));
    if (comptime @hasDecl(std.c.Stat, "birthtime")) {
        metadata.birthtime_ns = timespecNs(raw.birthtime());
    }
}

fn applyLinuxExtras(path: []const u8, follow: bool, metadata: *Metadata) void {
    const posix_path = std.posix.toPosixPath(path) catch return;
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
        .BTIME = true,
    };
    const result = std.os.linux.statx(std.os.linux.AT.FDCWD, &posix_path, flags, mask, &raw);
    if (std.os.linux.errno(result) != .SUCCESS) return;
    metadata.uid = raw.uid;
    metadata.gid = raw.gid;
    // Linuxのstatxはmajor/minorを分けて返すため、glibcの `makedev` と同じ
    // 符号化にまとめてPOSIXの `st_dev` 相当にする。
    metadata.dev = linuxDevice(raw.dev_major, raw.dev_minor);
    metadata.rdev = linuxDevice(raw.rdev_major, raw.rdev_minor);
    metadata.inode = raw.ino;
    metadata.nlink = raw.nlink;
    metadata.blocks = raw.blocks;
    metadata.mode = @as(u32, raw.mode) & 0o7777;
    if (raw.mask.BTIME) metadata.birthtime_ns = statxTimeNs(raw.btime);
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

fn applyWindowsExtras(io: std.Io, path: []const u8, follow: bool, metadata: *Metadata) void {
    // uid/gid/dev/rdev/blocks はWindowsに存在しないため0のまま。
    // 作成時刻だけは FILE.ALL_INFORMATION から取得する。lstat相当では
    // follow_symlinks=false でreparse point自身のハンドルを開く。
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = follow }) catch return;
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
    if (status != .SUCCESS and status != .BUFFER_OVERFLOW) return;
    // Windows FILETIME（1601年起点・100ns単位）をUnix epochナノ秒へ変換する。
    // 変換はG0の `timeNsFromWindowsFileTime` を正本として使う。
    metadata.birthtime_ns = foundation.timeNsFromWindowsFileTime(@bitCast(info.BasicInformation.CreationTime));
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
