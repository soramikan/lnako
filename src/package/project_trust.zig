const std = @import("std");
const builtin = @import("builtin");
const low_level_fs = @import("../runtime/low_level_fs.zig");

const Allocator = std.mem.Allocator;

/// Windows の `BUILTIN\Users` add-only ACE（FILE_ADD_FILE/
/// FILE_ADD_SUBDIRECTORY のみ、継承由来）を baseline として許容するか。
/// 対象オブジェクト自体へ適用される直接付与 ACE は例外にしない。
const UsersAddOnlyPolicy = enum {
    /// drive root 由来の継承 ACE を許容。project dir・祖先 dir 検査用。
    allow_inherited_baseline,
    /// package tree 本体用。add-only でも tree 内へ新規 source を作成
    /// されると検証後の内容を侵されるため例外を認めない。
    reject_on_tree,
};

/// Reject project paths whose owner or ACL/mode permits untrusted modification.
/// On Windows ACL parsing is deliberately conservative: unknown ACE forms fail closed.
/// POSIXではモードビットに加えて所有者を検査する — 0644でも別ユーザ所有なら
/// 所有者が書き換え・chmodできるため、実効ユーザでもrootでもない所有は拒否する。
pub fn isUnsafeWritablePath(allocator: Allocator, io: std.Io, path: []const u8) !bool {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (comptime builtin.os.tag == .windows)
        return try windowsPathHasUntrustedWriteAccess(allocator, path, stat.kind == .directory, .allow_inherited_baseline);
    if (comptime builtin.os.tag == .wasi) return false;
    if (@intFromEnum(stat.permissions) & 0o022 != 0) return true;
    const metadata = low_level_fs.stat(io, path, true) catch return true;
    return metadata.uid != 0 and metadata.uid != std.c.geteuid();
}

/// `root` 自体と配下の全エントリを走査し、共有writableな箇所があれば true
/// を返す。materialized tree は `.nako` 直下の権限がprivateでも、配下dirが
/// 共有writableなら entry を差し替えられ、配下fileが共有writableなら
/// export対象の中身を書き換えられるため、dir・fileの両方を末端まで検査する。
/// Windows では drive root baseline の add-only ACE 例外も package tree
/// 内では適用しない（新規 file 追加で import 対象を後から差し込めるため）。
/// 走査・権限取得の失敗は fail-closed で unsafe 扱いにする。
pub fn hasUnsafeWritableDirectory(allocator: Allocator, io: std.Io, root: []const u8) !bool {
    if (try isUnsafeWritableTreeEntry(allocator, io, root)) return true;
    var directory = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return true;
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (walker.next(io) catch return true) |entry| {
        const full = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(full);
        const unsafe = isUnsafeWritableTreeEntry(allocator, io, full) catch |err| {
            if (err == error.OutOfMemory) return err;
            return true;
        };
        if (unsafe) return true;
    }
    return false;
}

/// package tree 内の entry 用の判定。Windows では add-only baseline 例外を
/// 適用しない（tree 内への新規 file 追加自体が内容侵害になるため）。
fn isUnsafeWritableTreeEntry(allocator: Allocator, io: std.Io, path: []const u8) !bool {
    if (comptime builtin.os.tag == .windows) {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return true;
        return try windowsPathHasUntrustedWriteAccess(allocator, path, stat.kind == .directory, .reject_on_tree);
    }
    return isUnsafeWritablePath(allocator, io, path);
}

