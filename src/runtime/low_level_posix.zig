const std = @import("std");
const builtin = @import("builtin");
const foundation = @import("low_level_foundation.zig");

// chmod/chown/lchown/access/uid・gid/getgroups/umask はlibcのPOSIX wrapperを使う。
// Linuxはbuild.zigで常にlibcをリンクし（`link_libc = ... os.tag == .linux`）、
// `std.os.linux` にumaskのwrapperが無いため、macOS/Linuxで同一のerrno取得経路に
// 揃えられるlibc側へ寄せている。Windows/WASIはcomptime分岐で到達しない。

/// `所属グループID一覧取得` が返す補助グループID。
pub const GroupId = u32;

/// `UID取得` / `EUID取得` / `GID取得` / `EGID取得` が選ぶ実効・実IDの種別。
pub const IdKind = enum {
    uid,
    euid,
    gid,
    egid,
};

/// macOSのlibcには `getgroups` の宣言が無いため、POSIX環境向けに自前で宣言する。
/// Windowsでは comptime 分岐で到達しないので未解決シンボルにはならない。
extern "c" fn getgroups(size: c_int, list: ?[*]std.c.gid_t) c_int;

/// パスのパーミッションmodeを数値で設定する（chmod）。シンボリックリンクは
/// 追跡し、参照先のmodeを変更する。Windows/WASIは `ENOTSUP`（`error.OperationUnsupported`）。
pub fn chmod(path: []const u8, mode: u32) anyerror!void {
    return switch (builtin.os.tag) {
        .windows, .wasi => error.OperationUnsupported,
        else => chmodPosix(path, mode),
    };
}

/// パスの所有者UID/GIDを設定する。`follow == true` はchown（symlink追跡）、
/// `follow == false` はlchown（symlink自身）に相当する。`uid`/`gid` の `null`
/// は変更しない（POSIXの `(uid_t)-1`）。Windows/WASIは `ENOTSUP`。
pub fn chown(path: []const u8, uid: ?u32, gid: ?u32, follow: bool) anyerror!void {
    return switch (builtin.os.tag) {
        .windows, .wasi => error.OperationUnsupported,
        else => chownPosix(path, uid, gid, follow),
    };
}

/// OSのaccess(2)相当でpathのアクセス可否を判定する。`mode` は
/// `foundation.access_mode` のビット和。契約どおり実効UID/GID・補助グループで
/// 判定し（`AT_EACCESS`）、権限の拒否・対象不在はエラーではなく `false` を返す。
/// 不正mode（`EINVAL`）と非対応環境（`ENOTSUP`）だけを投げる。
pub fn access(path: []const u8, mode: u32) anyerror!bool {
    return switch (builtin.os.tag) {
        .windows, .wasi => error.OperationUnsupported,
        else => accessPosix(path, mode),
    };
}

/// 実UID・実効UID・実GID・実効GIDを返す。Windows/WASIは `ENOTSUP`。
pub fn id(kind: IdKind) anyerror!u32 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.OperationUnsupported;
    return switch (builtin.os.tag) {
        .linux => switch (kind) {
            .uid => std.os.linux.getuid(),
            .euid => std.os.linux.geteuid(),
            .gid => std.os.linux.getgid(),
            .egid => std.os.linux.getegid(),
        },
        else => switch (kind) {
            .uid => @intCast(std.c.getuid()),
            .euid => @intCast(std.c.geteuid()),
            .gid => @intCast(std.c.getgid()),
            .egid => @intCast(std.c.getegid()),
        },
    };
}

/// プロセスの補助グループID一覧を昇順でなくOSが返す順のまま返す。呼び出し側が
/// 同じallocatorで `free` する。Windows/WASIは `ENOTSUP`。
pub fn groups(allocator: std.mem.Allocator) anyerror![]GroupId {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.OperationUnsupported;
    while (true) {
        const count = getgroups(0, null);
        if (count < 0) return errnoError(std.c.errno(count));
        const length: usize = @intCast(count);
        if (length == 0) return allocator.alloc(GroupId, 0);
        const buffer = try allocator.alloc(std.c.gid_t, length);
        errdefer allocator.free(buffer);
        const written = getgroups(@intCast(length), buffer.ptr);
        if (written < 0) {
            const errno = std.c.errno(written);
            // 呼び出し中に補助グループが増えると不足分がEINVALになるため、
            // 現在数を取り直して再試行する。この経路だけ手動で解放し、
            // それ以外のエラー復帰はerrdeferに解放を任せる（二重解放防止）。
            if (errno == .INVAL) {
                allocator.free(buffer);
                continue;
            }
            return errnoError(errno);
        }
        const written_length: usize = @intCast(written);
        if (written_length > length) {
            allocator.free(buffer);
            continue;
        }
        const result = try allocator.alloc(GroupId, written_length);
        for (buffer[0..written_length], 0..) |value, index| result[index] = value;
        allocator.free(buffer);
        return result;
    }
}

