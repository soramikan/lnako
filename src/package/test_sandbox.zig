const std = @import("std");
const builtin = @import("builtin");

/// std.testing.tmpDir と同じ契約（dir/cleanup）のテスト用sandboxを返す。
///
/// Windowsの既定drive root ACLは BUILTIN\Users へ FILE_ADD_FILE /
/// FILE_ADD_SUBDIRECTORY（新規作成のみ・削除や改変は不可）を継承ACEとして
/// 付与するため、checkout配下の .zig-cache/tmp に作ったpackage treeは
/// project_trustのtree検査（tree内add-only ACE拒否）へ必ず不合格になる。
/// ユーザープロファイル配下のTEMPには当該ACEが無いため、Windowsでは
/// TEMP直下へ作成し、それ以外では従来どおり .zig-cache/tmp を使う。
pub fn tmpDir(opts: std.Io.Dir.OpenOptions) std.testing.TmpDir {
    if (comptime builtin.os.tag == .windows) return windowsTmpDir(opts);
    return std.testing.tmpDir(opts);
}

fn windowsTmpDir(opts: std.Io.Dir.OpenOptions) std.testing.TmpDir {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var random_bytes: [12]u8 = undefined;
    io.random(&random_bytes);
    var sub_path: [16]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

    const base = envOwned(allocator, "TEMP") orelse
        envOwned(allocator, "TMP") orelse
        userProfileTemp(allocator) orelse
        @panic("unable to locate TEMP dir for test sandbox");
    defer allocator.free(base);

    var parent_dir = std.Io.Dir.openDirAbsolute(io, base, .{}) catch
        @panic("unable to open TEMP dir for test sandbox");
    errdefer parent_dir.close(io);
    const dir = parent_dir.createDirPathOpen(io, &sub_path, .{ .open_options = opts }) catch
        @panic("unable to make test sandbox dir under TEMP");
    return .{ .dir = dir, .parent_dir = parent_dir, .sub_path = sub_path };
}

fn envOwned(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    const environ: std.process.Environ = .{ .block = .global };
    const value = std.process.Environ.getAlloc(environ, allocator, key) catch return null;
    const trimmed = std.mem.trimEnd(u8, value, "/\\");
    if (trimmed.len == 0) {
        allocator.free(value);
        return null;
    }
    if (trimmed.len == value.len) return value;
    defer allocator.free(value);
    return allocator.dupe(u8, trimmed) catch null;
}

fn userProfileTemp(allocator: std.mem.Allocator) ?[]u8 {
    const profile = envOwned(allocator, "USERPROFILE") orelse return null;
    defer allocator.free(profile);
    return std.fmt.allocPrint(allocator, "{s}\\AppData\\Local\\Temp", .{profile}) catch null;
}