/// `root` の親directoryを信頼境界 `boundary`（検査対象から除く）まで遡って
/// 検査する。package root 自体が安全でも、親dirが共有writableなら検証後に
/// root を rename して同 path の別 tree へ置き換えられるため、親まで fail
/// closed で検査する。`boundary` に含まれない root（外部 mutable path 依存）
/// は filesystem root まで遡る。
/// POSIX: sticky bit 付きの共有writable dir（`/tmp` 等）は他者の entry を
/// 削除・rename できないため置換不能とみなし安全側とする。sticky 無しの
/// writable dir は unsafe。Windows: add-only ACE は子の削除・rename を
/// 与えないため祖先では baseline 許容（tree 本体とは別基準）。
pub fn hasUnsafeWritableAncestors(allocator: Allocator, io: std.Io, root: []const u8, boundary: []const u8) !bool {
    var current = try allocator.dupe(u8, root);
    defer allocator.free(current);
    while (std.fs.path.dirname(current)) |parent| {
        if (std.mem.eql(u8, parent, boundary)) break;
        const unsafe = isUnsafeWritableAncestor(allocator, io, parent) catch |err| {
            if (err == error.OutOfMemory) return err;
            return true;
        };
        if (unsafe) return true;
        const owned = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = owned;
    }
    return false;
}

/// 祖先dir用の判定。root/canonical path の親は実体dirである前提。
fn isUnsafeWritableAncestor(allocator: Allocator, io: std.Io, path: []const u8) !bool {
    if (comptime builtin.os.tag == .windows) {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return true;
        return try windowsPathHasUntrustedWriteAccess(allocator, path, stat.kind == .directory, .allow_inherited_baseline);
    }
    if (comptime builtin.os.tag == .wasi) return false;
    const metadata = low_level_fs.stat(io, path, true) catch return true;
    // sticky 無しの writable dir は中の entry を rename/削除できる → unsafe。
    // sticky 付き（/tmp 等）は他者 entry の置換が不可能なため作成のみ →
    // ここでは owner 検査のみ残す（dir 自体の owner が他者なら unsafe）。
    if (metadata.mode & 0o022 != 0 and metadata.mode & 0o1000 == 0) return true;
    return metadata.uid != 0 and metadata.uid != std.c.geteuid();
}

