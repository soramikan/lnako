//! TOML inline table の構造走査・編集 helper。
//! `project_edit.zig` の依存表編集（`insertEntry`/`removeEntry`）から
//! 使う純粋な字句レベルの操作で、行・section 単位の文脈は持たない。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `source[open]` の `{` に対応する `}` の位置を返す。basic/literal
/// string 内の brace は無視する。`limit`（行末）までに閉じなければ
/// null（TOML の inline table は単一行に限定される）。
pub fn inlineTableClose(source: []const u8, open: usize, limit: usize) ?usize {
    var depth: usize = 0;
    var index = open;
    while (index < limit) : (index += 1) {
        switch (source[index]) {
            '"' => {
                index += 1;
                while (index < limit and source[index] != '"') : (index += 1) {
                    if (source[index] == '\\') index += 1;
                }
            },
            '\'' => {
                index += 1;
                while (index < limit and source[index] != '\'') : (index += 1) {}
            },
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
    }
    return null;
}

pub fn skipInlineWs(source: []const u8, index: usize, limit: usize) usize {
    var i = index;
    while (i < limit and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
    return i;
}

fn skipInlineSep(source: []const u8, index: usize, limit: usize) usize {
    var i = index;
    while (i < limit and (source[i] == ' ' or source[i] == '\t' or source[i] == ',')) : (i += 1) {}
    return i;
}

/// `<parent> = {` の inline table 内（`open`/`close` 間）の top-level で
/// `kind` key を探し、その値の `{` 位置を返す。`kind` が非 table 値で
/// 宣言済み、または dotted key（`path.lib = ...`）を含む場合は inline
/// 編集を断念して null。
pub fn findInlineKindOpen(source: []const u8, open: usize, close: usize, kind: []const u8) ?usize {
    var index = open + 1;
    while (index < close) {
        index = skipInlineSep(source, index, close);
        if (index >= close) return null;
        const key_start = index;
        var key: []const u8 = undefined;
        if (source[index] == '"' or source[index] == '\'') {
            const quote = source[index];
            index += 1;
            const content_start = index;
            while (index < close and source[index] != quote) : (index += 1) {
                if (quote == '"' and source[index] == '\\') index += 1;
            }
            key = source[content_start..index];
            index += 1;
        } else {
            while (index < close and isBareKeyChar(source[index])) : (index += 1) {}
            key = source[key_start..index];
        }
        index = skipInlineWs(source, index, close);
        if (index >= close or source[index] != '=') return null;
        index += 1;
        index = skipInlineWs(source, index, close);
        if (index >= close) return null;
        if (std.mem.eql(u8, key, kind)) {
            // 値が inline table でなければ追記先を作れない。
            if (source[index] != '{') return null;
            return index;
        }
        index = skipInlineValue(source, index, close) orelse return null;
    }
    return null;
}

/// `index` に始まる inline table 内の値（table・array・string・scalar）
/// の終端を返す。scalar は次の `,` または table 終端まで（末尾空白は
/// 含めない）。閉じない構造は null。
pub fn skipInlineValue(source: []const u8, index: usize, close: usize) ?usize {
    switch (source[index]) {
        '{' => return (inlineTableClose(source, index, close) orelse return null) + 1,
        '[' => return (inlineBracketClose(source, index, close) orelse return null) + 1,
        '"', '\'' => {
            const quote = source[index];
            var i = index + 1;
            while (i < close and source[i] != quote) : (i += 1) {
                if (quote == '"' and source[i] == '\\') i += 1;
            }
            if (i >= close) return null;
            return i + 1;
        },
        else => {},
    }
    var i = index;
    while (i < close and source[i] != ',') : (i += 1) {}
    var end = i;
    while (end > index and (source[end - 1] == ' ' or source[end - 1] == '\t')) end -= 1;
    return end;
}

/// `source[open]` の `[` に対応する `]` の位置を返す（array 値の
/// skip 用）。string 内の bracket は無視する。
fn inlineBracketClose(source: []const u8, open: usize, limit: usize) ?usize {
    var depth: usize = 0;
    var index = open;
    while (index < limit) : (index += 1) {
        switch (source[index]) {
            '"' => {
                index += 1;
                while (index < limit and source[index] != '"') : (index += 1) {
                    if (source[index] == '\\') index += 1;
                }
            },
            '\'' => {
                index += 1;
                while (index < limit and source[index] != '\'') : (index += 1) {}
            },
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
    }
    return null;
}

fn isBareKeyChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
}

/// `open`/`close`（`{`/`}` の index）の inline table 末尾へ `entry` を
/// 追加した新 source を返す。
pub fn spliceInlineTableEntry(a: Allocator, source: []const u8, open: usize, close: usize, entry: []const u8) ![]const u8 {
    const inner = std.mem.trim(u8, source[open + 1 .. close], " \t");
    var tail = close;
    while (tail > open + 1 and (source[tail - 1] == ' ' or source[tail - 1] == '\t')) tail -= 1;
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(a, source[0..tail]);
    if (inner.len == 0) {
        try output.appendSlice(a, try std.fmt.allocPrint(a, " {s} ", .{entry}));
    } else {
        try output.appendSlice(a, try std.fmt.allocPrint(a, ", {s} ", .{entry}));
    }
    try output.appendSlice(a, source[close..]);
    return output.items;
}

/// inline table（`open`/`close` が `{`/`}` の位置）内 top-level の
/// `key = value` entry の範囲。escape を含む basic key は誤対応を
/// 避けて一致させない。
const InlineEntryBounds = struct {
    /// key の開始位置（先行 separator・空白の直後）。
    start: usize,
    /// value の開始位置（`=` と空白の直後）。
    value_start: usize,
    /// value の終端（末尾空白の前）。
    end: usize,
    /// 先行 `,` の位置。先頭 entry は null。
    leading_comma: ?usize,
    /// 後続 `,` の位置。TOML の inline table に末尾 comma は無いため、
    /// 末尾 entry では null。
    trailing_comma: ?usize,
};

pub fn findInlineEntry(source: []const u8, open: usize, close: usize, want: []const u8) ?InlineEntryBounds {
    var index = open + 1;
    var leading_comma: ?usize = null;
    while (index < close) {
        index = skipInlineWs(source, index, close);
        if (index >= close) return null;
        if (source[index] == ',') {
            leading_comma = index;
            index += 1;
            continue;
        }
        const start = index;
        const my_leading = leading_comma;
        leading_comma = null;
        var escaped_key = false;
        var key: []const u8 = undefined;
        if (source[index] == '"' or source[index] == '\'') {
            const quote = source[index];
            index += 1;
            const content_start = index;
            while (index < close and source[index] != quote) : (index += 1) {
                if (quote == '"' and source[index] == '\\') {
                    escaped_key = true;
                    index += 1;
                }
            }
            if (index >= close) return null;
            key = source[content_start..index];
            index += 1;
        } else {
            while (index < close and isBareKeyChar(source[index])) : (index += 1) {}
            if (index == start) return null;
            key = source[start..index];
        }
        index = skipInlineWs(source, index, close);
        if (index >= close or source[index] != '=') return null;
        index += 1;
        index = skipInlineWs(source, index, close);
        if (index >= close) return null;
        const value_start = index;
        const value_end = skipInlineValue(source, index, close) orelse return null;
        if (!escaped_key and std.mem.eql(u8, key, want)) {
            const after = skipInlineWs(source, value_end, close);
            return .{
                .start = start,
                .value_start = value_start,
                .end = value_end,
                .leading_comma = my_leading,
                .trailing_comma = if (after < close and source[after] == ',') after else null,
            };
        }
        index = value_end;
    }
    return null;
}

/// `bounds` の entry 除去に必要な切り取り範囲を返す。先頭・中間 entry
/// は後続 `,` と空白ごと、末尾 entry は先行 `,` から切る。`close` は
/// 内側 table の `}` 位置。
pub fn inlineEntryCutRange(source: []const u8, bounds: InlineEntryBounds, close: usize) struct { start: usize, end: usize } {
    if (bounds.trailing_comma) |comma|
        return .{ .start = bounds.start, .end = skipInlineWs(source, comma + 1, close) };
    if (bounds.leading_comma) |comma|
        return .{ .start = comma, .end = bounds.end };
    return .{ .start = bounds.start, .end = bounds.end };
}

/// TOML dotted key の1 segmentを、引用形式を保ったまま比較する。
/// escape を含む basic key は誤削除を避けて不一致にする。
pub fn tomlKeySegmentEquals(raw: []const u8, expected: []const u8) bool {
    const segment = std.mem.trim(u8, raw, " \t");
    if (segment.len == 0) return false;
    if (segment[0] == '"' or segment[0] == '\'') {
        if (segment.len < 2 or segment[segment.len - 1] != segment[0]) return false;
        const inner = segment[1 .. segment.len - 1];
        if (segment[0] == '"' and std.mem.indexOfScalar(u8, inner, '\\') != null) return false;
        return std.mem.eql(u8, inner, expected);
    }
    return std.mem.eql(u8, segment, expected);
}

/// 代入左辺が `<first>.<second>` のちょうど2 segment dotted key か。
/// 各 segment の引用は剥がす。引用 segment 内の `.` を区切りと誤認する
/// 簡易走査だが、誤対応は不一致（対象外）側にのみ倒れる。
fn lhsIsDottedPair(lhs: []const u8, first: []const u8, second: []const u8) bool {
    var it = std.mem.splitScalar(u8, lhs, '.');
    const a_seg = it.next() orelse return false;
    const b_seg = it.next() orelse return false;
    if (it.next() != null) return false;
    return tomlKeySegmentEquals(a_seg, first) and
        tomlKeySegmentEquals(b_seg, second);
}

/// `<parent> = { <kind> = { <name> = <value>, ... } }` の inline table
/// 宣言、または `<parent>.<kind> = { <name> = <value>, ... }` の
/// dotted key + inline table 宣言から `<name>` entry だけを除去する。
/// 除去で `<kind>` が空 table になったら `<kind> = {}` pair ごと除去し、
/// `<parent>` が空になったら代入行全体を除去する。対象が見つからなけれ
/// ば null。
pub fn removeInlineEntry(a: Allocator, source: []const u8, parent: []const u8, kind: []const u8, name: []const u8, line_start: usize, line_end: usize) !?[]const u8 {
    const text = source[line_start..line_end];
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    const lhs = std.mem.trim(u8, text[0..eq], " \t");
    var value_start = line_start + eq + 1;
    while (value_start < line_end and (source[value_start] == ' ' or source[value_start] == '\t')) value_start += 1;
    if (value_start >= line_end or source[value_start] != '{') return null;
    const close = inlineTableClose(source, value_start, line_end) orelse return null;
    var output: std.ArrayList(u8) = .empty;

    if (!tomlKeySegmentEquals(lhs, parent)) {
        // `dependencies.path = { lib = ... }` 形式。value の top-level が
        // 直接 dep entry を持つ（`<kind>` の入れ子は無い）。
        if (!lhsIsDottedPair(lhs, parent, kind)) return null;
        const name_bounds = findInlineEntry(source, value_start, close, name) orelse return null;
        if (name_bounds.leading_comma == null and name_bounds.trailing_comma == null) {
            // 唯一の entry → 空の `dependencies.path = {}` を残さず
            // 代入行全体を除去する。
            const remove_end = if (line_end < source.len) line_end + 1 else line_end;
            try output.appendSlice(a, source[0..line_start]);
            try output.appendSlice(a, source[remove_end..]);
            return output.items;
        }
        const cut = inlineEntryCutRange(source, name_bounds, close);
        try output.appendSlice(a, source[0..cut.start]);
        try output.appendSlice(a, source[cut.end..]);
        return output.items;
    }

    const kind_bounds = findInlineEntry(source, value_start, close, kind) orelse return null;
    if (source[kind_bounds.value_start] != '{') return null;
    const kind_close = inlineTableClose(source, kind_bounds.value_start, close) orelse return null;

    const name_bounds = findInlineEntry(source, kind_bounds.value_start, kind_close, name) orelse return null;
    if (name_bounds.leading_comma == null and name_bounds.trailing_comma == null) {
        // `<kind>` の唯一の entry → `<kind> = {...}` を親から除去する。
        if (kind_bounds.leading_comma == null and kind_bounds.trailing_comma == null) {
            // `<parent>` の唯一の kind → 空の `dependencies = {}` を残さず
            // 代入行全体を除去する。
            const remove_end = if (line_end < source.len) line_end + 1 else line_end;
            try output.appendSlice(a, source[0..line_start]);
            try output.appendSlice(a, source[remove_end..]);
            return output.items;
        }
        const cut = inlineEntryCutRange(source, kind_bounds, close);
        try output.appendSlice(a, source[0..cut.start]);
        try output.appendSlice(a, source[cut.end..]);
        return output.items;
    }
    const cut = inlineEntryCutRange(source, name_bounds, kind_close);
    try output.appendSlice(a, source[0..cut.start]);
    try output.appendSlice(a, source[cut.end..]);
    return output.items;
}
