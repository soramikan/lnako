//! TOML の行・字句レベル走査 helper。
//! `project_edit.zig` の依存表編集（`insertEntry`/`removeEntry`）から
//! 使う純粋な字句レベルの操作で、行・section 単位の文脈は持たない。

const std = @import("std");

const Allocator = std.mem.Allocator;

/// TOML 基本文字列の中身として安全な形へエスケープする。`"`・`\`・
/// 制御文字をエスケープシーケンスへ変換する（Windows path の `\` や
/// URL 中の `"` が manifest を壊さないようにするため）。
pub fn tomlEscape(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            0x08 => try out.appendSlice(a, "\\b"),
            0x0C => try out.appendSlice(a, "\\f"),
            else => {
                if (ch < 0x20 or ch == 0x7F) {
                    try out.appendSlice(a, try std.fmt.allocPrint(a, "\\u{X:0>4}", .{ch}));
                } else {
                    try out.append(a, ch);
                }
            },
        }
    }
    return out.items;
}

/// `offset` 以降の最初の `\n` の位置（なければ source.len）。
pub fn lineEnd(source: []const u8, offset: usize) usize {
    var index = offset;
    while (index < source.len and source[index] != '\n') index += 1;
    return index;
}

/// 行末の TOML コメントを除去する。`#` が基本文字列・literal 文字列の
/// 内側にある場合はコメント開始とみなさない（`"a#b"]` のような細工
/// をヘッダとして誤認しない）。
pub fn stripTomlComment(text: []const u8) []const u8 {
    const String = enum { none, basic, literal };
    var string: String = .none;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const ch = text[index];
        switch (string) {
            .basic => {
                if (ch == '\\') {
                    index += 1;
                    continue;
                }
                if (ch == '"') string = .none;
            },
            .literal => if (ch == '\'') {
                string = .none;
            },
            .none => switch (ch) {
                '#' => return text[0..index],
                '"' => string = .basic,
                '\'' => string = .literal,
                else => {},
            },
        }
    }
    return text;
}

pub const TomlLexState = enum { normal, basic, literal, multiline_basic, multiline_literal };

pub fn tomlLineStartsInMultiline(state: TomlLexState) bool {
    return state == .multiline_basic or state == .multiline_literal;
}

/// TOML の1行を走査して multiline string 状態を更新する。
pub fn advanceTomlLexState(line: []const u8, state: *TomlLexState) void {
    var index: usize = 0;
    while (index < line.len) {
        const ch = line[index];
        switch (state.*) {
            .normal => switch (ch) {
                '#' => break,
                '"' => {
                    if (index + 2 < line.len and line[index + 1] == '"' and line[index + 2] == '"') {
                        state.* = .multiline_basic;
                        index += 3;
                        continue;
                    }
                    state.* = .basic;
                },
                '\'' => {
                    if (index + 2 < line.len and line[index + 1] == '\'' and line[index + 2] == '\'') {
                        state.* = .multiline_literal;
                        index += 3;
                        continue;
                    }
                    state.* = .literal;
                },
                else => {},
            },
            .basic => switch (ch) {
                '\\' => {
                    index += @min(2, line.len - index);
                    continue;
                },
                '"' => state.* = .normal,
                else => {},
            },
            .literal => if (ch == '\'') {
                state.* = .normal;
            },
            .multiline_basic => {
                if (ch == '\\') {
                    index += @min(2, line.len - index);
                    continue;
                }
                if (ch == '"' and index + 2 < line.len and line[index + 1] == '"' and line[index + 2] == '"') {
                    state.* = .normal;
                    index += 3;
                    continue;
                }
            },
            .multiline_literal => if (ch == '\'' and index + 2 < line.len and line[index + 1] == '\'' and line[index + 2] == '\'') {
                state.* = .normal;
                index += 3;
                continue;
            },
        }
        index += 1;
    }
    // TOML single-line strings cannot cross a line boundary. Invalid TOML is
    // rejected by the manifest parser; reset here to keep later scans bounded.
    if (state.* == .basic or state.* == .literal) state.* = .normal;
}

/// `"..."` 形式の quoted key の内部を TOML basic string の規則で復号
/// する。malformed または `buf` に収まらない場合は null（復号結果が
/// buf 超過なら短い比較対象とは一致し得ないため不一致扱いでよい）。
pub fn decodeBasicKey(inner: []const u8, buf: []u8) ?usize {
    var out: usize = 0;
    var index: usize = 0;
    while (index < inner.len) {
        const ch = inner[index];
        index += 1;
        if (ch != '\\') {
            if (out >= buf.len) return null;
            buf[out] = ch;
            out += 1;
            continue;
        }
        if (index >= inner.len) return null;
        const esc = inner[index];
        index += 1;
        const byte: u8 = switch (esc) {
            'b' => 0x08,
            't' => '\t',
            'n' => '\n',
            'f' => 0x0c,
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            else => {
                const digits: usize = switch (esc) {
                    'u' => 4,
                    'U' => 8,
                    else => return null,
                };
                if (index + digits > inner.len) return null;
                const codepoint = std.fmt.parseInt(u21, inner[index .. index + digits], 16) catch return null;
                index += digits;
                if (out + 4 > buf.len) return null;
                const len = std.unicode.utf8Encode(codepoint, buf[out..][0..4]) catch return null;
                out += len;
                continue;
            },
        };
        if (out >= buf.len) return null;
        buf[out] = byte;
        out += 1;
    }
    return out;
}