const WinApi = struct {
    const Handle = ?*anyopaque;
    const Sid = ?*anyopaque;
    const SecurityDescriptor = ?*anyopaque;
    const Acl = ?*anyopaque;
    const OwnerSecurityInformation: u32 = 0x00000001;
    const DaclSecurityInformation: u32 = 0x00000004;
    const SeFileObject: u32 = 1;
    const TokenQuery: u32 = 0x0008;
    const TokenUser: u32 = 1;
    const AclSizeInformation: u32 = 2;
    const AccessAllowedAceType: u8 = 0;
    const AccessDeniedAceType: u8 = 1;
    const AccessAllowedObjectAceType: u8 = 5;
    const AccessDeniedObjectAceType: u8 = 6;
    const AccessAllowedCallbackAceType: u8 = 9;
    const AccessDeniedCallbackAceType: u8 = 10;
    const AccessAllowedCallbackObjectAceType: u8 = 11;
    const AccessDeniedCallbackObjectAceType: u8 = 12;
    /// ACE が対象オブジェクト自身ではなく継承先にのみ適用されることを示す
    /// ace_flags のビット（CREATOR OWNER 等の継承用 ACE を拾わない）。
    const InheritOnlyAce: u8 = 0x08;
    /// 親から継承された ACE を示すビット。drive root 既定 ACE の判別に使う
    /// （直接付与された add-only ACE は baseline 例外の対象外）。
    const InheritedObjectAce: u8 = 0x10;

    extern "advapi32" fn GetNamedSecurityInfoW(
        object_name: [*:0]const u16,
        object_type: u32,
        security_info: u32,
        owner: ?*Sid,
        group: ?*Sid,
        dacl: ?*Acl,
        sacl: ?*Acl,
        security_descriptor: *SecurityDescriptor,
    ) callconv(.winapi) u32;
    extern "advapi32" fn IsValidSid(sid: Sid) callconv(.winapi) i32;
    extern "advapi32" fn GetAclInformation(acl: Acl, information: *anyopaque, information_length: u32, information_class: u32) callconv(.winapi) i32;
    extern "advapi32" fn GetAce(acl: Acl, ace_index: u32, ace: *?*anyopaque) callconv(.winapi) i32;
    extern "advapi32" fn OpenProcessToken(process: Handle, desired_access: u32, token: *Handle) callconv(.winapi) i32;
    extern "advapi32" fn GetTokenInformation(token: Handle, information_class: u32, information: ?*anyopaque, information_length: u32, return_length: *u32) callconv(.winapi) i32;
    extern "advapi32" fn EqualSid(sid1: Sid, sid2: Sid) callconv(.winapi) i32;
    extern "advapi32" fn ConvertSidToStringSidW(sid: Sid, string_sid: *?[*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) Handle;
    extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
    extern "kernel32" fn LocalFree(memory: Handle) callconv(.winapi) Handle;

    const AclSize = extern struct { ace_count: u32, bytes_in_use: u32, bytes_free: u32 };
    const AceHeader = extern struct { ace_type: u8, ace_flags: u8, ace_size: u16 };
    const AllowedAce = extern struct { header: AceHeader, mask: u32, sid_start: u32 };
};

fn windowsPathHasUntrustedWriteAccess(allocator: Allocator, path: []const u8, is_directory: bool, users_add_only_policy: UsersAddOnlyPolicy) !bool {
    const Api = WinApi;

    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(path_w);

    var owner: Api.Sid = null;
    var dacl: Api.Acl = null;
    var descriptor: Api.SecurityDescriptor = null;
    const status = Api.GetNamedSecurityInfoW(
        path_w.ptr,
        Api.SeFileObject,
        Api.OwnerSecurityInformation | Api.DaclSecurityInformation,
        &owner,
        null,
        &dacl,
        null,
        &descriptor,
    );
    // ACL retrieval errors, a null DACL (unrestricted), and a null owner all fail closed.
    if (status != 0 or owner == null or dacl == null or descriptor == null) return true;
    defer _ = Api.LocalFree(descriptor);

    var token: Api.Handle = null;
    if (Api.OpenProcessToken(Api.GetCurrentProcess(), Api.TokenQuery, &token) == 0 or token == null) return true;
    defer _ = Api.CloseHandle(token);
    var token_size: u32 = 0;
    _ = Api.GetTokenInformation(token, Api.TokenUser, null, 0, &token_size);
    if (token_size == 0) return true;
    const token_bytes = try allocator.alignedAlloc(u8, std.mem.Alignment.of(usize), token_size);
    defer allocator.free(token_bytes);
    if (Api.GetTokenInformation(token, Api.TokenUser, @ptrCast(token_bytes.ptr), token_size, &token_size) == 0) return true;
    const current_user_sid = @as(*const Api.Sid, @ptrCast(@alignCast(token_bytes.ptr))).*;
    // 所有者は実効ユーザまたは SYSTEM/Administrators のみ信頼する。管理者権限で
    // 作成されたオブジェクトの owner は Windows の既定で Builtin Administrators
    // になるため、厳密なユーザ一致では正当な private dir を untrusted と誤判定する。
    if (current_user_sid == null or Api.IsValidSid(owner) == 0 or Api.IsValidSid(current_user_sid) == 0 or
        (Api.EqualSid(owner, current_user_sid) == 0 and !isWellKnownTrustedWindowsWriter(owner))) return true;

    var acl_size: Api.AclSize = undefined;
    if (Api.GetAclInformation(dacl, @ptrCast(&acl_size), @sizeOf(Api.AclSize), Api.AclSizeInformation) == 0) return true;
    // drive root（`C:\` 等）では当該ACEが継承ではなく直接置かれる（rootに親は
    // 存在しない）ため、対象がfilesystem rootなら直接ACEも既定layoutとして扱う。
    const is_filesystem_root = std.fs.path.dirname(path) == null;
    const add_only_rights: u32 = 0x00000002 | // FILE_ADD_FILE（dir）/ FILE_WRITE_DATA（file）
        0x00000004; // FILE_ADD_SUBDIRECTORY（dir）/ FILE_APPEND_DATA（file）
    const write_rights = add_only_rights |
        0x00000010 | // FILE_WRITE_EA
        0x00000040 | // FILE_DELETE_CHILD
        0x00000100 | // FILE_WRITE_ATTRIBUTES
        0x00010000 | // DELETE
        0x00040000 | // WRITE_DAC
        0x00080000 | // WRITE_OWNER
        0x40000000 | // GENERIC_WRITE
        0x10000000; // GENERIC_ALL
    var ace_index: u32 = 0;
    while (ace_index < acl_size.ace_count) : (ace_index += 1) {
        var ace_pointer: ?*anyopaque = null;
        if (Api.GetAce(dacl, ace_index, &ace_pointer) == 0 or ace_pointer == null) return true;
        const header: *const Api.AceHeader = @ptrCast(@alignCast(ace_pointer.?));
        if (header.ace_size < @sizeOf(Api.AceHeader)) return true;
        // INHERIT_ONLY の ACE（CREATOR OWNER の GENERIC_ALL 継承用 ACE 等）は
        // 対象オブジェクト自身へのアクセスを与えないため無視する。無視しないと
        // 継承 ACE を持つ通常の private dir が untrusted と誤判定される。
        if (header.ace_flags & Api.InheritOnlyAce != 0) continue;
        switch (header.ace_type) {
            Api.AccessDeniedAceType, Api.AccessDeniedObjectAceType, Api.AccessDeniedCallbackAceType, Api.AccessDeniedCallbackObjectAceType => continue,
            Api.AccessAllowedAceType => {
                if (header.ace_size < @sizeOf(Api.AllowedAce)) return true;
                const ace: *const Api.AllowedAce = @ptrCast(@alignCast(ace_pointer.?));
                if (ace.mask & write_rights == 0) continue;
                const sid: Api.Sid = @ptrCast(@constCast(&ace.sid_start));
                if (Api.IsValidSid(sid) == 0) return true;
                // CREATOR OWNER (S-1-3-0) は継承時のプレースホルダであり、対象
                // オブジェクト自身へのアクセスを与えない。
                if (isCreatorOwnerSid(sid)) continue;
                if (Api.EqualSid(sid, current_user_sid) != 0 or isWellKnownTrustedWindowsWriter(sid)) continue;
                // Windows drive root の既定 ACL は BUILTIN\Users へ
                // FILE_ADD_FILE/FILE_ADD_SUBDIRECTORY（新規エントリの作成のみで
                // 既存内容の改変・削除・権限変更は不可）を継承付与する。
                // これを untrusted write とみなすと `D:\` 配下など標準 layout の
                // private dir が全て拒否されるため、dir への add-only Users ACE は
                // baseline として許容する。file への同名 bit は FILE_WRITE_DATA/
                // APPEND_DATA（実改変）なので除外しない。また add 以外の権利を
                // 含む Users ACE（FILE_DELETE_CHILD/GENERIC_ALL 等）は拒否する。
                // 例外は継承（INHERITED_ACE）由来の ACE と filesystem root へ
                // 直接置かれる既定 ACE に限定する — それ以外の dir へ直接付与された
                // add-only ACE は運用者の意図付与であり既定 layout ではないため
                // baseline に含めない。package tree 本体（reject_on_tree）では
                // 新規 file 追加自体が内容侵害になるため baseline 例外を一切適用しない。
                if (users_add_only_policy == .allow_inherited_baseline and
                    is_directory and isBuiltinUsersSid(sid) and
                    ace.mask & (write_rights & ~add_only_rights) == 0 and
                    (header.ace_flags & Api.InheritedObjectAce != 0 or is_filesystem_root)) continue;
                return true;
            },
            // Object/callback ACEs have conditional or object-specific semantics.
            // A write-capable ACE of these types is not safely reducible here.
            Api.AccessAllowedObjectAceType, Api.AccessAllowedCallbackAceType, Api.AccessAllowedCallbackObjectAceType => {
                if (header.ace_size < @sizeOf(Api.AceHeader) + @sizeOf(u32)) return true;
                const mask: *const u32 = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(ace_pointer.?)) + @sizeOf(Api.AceHeader)));
                if (mask.* & write_rights != 0) return true;
            },
            else => return true,
        }
    }
    return false;
}

