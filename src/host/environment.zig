const std = @import("std");
const builtin = @import("builtin");

pub fn homeDirectory(environment: *const std.process.Environ.Map) ?[]const u8 {
    return environment.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
}

pub fn temporaryDirectory(environment: *const std.process.Environ.Map) []const u8 {
    // Nodeの`os.tmpdir()`と同じ候補順で選ぶ。空文字の環境変数はfalseyとして
    // 未設定と同じに扱い、次の候補へフォールバックする。空文字を採用すると
    // 一時フォルダがCWD基準になってしまうため。
    const value = if (builtin.os.tag == .windows)
        nonEmpty(environment.get("TEMP")) orelse nonEmpty(environment.get("TMP")) orelse "."
    else
        nonEmpty(environment.get("TMPDIR")) orelse "/tmp";
    const trimmed = std.mem.trimEnd(u8, value, "/\\");
    return if (trimmed.len == 0) value else trimmed;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

pub fn parseOptionalI64(value: ?[]const u8) ?i64 {
    return std.fmt.parseInt(i64, value orelse return null, 10) catch null;
}

pub fn parseOptionalU64(value: ?[]const u8) ?u64 {
    return std.fmt.parseInt(u64, value orelse return null, 10) catch null;
}

pub fn parseOptionalF64(value: ?[]const u8) ?f64 {
    return std.fmt.parseFloat(f64, value orelse return null) catch null;
}

test "temporaryDirectoryは空の環境変数を未設定として扱う" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TEMP", "");
    try environment.put("TMP", "");
    try environment.put("TMPDIR", "");
    const expected = if (builtin.os.tag == .windows) "." else "/tmp";
    try std.testing.expectEqualStrings(expected, temporaryDirectory(&environment));
}

test "temporaryDirectoryはWindowsで空のTEMPをTMPへフォールバックする" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TEMP", "");
    try environment.put("TMP", "C:\\Temp");
    try std.testing.expectEqualStrings("C:\\Temp", temporaryDirectory(&environment));
}

test "temporaryDirectoryはPOSIXで空のTMPDIRを既定へフォールバックする" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TMPDIR", "");
    try environment.put("TEMP", "/ignored");
    try std.testing.expectEqualStrings("/tmp", temporaryDirectory(&environment));
}

test "temporaryDirectoryは非空TMPDIRの末尾区切りを除去する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TMPDIR", "/var/tmp/");
    try std.testing.expectEqualStrings("/var/tmp", temporaryDirectory(&environment));
}
