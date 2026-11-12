//! 実行ファイル自身の path 解決（Issue #56 の移動可能 loader）。
//!
//! 生成物が自分自身の隣にある payload（`<out>.deps/`）を解決できるよう、
//! argv[0] を使わず OS の自己 path API から絶対 path を得る。argv[0] は
//! PATH 経由の起動や相対指定で実際の配置と一致しないため探索の基準に
//! できない。OS 差はここで吸収し、呼び出し側は解決済み絶対 path を受ける。
//!
//! - Linux: `/proc/self/exe` の readlink
//! - macOS: `_NSGetExecutablePath` + realpath
//! - Windows: `GetModuleFileNameW`（UTF-16 → WTF-8）
//! - その他 POSIX（FreeBSD 等）: std.process.executablePathAlloc が提供する
//!   kernel 情報へ委譲（CI の正式 3 OS 外の保険）。
const std = @import("std");
const builtin = @import("builtin");

/// 実行ファイル自身の絶対 path を返す（caller が free）。
/// symlink で起動された場合も、OS API の契約に従い解決後の実体 path を
/// 返す（macOS は realpath、Linux の `/proc/self/exe` はリンク先）。
/// payload の探索はこの path の directory を基準に行うため、symlink 経由
/// の起動では symlink の配置ではなく実体の配置が基準になる。
pub fn selfExecutablePathAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    switch (builtin.os.tag) {
        .linux => return readSelfExeLink(allocator, io),
        .macos, .ios, .maccatalyst, .tvos, .visionos, .watchos => return nsExecutablePath(allocator, io),
        .windows => return windowsExecutablePath(allocator, io),
        else => {
            const path = try std.process.executablePathAlloc(io, allocator);
            defer allocator.free(path);
            return allocator.dupe(u8, path);
        },
    }
}

/// `payload` が marker（`@self/`）で始まる場合、`<実行ファイル>.deps/` を
/// 基準に解決した絶対 path を返す（`lnako build --bundle-deps` の payload
/// 配置規約。実行ファイルが `dist/app` なら `dist/app.deps/` 配下の
/// `rest`）。marker 以外は null（既存の相対/絶対 path 意味を変えない）。
/// `marker` と `payload_suffix` は呼び出し側が定義した値を使う。
pub fn resolveMarker(
    allocator: std.mem.Allocator,
    io: std.Io,
    payload: []const u8,
    comptime marker: []const u8,
    payload_suffix: []const u8,
) !?[]u8 {
    if (!std.mem.startsWith(u8, payload, marker)) return null;
    const rest = payload[marker.len..];
    // marker 以降は payload directory 配下に留まることを要求する。`..` で
    // `<out>.deps/` の外（任意の共有 library）へ出る指定は解決しない。
    // 現状 marker は build 時にのみ生成されるが、path を組み立てる側が
    // 増えても脱出経路を作らないようここで閉じる。
    if (!restIsContained(rest)) return error.PayloadPathEscapesPayload;
    const executable = selfExecutablePathAlloc(allocator, io) catch return error.SelfExecutablePathUnavailable;
    defer allocator.free(executable);
    const joined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ executable, payload_suffix });
    defer allocator.free(joined);
    const with_rest = try std.fs.path.join(allocator, &.{ joined, rest });
    return with_rest;
}

/// marker 以降の相対 path が payload directory 内に留まるか。absolute と
/// `..` segment を拒否する（`.` と空 segment は許容）。
fn restIsContained(rest: []const u8) bool {
    if (rest.len == 0) return false;
    if (std.fs.path.isAbsolute(rest)) return false;
    // marker は `/` 区切りで書かれるが、Windows では `\\` も不正な
    // 区切りとして混入し得るため両方を segment 境界として扱う。
    var index: usize = 0;
    while (index <= rest.len) {
        const start = index;
        while (index < rest.len and rest[index] != '/' and rest[index] != '\\') index += 1;
        if (std.mem.eql(u8, rest[start..index], "..")) return false;
        index += 1;
    }
    return true;
}