/// CREATOR OWNER (S-1-3-0) かどうかを SID バイナリから判定する。
fn isCreatorOwnerSid(sid: ?*anyopaque) bool {
    if (sid == null) return false;
    const bytes: [*]const u8 = @ptrCast(sid.?);
    if (bytes[0] != 1 or bytes[1] != 1) return false;
    const authority = bytes[2..8];
    if (authority[0] != 0 or authority[1] != 0 or authority[2] != 0 or authority[3] != 0 or
        authority[4] != 0 or authority[5] != 3) return false; // SECURITY_CREATOR_SID_AUTHORITY = 3
    return @as(*align(1) const u32, @ptrCast(bytes + 8)).* == 0;
}

/// BUILTIN\Users (S-1-5-32-545) かどうかを SID バイナリから判定する。
fn isBuiltinUsersSid(sid: ?*anyopaque) bool {
    if (sid == null) return false;
    const bytes: [*]const u8 = @ptrCast(sid.?);
    if (bytes[0] != 1 or bytes[1] < 2) return false;
    const authority = bytes[2..8];
    if (authority[0] != 0 or authority[1] != 0 or authority[2] != 0 or authority[3] != 0 or
        authority[4] != 0 or authority[5] != 5) return false; // SECURITY_NT_AUTHORITY = 5
    if (@as(*align(1) const u32, @ptrCast(bytes + 8)).* != 32) return false;
    return @as(*align(1) const u32, @ptrCast(bytes + 12)).* == 545;
}

