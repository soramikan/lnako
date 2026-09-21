const std = @import("std");

/// `package.include` 用の最小globマッチャ。
/// - `*`  : `/` をまたがない任意文字列
/// - `**` : `/` をまたぐ任意の0個以上のpath成分
/// - `?`  : `/` 以外の1文字
/// 上記以外はリテラルとして比較する。`[...]`・`{a,b}`・`!`否定は対象外。
/// patternとpathはともにPOSIX区切りの正規化済みパスを前提とする。
/// パターンがdir名のみを指す場合（例: `data`）はその配下全体に一致する
/// （`data` は `data/**` と同義）。
pub fn match(pattern: []const u8, path: []const u8) bool {
    var pattern_segments = std.mem.splitScalar(u8, pattern, '/');
    var path_segments = std.mem.splitScalar(u8, path, '/');
    return matchSegments(&pattern_segments, &path_segments);
}

fn matchSegments(pattern: *std.mem.SplitIterator(u8, .scalar), path: *std.mem.SplitIterator(u8, .scalar)) bool {
    const segment = pattern.next() orelse return true;
    if (std.mem.eql(u8, segment, "**")) {
        // `**` は0個以上のpath成分へ展開する。
        var rest = pattern.*;
        if (rest.next() == null) return true;
        var probe = path.*;
        while (true) {
            var candidate_pattern = rest;
            var candidate_path = probe;
            if (matchSegments(&candidate_pattern, &candidate_path)) return true;
            if (probe.next() == null) return false;
        }
    }
    const path_segment = path.next() orelse return false;
    if (!matchSegment(segment, path_segment)) return false;
    return matchSegments(pattern, path);
}

/// `/` を含まない成分内の `*` `?` マッチ。
fn matchSegment(pattern: []const u8, name: []const u8) bool {
    if (pattern.len == 0) return name.len == 0;
    const head = pattern[0];
    if (head == '*') {
        var index: usize = 0;
        while (index <= name.len) : (index += 1) {
            if (matchSegment(pattern[1..], name[index..])) return true;
        }
        return false;
    }
    if (name.len == 0) return false;
    if (head != '?' and head != name[0]) return false;
    return matchSegment(pattern[1..], name[1..]);
}

test "globパターンでpathを照合する" {
    try std.testing.expect(match("src/index.nako3", "src/index.nako3"));
    try std.testing.expect(!match("src/index.nako3", "src/other.nako3"));
    try std.testing.expect(match("src/*.nako3", "src/index.nako3"));
    try std.testing.expect(!match("src/*.nako3", "src/sub/index.nako3"));
    try std.testing.expect(match("src/**/*.nako3", "src/sub/deep/index.nako3"));
    try std.testing.expect(match("src/**/*.nako3", "src/index.nako3"));
    try std.testing.expect(match("**/*.nako3", "index.nako3"));
    try std.testing.expect(match("data/*.json", "data/dic.json"));
    try std.testing.expect(match("?", "a"));
    try std.testing.expect(!match("?", "ab"));
    // ディレクトリ指定は配下全体を含む。
    try std.testing.expect(match("data", "data/sub/x.bin"));
}