/// 行テキストが `[<section>]` ヘッダか判定する。`[ dependencies.path ]
/// のような空白や、`[dependencies."path"]` のようなセグメント引用は
/// TOML 上同一のテーブルなので正規化して比較する。
/// `["dependencies.path"]`（名前全体の引用）は別名テーブルなので一致
/// させない（セグメント分割で引用が崩れた場合は不一致）。
/// `[dependencies.path] # comment` のような行末コメントは除去して
/// から比較する。
pub fn headerMatches(text: []const u8, section: []const u8, buf: []u8) bool {
    const t = std.mem.trim(u8, stripTomlComment(text), " \t\r");
    if (t.len < 3 or t[0] != '[' or t[t.len - 1] != ']') return false;
    const inner = t[1 .. t.len - 1];
    var out: usize = 0;
    var it = std.mem.splitScalar(u8, inner, '.');
    var first = true;
    while (it.next()) |seg_raw| {
        const seg = std.mem.trim(u8, seg_raw, " \t");
        if (!first) {
            if (out >= buf.len) return false;
            buf[out] = '.';
            out += 1;
        }
        if (seg.len >= 2 and seg[0] == '"' and seg[seg.len - 1] == '"') {
            // basic quoted key は escape を復号して比較する
            // （`"pa\u0074h"` は `path` と同一テーブル）。
            const n = decodeBasicKey(seg[1 .. seg.len - 1], buf[out..]) orelse return false;
            if (n == 0) return false;
            out += n;
        } else if (seg.len >= 2 and seg[0] == '\'' and seg[seg.len - 1] == '\'') {
            // literal quoted key は escape なし。そのまま比較する。
            const name = seg[1 .. seg.len - 1];
            if (name.len == 0 or out + name.len > buf.len) return false;
            @memcpy(buf[out .. out + name.len], name);
            out += name.len;
        } else if (seg.len >= 1 and (seg[0] == '"' or seg[0] == '\'')) {
            return false; // 引用がドットを跨ぐ → 別名テーブル
        } else {
            if (seg.len == 0 or out + seg.len > buf.len) return false;
            @memcpy(buf[out .. out + seg.len], seg);
            out += seg.len;
        }
        first = false;
    }
    return std.mem.eql(u8, buf[0..out], section);
}

/// `[<section>]` テーブルヘッダの行開始 offset を探す。
pub fn findTableHeader(source: []const u8, section: []const u8) ?usize {
    var index: usize = 0;
    var buf: [1024]u8 = undefined;
    var state: TomlLexState = .normal;
    while (index < source.len) {
        const end = lineEnd(source, index);
        const text = source[index..end];
        if (!tomlLineStartsInMultiline(state) and headerMatches(text, section, &buf)) return index;
        advanceTomlLexState(text, &state);
        index = if (end < source.len) end + 1 else source.len;
    }
    return null;
}

/// `header_offset` 以降で次の `[` ヘッダ（または `[[`）の行開始 offset。
/// 無ければ source.len。
pub fn nextHeader(source: []const u8, header_offset: usize) usize {
    var state: TomlLexState = .normal;
    var index = header_offset;
    const first_end = lineEnd(source, index);
    advanceTomlLexState(source[index..first_end], &state);
    index = first_end;
    while (index < source.len) {
        index += 1; // '\n' を越える
        if (index >= source.len) break;
        const end = lineEnd(source, index);
        const text = std.mem.trimStart(u8, source[index..end], " \t");
        if (!tomlLineStartsInMultiline(state) and text.len > 0 and text[0] == '[') return index;
        advanceTomlLexState(source[index..end], &state);
        index = end;
    }
    return source.len;
}

/// 行テキスト内で引用符外の最初の `=`（代入演算子）の位置を返す。
/// `"foo=bar"` のような引用 key 内の `=` は区切りとみなさない。
/// basic quoted key の `\` escape と literal quoted key を考慮する。
/// 引用が閉じない場合も null（左辺として扱えない）。
pub fn assignmentOperatorIndex(text: []const u8) ?usize {
    var quote: u8 = 0;
    var escaped = false;
    for (text, 0..) |ch, index| {
        if (quote != 0) {
            if (quote == '"' and escaped) {
                escaped = false;
                continue;
            }
            if (quote == '"' and ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == quote) quote = 0;
            continue;
        }
        switch (ch) {
            '"', '\'' => quote = ch,
            '=' => return index,
            else => {},
        }
    }
    return null;
}

test "tomlEscape は quote・backslash・制御文字を逃がす" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("C:\\\\new\\\\dir", try tomlEscape(a, "C:\\new\\dir"));
    try std.testing.expectEqualStrings("say \\\"hi\\\"", try tomlEscape(a, "say \"hi\""));
    try std.testing.expectEqualStrings("a\\nb", try tomlEscape(a, "a\nb"));
    try std.testing.expectEqualStrings("plain", try tomlEscape(a, "plain"));
}