fn isWellKnownTrustedWindowsWriter(sid: ?*anyopaque) bool {
    if (sid == null) return false;
    const bytes: [*]const u8 = @ptrCast(sid.?);
    if (bytes[0] != 1 or bytes[1] < 1) return false;
    const authority = bytes[2..8];
    const sub = @as(*align(1) const u32, @ptrCast(bytes + 8)).*;
    const is_nt_authority = authority[0] == 0 and authority[1] == 0 and authority[2] == 0 and authority[3] == 0 and authority[4] == 0 and authority[5] == 5;
    if (is_nt_authority and sub == 18) return true; // LocalSystem: S-1-5-18
    if (is_nt_authority and sub == 32 and bytes[1] >= 2) {
        const second = @as(*align(1) const u32, @ptrCast(bytes + 12)).*;
        if (second == 544) return true; // Builtin Administrators: S-1-5-32-544
    }
    return false;
}

/// SID を `S-1-5-...` 文字列へ変換する。失敗時は null。
fn windowsSidText(allocator: Allocator, sid: WinApi.Sid) ?[]u8 {
    if (sid == null) return null;
    var text_w: ?[*:0]const u16 = null;
    if (WinApi.ConvertSidToStringSidW(sid, &text_w) == 0 or text_w == null) return null;
    defer _ = WinApi.LocalFree(@ptrCast(@constCast(text_w.?)));
    return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(text_w.?)) catch null;
}

