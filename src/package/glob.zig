const std = @import("std");

/// `package.include` 用の最小globマッチャ。
/// - `*`  : `/` をまたがない任意文字列
/// - `**` : `/` をまたぐ任意の0個以上のpath成分
/// - `?`  : `/` 以外の1文字
/// 上記以外はリテラルとして比較する。`[...]`・`{a,b}`・`!`否定は対象外。
/// patternとpathはともにPOSIX区切りの正規化済みパスを前提とする。
/// パターンを消費し尽くした時点で path に未消費の成分が残る場合は不一致
/// （`*.txt` は `a.txt/sub/file` に一致しない）。末尾 `**` だけが残りの
/// 全成分へ一致する。glob を含まないパターンの directory 接頭辞扱い
/// （`data` が `data/sub/x` に一致する）は呼出し側の
/// `includePatternMatches` が担う。
pub fn match(pattern: []const u8, path: []const u8) bool {
    var pattern_segments = std.mem.splitScalar(u8, pattern, '/');
    var path_segments = std.mem.splitScalar(u8, path, '/');
    return matchSegments(&pattern_segments, &path_segments);
}

fn matchSegments(pattern: *std.mem.SplitIterator(u8, .scalar), path: *std.mem.SplitIterator(u8, .scalar)) bool {
    // パターンを消費し尽くしたとき path 側も尽きている場合のみ一致。
    // これを緩めると `*.txt` が `a.txt/sub/file` のような深い path へ
    // 一致し、意図しないファイルを payload に収録してしまう。
    const segment = pattern.next() orelse return path.next() == null;
    if (std.mem.eql(u8, segment, "**")) {
        // `**` は0個以上のpath成分へ展開する。末尾確認は probe コピーで
        // 行い、再帰へ渡す rest 自体は `**` 直後の位置を維持する。
        const rest = pattern.*;
        var rest_probe = rest;
        if (rest_probe.next() == null) return true;
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
    // `**` の末尾確認で iterator が進まないこと（`*.nako3` は消費されず
    // 拡張子の違うファイルへ一致しない）。
    try std.testing.expect(!match("src/**/*.nako3", "src/private.bin"));
    try std.testing.expect(!match("src/**/*.nako3", "src/sub/notes.txt"));
    try std.testing.expect(match("**/*.nako3", "index.nako3"));
    try std.testing.expect(match("data/*.json", "data/dic.json"));
    try std.testing.expect(match("?", "a"));
    try std.testing.expect(!match("?", "ab"));
    // 末尾 `**` だけが残り成分全体へ一致する。パターン消費後に path が
    // 残る場合は不一致（`data` のようなリテラル dir 接頭辞は
    // `includePatternMatches` の責務）。
    try std.testing.expect(match("data/**", "data/sub/x.bin"));
    try std.testing.expect(!match("data", "data/sub/x.bin"));
    try std.testing.expect(!match("*.txt", "a.txt/sub/file"));
    try std.testing.expect(!match("assets/*.txt", "assets/readme.txt/sub/secret.bin"));
}