/// プロセスのumaskを `mode` へ変更し、変更前のumaskを返す。Windows/WASIは
/// `ENOTSUP`。
pub fn umask(mode: u32) anyerror!u32 {
    return switch (builtin.os.tag) {
        .windows, .wasi => error.OperationUnsupported,
        else => @intCast(std.c.umask(@intCast(mode))),
    };
}

fn chmodPosix(path: []const u8, mode: u32) anyerror!void {
    const posix_path = try std.posix.toPosixPath(path);
    while (true) {
        const result = std.c.fchmodat(std.c.AT.FDCWD, &posix_path, @intCast(mode), 0);
        if (result == 0) return;
        const errno = std.c.errno(result);
        // シグナル割込みは一時的なので再試行する（EINTRをEINVALにしない）。
        if (errno == .INTR) continue;
        return errnoError(errno);
    }
}

fn chownPosix(path: []const u8, uid: ?u32, gid: ?u32, follow: bool) anyerror!void {
    const posix_path = try std.posix.toPosixPath(path);
    // POSIXの (uid_t)-1 / (gid_t)-1 は「変更しない」を意味する。
    const owner: std.c.uid_t = if (uid) |value| @intCast(value) else std.math.maxInt(std.c.uid_t);
    const group: std.c.gid_t = if (gid) |value| @intCast(value) else std.math.maxInt(std.c.gid_t);
    const flags: c_uint = if (follow) 0 else std.c.AT.SYMLINK_NOFOLLOW;
    while (true) {
        const result = std.c.fchownat(std.c.AT.FDCWD, &posix_path, owner, group, flags);
        if (result == 0) return;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        return errnoError(errno);
    }
}

fn accessPosix(path: []const u8, mode: u32) anyerror!bool {
    const posix_path = try std.posix.toPosixPath(path);
    // 契約の「実効アクセス semantics」に合わせ、実IDではなく実効UID/GIDと
    // 補助グループで判定するよう AT_EACCESS を付ける。Linuxはカーネル5.8未満で
    // faccessat2がENOSYSになるが、glibcのfaccessatは実効IDで判定する互換経路へ
    // フォールバックする（それも不可ならENOTSUPになる）。
    const flags = accessFlags();
    while (true) {
        const result = std.c.faccessat(std.c.AT.FDCWD, &posix_path, @intCast(mode), flags);
        if (result == 0) return true;
        const errno = std.c.errno(result);
        if (errno == .INTR) continue;
        return switch (errno) {
            // 権限拒否・対象不在・読み取り専用FSでの書込み拒否は、エラーではなく
            // 「アクセス不可」としてfalseを返す（catalogのエラーはEINVAL/ENOTSUPのみ）。
            .ACCES, .PERM, .NOENT, .NOTDIR, .LOOP, .ROFS => false,
            else => errnoError(errno),
        };
    }
}

/// `faccessat` の実効ID判定フラグ。Linuxの `std.c.AT` は `EACCESS` を持たない
/// ため、`linux/fs.h` の `AT_EACCESS`（0x200）を直接使う。macOS等はlibc定義を使う。
fn accessFlags() c_uint {
    return switch (builtin.os.tag) {
        .linux => 0x200,
        else => std.c.AT.EACCESS,
    };
}

/// POSIX errnoをZigエラーへ写す。portable code対応外のerrnoは `error.Unexpected`
/// になり、構造化エラー側でEINVALへ丸められる（G0の未写像エラー方針）。
fn errnoError(errno: std.c.E) anyerror {
    return switch (errno) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .INVAL => error.InvalidArgument,
        .ROFS => error.ReadOnlyFileSystem,
        .NOSPC => error.NoSpaceLeft,
        .NOMEM => error.SystemResources,
        // faccessat2非対応カーネル等、OSが判定自体に対応しない場合はcapability
        // 非対応としてENOTSUPへ写す（accessのcatalogエラーにENOTSUPを含む）。
        .NOSYS, .OPNOTSUPP => error.OperationUnsupported,
        else => error.Unexpected,
    };
}