/// CI 診断用: owner・実効ユーザ・DACL の各 ACE を stderr へ出力する。
/// Windows 専用。テスト失敗時の原因特定に使い、本番経路からは呼ばない。
fn windowsAclDebugDump(allocator: Allocator, path: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch return;
    defer allocator.free(path_w);
    var owner: WinApi.Sid = null;
    var dacl: WinApi.Acl = null;
    var descriptor: WinApi.SecurityDescriptor = null;
    const status = WinApi.GetNamedSecurityInfoW(path_w.ptr, WinApi.SeFileObject, WinApi.OwnerSecurityInformation | WinApi.DaclSecurityInformation, &owner, null, &dacl, null, &descriptor);
    if (status != 0) {
        std.debug.print("acl-dump {s}: GetNamedSecurityInfoW={d}\n", .{ path, status });
        return;
    }
    defer _ = WinApi.LocalFree(descriptor);
    const owner_text = windowsSidText(allocator, owner);
    defer if (owner_text) |text| allocator.free(text);
    std.debug.print("acl-dump {s}: owner={s}\n", .{ path, owner_text orelse "?" });
    var token: WinApi.Handle = null;
    if (WinApi.OpenProcessToken(WinApi.GetCurrentProcess(), WinApi.TokenQuery, &token) != 0 and token != null) {
        defer _ = WinApi.CloseHandle(token);
        var token_size: u32 = 0;
        _ = WinApi.GetTokenInformation(token, WinApi.TokenUser, null, 0, &token_size);
        if (token_size != 0) {
            if (allocator.alignedAlloc(u8, std.mem.Alignment.of(usize), token_size)) |token_bytes| {
                defer allocator.free(token_bytes);
                if (WinApi.GetTokenInformation(token, WinApi.TokenUser, @ptrCast(token_bytes.ptr), token_size, &token_size) != 0) {
                    const user_sid = @as(*const WinApi.Sid, @ptrCast(@alignCast(token_bytes.ptr))).*;
                    const user_text = windowsSidText(allocator, user_sid);
                    defer if (user_text) |text| allocator.free(text);
                    std.debug.print("acl-dump {s}: user={s}\n", .{ path, user_text orelse "?" });
                }
            } else |_| {}
        }
    }
    var acl_size: WinApi.AclSize = undefined;
    if (WinApi.GetAclInformation(dacl, @ptrCast(&acl_size), @sizeOf(WinApi.AclSize), WinApi.AclSizeInformation) == 0) {
        std.debug.print("acl-dump {s}: GetAclInformation failed\n", .{path});
        return;
    }
    var index: u32 = 0;
    while (index < acl_size.ace_count) : (index += 1) {
        var ace_pointer: ?*anyopaque = null;
        if (WinApi.GetAce(dacl, index, &ace_pointer) == 0 or ace_pointer == null) continue;
        const header: *const WinApi.AceHeader = @ptrCast(@alignCast(ace_pointer.?));
        if (header.ace_size < @sizeOf(WinApi.AllowedAce)) {
            std.debug.print("acl-dump {s}: ace[{d}] type={d} flags=0x{x} small\n", .{ path, index, header.ace_type, header.ace_flags });
            continue;
        }
        const ace: *const WinApi.AllowedAce = @ptrCast(@alignCast(ace_pointer.?));
        const sid_text = windowsSidText(allocator, @ptrCast(@constCast(&ace.sid_start)));
        defer if (sid_text) |text| allocator.free(text);
        std.debug.print("acl-dump {s}: ace[{d}] type={d} flags=0x{x} mask=0x{x} sid={s}\n", .{ path, index, header.ace_type, header.ace_flags, ace.mask, sid_text orelse "?" });
    }
}

test "POSIX owner check accepts current-user-owned non-shared paths" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = "[package]\nname = \"safe\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const manifest = try std.fs.path.join(allocator, &.{ root, "nako.toml" });
    defer allocator.free(manifest);
    // tmpDir配下は実効ユーザ所有 — 0644/0755系でもowner信頼により安全側。
    try std.testing.expect(!try isUnsafeWritablePath(allocator, io, root));
    try std.testing.expect(!try isUnsafeWritablePath(allocator, io, manifest));
    // root所有の0644 file（共有writableでないシステムpath）は引き続き安全側。
    if (std.Io.Dir.cwd().statFile(io, "/etc/hosts", .{})) |_| {
        try std.testing.expect(!try isUnsafeWritablePath(allocator, io, "/etc/hosts"));
    } else |_| {}
}

test "Windows ACL check accepts a private temporary project directory and file" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = "[package]\nname = \"safe\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const manifest = try std.fs.path.join(allocator, &.{ root, "nako.toml" });
    defer allocator.free(manifest);
    if (try windowsPathHasUntrustedWriteAccess(allocator, root, true, .allow_inherited_baseline)) {
        windowsAclDebugDump(allocator, root);
        return error.TestUnexpectedResult;
    }
    if (try windowsPathHasUntrustedWriteAccess(allocator, manifest, false, .allow_inherited_baseline)) {
        windowsAclDebugDump(allocator, manifest);
        return error.TestUnexpectedResult;
    }
}
