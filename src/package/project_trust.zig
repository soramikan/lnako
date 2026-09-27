const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// Reject project paths whose owner or ACL/mode permits untrusted modification.
/// On Windows ACL parsing is deliberately conservative: unknown ACE forms fail closed.
pub fn isUnsafeWritablePath(allocator: Allocator, io: std.Io, path: []const u8) !bool {
    if (comptime builtin.os.tag == .windows) return try windowsPathHasUntrustedWriteAccess(allocator, path);
    if (comptime builtin.os.tag == .wasi) return false;
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    return @intFromEnum(stat.permissions) & 0o022 != 0;
}

/// `root` 自体と配下の全ディレクトリを走査し、共有writableなディレクトリが
/// あれば true を返す。materialized tree は `.nako` 直下の権限がprivateでも
/// 配下dirが共有writableなら中身を差し替えられるため、末端まで検査する。
/// 走査・権限取得の失敗は fail-closed で unsafe 扱いにする。
pub fn hasUnsafeWritableDirectory(allocator: Allocator, io: std.Io, root: []const u8) !bool {
    if (try isUnsafeWritablePath(allocator, io, root)) return true;
    var directory = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return true;
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (walker.next(io) catch return true) |entry| {
        if (entry.kind != .directory) continue;
        const full = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(full);
        const unsafe = isUnsafeWritablePath(allocator, io, full) catch |err| {
            if (err == error.OutOfMemory) return err;
            return true;
        };
        if (unsafe) return true;
    }
    return false;
}

fn windowsPathHasUntrustedWriteAccess(allocator: Allocator, path: []const u8) !bool {
    const Api = struct {
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
        extern "kernel32" fn GetCurrentProcess() callconv(.winapi) Handle;
        extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
        extern "kernel32" fn LocalFree(memory: Handle) callconv(.winapi) Handle;

        const AclSize = extern struct { ace_count: u32, bytes_in_use: u32, bytes_free: u32 };
        const AceHeader = extern struct { ace_type: u8, ace_flags: u8, ace_size: u16 };
        const AllowedAce = extern struct { header: AceHeader, mask: u32, sid_start: u32 };
    };

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
    if (current_user_sid == null or Api.IsValidSid(owner) == 0 or Api.IsValidSid(current_user_sid) == 0 or
        Api.EqualSid(owner, current_user_sid) == 0) return true;

    var acl_size: Api.AclSize = undefined;
    if (Api.GetAclInformation(dacl, @ptrCast(&acl_size), @sizeOf(Api.AclSize), Api.AclSizeInformation) == 0) return true;
    const write_rights = 0x00000002 | // FILE_ADD_FILE / FILE_WRITE_DATA
        0x00000004 | // FILE_ADD_SUBDIRECTORY / FILE_APPEND_DATA
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
        switch (header.ace_type) {
            Api.AccessDeniedAceType, Api.AccessDeniedObjectAceType, Api.AccessDeniedCallbackAceType, Api.AccessDeniedCallbackObjectAceType => continue,
            Api.AccessAllowedAceType => {
                if (header.ace_size < @sizeOf(Api.AllowedAce)) return true;
                const ace: *const Api.AllowedAce = @ptrCast(@alignCast(ace_pointer.?));
                if (ace.mask & write_rights == 0) continue;
                const sid: Api.Sid = @ptrCast(@constCast(&ace.sid_start));
                if (Api.IsValidSid(sid) == 0 or
                    (Api.EqualSid(sid, current_user_sid) == 0 and !isWellKnownTrustedWindowsWriter(sid))) return true;
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
    try std.testing.expect(!try windowsPathHasUntrustedWriteAccess(allocator, root));
    try std.testing.expect(!try windowsPathHasUntrustedWriteAccess(allocator, manifest));
}