fn readSelfExeLink(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // readLink は書き込んだ byte 数を返す（[]u8 ではない）。
    const length = try std.Io.Dir.cwd().readLink(io, "/proc/self/exe", &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

fn nsExecutablePath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const c = std.c;
    var symlink_path_buf: [c.PATH_MAX + 1]u8 = undefined;
    var size: u32 = symlink_path_buf.len;
    if (c._NSGetExecutablePath(&symlink_path_buf, &size) != 0) return error.NameTooLong;
    const symlink_path = std.mem.sliceTo(&symlink_path_buf, 0);
    // `_NSGetExecutablePath` の戻りは symlink の可能性があるため realpath で
    // 実体へ解決する（zig std の processExecutablePath と同じ規約）。
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, symlink_path, allocator) catch {
        // realpath に失敗した場合（削除後の実行など）は生の path を使う。
        return allocator.dupe(u8, symlink_path);
    };
    // realPathFileAlloc は sentinel 付きで確保するため、[]u8 へ型を合わせて
    // から返す（free は caller 側の dupe 契約に揃える）。
    defer allocator.free(resolved);
    return allocator.dupe(u8, resolved);
}

fn windowsExecutablePath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    _ = io;
    var wide: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const length = kernel32.GetModuleFileNameW(null, &wide, wide.len);
    if (length == 0) return error.SelfExecutablePathUnavailable;
    // GetModuleFileNameW は WTF-16 を返す。zig の path 層は WTF-8 で扱う。
    return std.unicode.wtf16LeToWtf8Alloc(allocator, wide[0..length]);
}

const kernel32 = struct {
    extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, filename: [*]u16, size: u32) callconv(.winapi) u32;
};

test "selfExecutablePathAllocは絶対pathを返す" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = try selfExecutablePathAlloc(allocator, io);
    defer allocator.free(path);
    try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expect(path.len > 0);
}

test "resolveMarkerはmarker以外を解決しない" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expect((try resolveMarker(allocator, io, "/absolute/lib.so", "@self/", ".deps")) == null);
    try std.testing.expect((try resolveMarker(allocator, io, "./relative/lib.so", "@self/", ".deps")) == null);
}

test "resolveMarkerはpayload外へ出る指定を拒否する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // `..` による脱出と absolute path は payload 内に留まらない。
    try std.testing.expectError(error.PayloadPathEscapesPayload, resolveMarker(allocator, io, "@self/../../etc/lib.so", "@self/", ".deps"));
    try std.testing.expectError(error.PayloadPathEscapesPayload, resolveMarker(allocator, io, "@self/a/../../b.so", "@self/", ".deps"));
    try std.testing.expectError(error.PayloadPathEscapesPayload, resolveMarker(allocator, io, "@self//abs.so", "@self/", ".deps"));
    // 通常の相対は通る。
    const ok = (try resolveMarker(allocator, io, "@self/pkg/sub/plugin.so", "@self/", ".deps")) orelse return error.TestUnexpectedResult;
    defer allocator.free(ok);
    const ok_tail = try std.fs.path.join(allocator, &.{ ".deps", "pkg", "sub", "plugin.so" });
    defer allocator.free(ok_tail);
    try std.testing.expect(std.mem.endsWith(u8, ok, ok_tail));
}

test "resolveMarkerは実行ファイル隣接のpayloadへ解決する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // marker 相当の path は存在しなくても path 合成として解決する。
    const resolved = (try resolveMarker(allocator, io, "@self/pkg/plugin.so", "@self/", ".deps")) orelse return error.TestUnexpectedResult;
    defer allocator.free(resolved);
    try std.testing.expect(std.fs.path.isAbsolute(resolved));
    const expected_tail = try std.fs.path.join(allocator, &.{ ".deps", "pkg", "plugin.so" });
    defer allocator.free(expected_tail);
    try std.testing.expect(std.mem.endsWith(u8, resolved, expected_tail));
}