test "chmodはmodeを変更しaccessは権限ビットを判定する" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "perm.txt", .data = "x" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "perm.txt" });
    defer std.testing.allocator.free(path);

    try chmod(path, 0o600);
    const metadata = try @import("low_level_fs.zig").stat(std.testing.io, path, true);
    try std.testing.expectEqual(@as(u32, 0o600), metadata.mode & 0o777);

    try std.testing.expect(try access(path, foundation.access_mode.f_ok));
    try std.testing.expect(try access(path, foundation.access_mode.r_ok));
    // `access` は AT_EACCESS を使うため実効UID/GIDで判定する。実IDと実効IDが
    // 異なるsetuidプロセスは単体テストで再現できないため、ここでは通常
    // （実ID=実効ID）の可否だけを検証する。
    // 実行ビットは付いていない。ただしroot（euid=0）は実行ビット無しでも
    // access(X_OK)が成功し得るため、その場合は検証しない。
    if (try id(.euid) != 0) {
        try std.testing.expect(!try access(path, foundation.access_mode.x_ok));
    }

    try chmod(path, 0o400);
    const read_only = try @import("low_level_fs.zig").stat(std.testing.io, path, true);
    try std.testing.expectEqual(@as(u32, 0o400), read_only.mode & 0o777);

    // 存在しないpathはエラーではなくfalse。
    const missing = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing.txt" });
    defer std.testing.allocator.free(missing);
    try std.testing.expect(!try access(missing, foundation.access_mode.f_ok));
    try std.testing.expectError(error.FileNotFound, chmod(missing, 0o644));
}

test "uid/gid取得は自身の実IDと一致し、umaskは旧値を返す" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    try std.testing.expectEqual(std.c.getuid(), try id(.uid));
    try std.testing.expectEqual(std.c.geteuid(), try id(.euid));
    try std.testing.expectEqual(std.c.getgid(), try id(.gid));
    try std.testing.expectEqual(std.c.getegid(), try id(.egid));

    const list = try groups(std.testing.allocator);
    defer std.testing.allocator.free(list);
    const count = getgroups(0, null);
    try std.testing.expectEqual(@as(usize, @intCast(count)), list.len);

    const previous = try umask(0o022);
    defer _ = umask(previous) catch {};
    try std.testing.expectEqual(@as(u32, 0o022), try umask(previous));
}

test "chownは同一IDへの変更が成功し、存在しないpathはENOENTになる" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "owner.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "owner.txt" });
    defer std.testing.allocator.free(path);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing.txt" });
    defer std.testing.allocator.free(missing);

    const own_uid = try id(.uid);
    const own_gid = try id(.gid);
    // 一般ユーザーは他IDへ変更できないため、自身のIDへのchown/lchownだけを検証する。
    try chown(path, own_uid, own_gid, true);
    try chown(path, own_uid, own_gid, false);
    // uid/gidのどちらかを -1（null）で無変更にできる。
    try chown(path, null, own_gid, true);
    try std.testing.expectError(error.FileNotFound, chown(missing, own_uid, own_gid, true));
    try std.testing.expectError(error.FileNotFound, chown(missing, own_uid, own_gid, false));

    // 未解決symlinkを使い、chown（follow）が参照先を解決してENOENTになり、
    // lchown（no-follow）がリンク自身を対象に成功することを区別して検証する。
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        try temporary.dir.symLink(std.testing.io, "dangling-target", "dangling", .{});
        const dangling = try std.fs.path.join(std.testing.allocator, &.{ directory, "dangling" });
        defer std.testing.allocator.free(dangling);
        try std.testing.expectError(error.FileNotFound, chown(dangling, own_uid, own_gid, true));
        try chown(dangling, own_uid, own_gid, false);
    }
}

test "accessは存在可否を判定し、不在はfalseになる" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "probe.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "probe.txt" });
    defer std.testing.allocator.free(path);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing.txt" });
    defer std.testing.allocator.free(missing);

    try std.testing.expect(try access(path, foundation.access_mode.f_ok));
    // 存在しないpathはF_OKでもエラーではなくfalse。
    try std.testing.expect(!try access(missing, foundation.access_mode.f_ok));
}

test "POSIX非対応OSではchmod/chown/access/uid取得/umaskがENOTSUPになる" {
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) return error.SkipZigTest;
    try std.testing.expectError(error.OperationUnsupported, chmod("whatever", 0o644));
    try std.testing.expectError(error.OperationUnsupported, chown("whatever", 0, 0, true));
    try std.testing.expectError(error.OperationUnsupported, access("whatever", 0));
    try std.testing.expectError(error.OperationUnsupported, id(.uid));
    try std.testing.expectError(error.OperationUnsupported, id(.euid));
    try std.testing.expectError(error.OperationUnsupported, id(.gid));
    try std.testing.expectError(error.OperationUnsupported, id(.egid));
    try std.testing.expectError(error.OperationUnsupported, groups(std.testing.allocator));
    try std.testing.expectError(error.OperationUnsupported, umask(0o022));
}
