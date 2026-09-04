const builtin = @import("builtin");
const std = @import("std");

pub fn nodeBasename(path: []const u8) []const u8 {
    return nodeBasenameFor(path, builtin.os.tag == .windows);
}

pub fn nodeBasenameFor(path: []const u8, windows: bool) []const u8 {
    // This follows Node's path.win32.basename loop: the drive prefix is
    // skipped before trimming trailing separators, and the first separator
    // before the basename becomes the exclusive start.  In particular, the
    // loop preserves mixed `/` and `\\` runs instead of normalizing them.
    var start: usize = 0;
    var end: ?usize = null;
    var matched_separator = true;
    if (windows and path.len >= 2 and isWindowsDriveLetter(path[0]) and path[1] == ':') start = 2;

    var index = path.len;
    while (index > start) {
        index -= 1;
        if (nodePathSeparator(path[index], windows)) {
            if (!matched_separator) {
                start = index + 1;
                break;
            }
        } else if (end == null) {
            matched_separator = false;
            end = index + 1;
        }
    }
    return path[start..(end orelse return "")];
}

pub fn nodeDirname(path: []const u8) []const u8 {
    return nodeDirnameFor(path, builtin.os.tag == .windows);
}

pub fn nodeDirnameFor(path: []const u8, windows: bool) []const u8 {
    if (windows) return nodeDirnameWindowsFor(path);
    if (path.len == 0) return ".";
    if (path.len == 1) return if (nodePathSeparator(path[0], false)) path else ".";
    var end = path.len;
    while (end > 0 and nodePathSeparator(path[end - 1], false)) end -= 1;
    if (end == 0) return path[0..1];

    var start = end;
    while (start > 0 and !nodePathSeparator(path[start - 1], false)) start -= 1;
    if (start == 0) return ".";
    if (start == 1 and nodePathSeparator(path[0], false)) return path[0..1];
    if (start == 2 and nodePathSeparator(path[0], false) and nodePathSeparator(path[1], false)) return path[0..2];
    return path[0 .. start - 1];
}

pub fn nodeDirnameWindowsFor(path: []const u8) []const u8 {
    // Port the root scan used by Node 24's path.win32.dirname.  A matched
    // UNC root is only special when it has a server, share, and a leftover
    // component; a root-only path is returned unchanged.  This matters for
    // mixed separator input such as `//\\server/share/\\file`.
    const len = path.len;
    if (len == 0) return ".";
    if (len == 1) return if (nodePathSeparator(path[0], true)) path else ".";

    var root_end: ?usize = null;
    var offset: usize = 0;
    const first = path[0];
    if (nodePathSeparator(first, true)) {
        root_end = 1;
        offset = 1;
        if (nodePathSeparator(path[1], true)) {
            var index: usize = 2;
            var last = index;
            while (index < len and !nodePathSeparator(path[index], true)) index += 1;
            if (index < len and index != last) {
                last = index;
                while (index < len and nodePathSeparator(path[index], true)) index += 1;
                if (index < len and index != last) {
                    last = index;
                    while (index < len and !nodePathSeparator(path[index], true)) index += 1;
                    if (index == len) return path;
                    if (index != last) {
                        root_end = index + 1;
                        offset = index + 1;
                    }
                }
            }
        }
    } else if (isWindowsDriveLetter(first) and path[1] == ':') {
        root_end = if (len > 2 and nodePathSeparator(path[2], true)) 3 else 2;
        offset = root_end.?;
    }

    var end: ?usize = null;
    var matched_separator = true;
    var index = len;
    while (index > offset) {
        index -= 1;
        if (nodePathSeparator(path[index], true)) {
            if (!matched_separator) {
                end = index;
                break;
            }
        } else {
            matched_separator = false;
        }
    }
    if (end == null) end = root_end orelse return ".";
    return path[0..end.?];
}

pub fn isWindowsDriveLetter(byte: u8) bool {
    return byte >= 'A' and byte <= 'Z' or byte >= 'a' and byte <= 'z';
}

pub fn nodePathSeparator(byte: u8, windows: bool) bool {
    return byte == std.fs.path.sep or (windows and (byte == '/' or byte == '\\'));
}

pub fn nodePathSeparatorWide(unit: u16, windows: bool) bool {
    return unit == @as(u16, std.fs.path.sep) or (windows and (unit == '/' or unit == '\\'));
}

pub fn isWindowsDriveLetterWide(unit: u16) bool {
    return unit >= 'A' and unit <= 'Z' or unit >= 'a' and unit <= 'z';
}
