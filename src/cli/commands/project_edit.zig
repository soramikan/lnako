//! `lnako init`/`add`/`remove` — `nako.toml` を原子的に編集する
//! コマンド。共通の失敗・フラグ・プロジェクト読込基盤は
//! `project.zig`（`shared`）を使う。

const std = @import("std");
const lnako = @import("lnako");
const shared = @import("project.zig");

const diag = lnako.package.diagnostics;
const project = lnako.package.project;
const manifest_mod = lnako.package.manifest;

const Allocator = std.mem.Allocator;

const CliError = shared.CliError;
const PrepFlags = shared.PrepFlags;
const fail = shared.fail;
const failUsage = shared.failUsage;
const flagValue = shared.flagValue;
const renderOrFail = shared.renderOrFail;
const failProject = shared.failProject;
const loadProjectOrFail = shared.loadProjectOrFail;

/// manifest 編集をプロジェクト単位で直列化する OS file lock の取得。
/// `nako.toml` の読込→候補生成→原子的置換→lock 更新を同じロック区間
/// に入れ、同時に走る add/remove/lock/update/sync/自動準備が互いの
/// 変更を上書きしないようにする。実装は `project.EditLock`。
/// 非プロジェクトなら null（`loadProjectOrFail` の診断に委ねる）。
/// `loadProjectOrFail` より前に呼ぶこと。
fn acquireEditLock(a: Allocator, io: std.Io, start_dir: []const u8, verb: []const u8, stderr: *std.Io.Writer) !?project.EditLock {
    const root = project.findRoot(a, io, start_dir) catch |err| {
        return fail(stderr, "{s}: プロジェクトルートを探索できません: {s}\n", .{ verb, @errorName(err) });
    } orelse return null;
    defer a.free(root);
    const guard = project.acquireEditLock(a, io, root) catch |err| {
        return fail(stderr, "{s}: 編集ロックを取得できません: {s}\n", .{ verb, @errorName(err) });
    };
    return guard;
}

// ---------------------------------------------------------------------------
// nako.toml の原子的編集
// ---------------------------------------------------------------------------

/// `source` の `line` 行目（1始まり）の開始 byte offset。範囲外は null。
fn lineStart(source: []const u8, line: usize) ?usize {
    var current: usize = 1;
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        if (current == line) return index;
        if (source[index] == '\n') current += 1;
    }
    return if (current == line) index else null;
}

fn lineEnd(source: []const u8, offset: usize) usize {
    var index = offset;
    while (index < source.len and source[index] != '\n') index += 1;
    return index;
}

fn isBareKey(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

fn emitKey(a: Allocator, name: []const u8) ![]const u8 {
    if (isBareKey(name)) return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "\"{s}\"", .{name});
}

/// 行末の TOML コメントを除去する。`#` が基本文字列・literal 文字列の
/// 内側にある場合はコメント開始とみなさない（`"a#b"]` のような細工
/// をヘッダとして誤認しない）。
fn stripTomlComment(text: []const u8) []const u8 {
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

const TomlLexState = enum { normal, basic, literal, multiline_basic, multiline_literal };

fn tomlLineStartsInMultiline(state: TomlLexState) bool {
    return state == .multiline_basic or state == .multiline_literal;
}

/// TOML の1行を走査して multiline string 状態を更新する。
fn advanceTomlLexState(line: []const u8, state: *TomlLexState) void {
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

/// 行テキストが `[<section>]` ヘッダか判定する。`[ dependencies.path ]
/// のような空白や、`[dependencies."path"]` のようなセグメント引用は
/// TOML 上同一のテーブルなので正規化して比較する。
/// `["dependencies.path"]`（名前全体の引用）は別名テーブルなので一致
/// させない（セグメント分割で引用が崩れた場合は不一致）。
/// `[dependencies.path] # comment` のような行末コメントは除去して
/// から比較する。
fn headerMatches(text: []const u8, section: []const u8, buf: []u8) bool {
    const t = std.mem.trim(u8, stripTomlComment(text), " \t\r");
    if (t.len < 3 or t[0] != '[' or t[t.len - 1] != ']') return false;
    const inner = t[1 .. t.len - 1];
    var out: usize = 0;
    var it = std.mem.splitScalar(u8, inner, '.');
    var first = true;
    while (it.next()) |seg_raw| {
        const seg = std.mem.trim(u8, seg_raw, " \t");
        var name = seg;
        if (seg.len >= 2 and ((seg[0] == '"' and seg[seg.len - 1] == '"') or
            (seg[0] == '\'' and seg[seg.len - 1] == '\'')))
        {
            // 引用セグメント（basic `"x"`・literal `'x'` 両方）。
            // 内部に '.' や escape が来る入力は依存セクション名に現れない
            // ため単純に剥がす。
            name = seg[1 .. seg.len - 1];
        } else if (seg.len >= 1 and (seg[0] == '"' or seg[0] == '\'')) {
            return false; // 引用がドットを跨ぐ → 別名テーブル
        }
        if (name.len == 0) return false;
        if (!first) {
            if (out >= buf.len) return false;
            buf[out] = '.';
            out += 1;
        }
        if (out + name.len > buf.len) return false;
        @memcpy(buf[out .. out + name.len], name);
        out += name.len;
        first = false;
    }
    return std.mem.eql(u8, buf[0..out], section);
}

/// `[<section>]` テーブルヘッダの行開始 offset を探す。
fn findTableHeader(source: []const u8, section: []const u8) ?usize {
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
fn nextHeader(source: []const u8, header_offset: usize) usize {
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

/// `[<section>]` 内に `key = <value>` 行を挿入した新しい source を返す。
/// テーブルが無ければ末尾へ新設する。ただし `[dependencies] path.lib = ...`
/// や文書 root の `dependencies.path.lib = ...` のような dotted key で
/// `<section>` が暗黙に定義済みの場合、`[section]` ヘッダの追加は TOML
/// table 再定義になるため、互換の dotted 代入として挿入する。
fn insertEntry(a: Allocator, source: []const u8, section: []const u8, name: []const u8, value: []const u8) ![]const u8 {
    const key = try emitKey(a, name);
    const line = try std.fmt.allocPrint(a, "{s} = {s}\n", .{ key, value });
    if (findTableHeader(source, section)) |header| {
        // テーブル末尾（次のヘッダ直前）へ挿入する。
        const boundary = nextHeader(source, header);
        var output: std.ArrayList(u8) = .empty;
        try output.appendSlice(a, source[0..boundary]);
        // 末尾の空白行をまとめてから追記する。
        while (output.items.len > 0 and (output.items[output.items.len - 1] == '\n' or output.items[output.items.len - 1] == ' ' or output.items[output.items.len - 1] == '\t' or output.items[output.items.len - 1] == '\r')) {
            _ = output.pop();
        }
        try output.append(a, '\n');
        try output.appendSlice(a, line);
        try output.append(a, '\n');
        try output.appendSlice(a, source[boundary..]);
        return output.items;
    }
    if (try insertDottedEntry(a, source, section, key, value)) |inserted| return inserted;
    if (try insertInlineEntry(a, source, section, key, value)) |inserted| return inserted;
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(a, source);
    while (output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
        _ = output.pop();
    }
    try output.appendSlice(a, try std.fmt.allocPrint(a, "\n\n[{s}]\n{s}", .{ section, line }));
    return output.items;
}

/// `dependencies = { path = { lib = { path = "lib" } } }` のような
/// 文書 root の inline table 形式で `<parent>` が宣言済みの場合、
/// inline table の内側へ `<key> = <value>` を追記する。inline table
/// は自足宣言のため `[<section>]` ヘッダの追加は table 再定義になる。
/// 見つからなければ null。
fn insertInlineEntry(a: Allocator, source: []const u8, section: []const u8, key: []const u8, value: []const u8) !?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, section, '.') orelse return null;
    const parent = section[0..dot];
    const kind = section[dot + 1 ..];

    // 文書 root（最初の `[` ヘッダより前）で `<parent> = {` を探す。
    var index: usize = 0;
    var state: TomlLexState = .normal;
    while (index < source.len) {
        const end = lineEnd(source, index);
        const text = std.mem.trimStart(u8, source[index..end], " \t");
        if (!tomlLineStartsInMultiline(state) and text.len > 0 and text[0] == '[') break;
        if (!tomlLineStartsInMultiline(state)) {
            if (assignmentLhs(source[index..end])) |lhs| {
                if (tomlKeySegmentEquals(lhs, parent)) {
                    const eq = index + (std.mem.indexOfScalar(u8, source[index..end], '=') orelse unreachable);
                    var value_start = eq + 1;
                    while (value_start < end and (source[value_start] == ' ' or source[value_start] == '\t')) value_start += 1;
                    // `<parent>` が inline table でなければ編集対象外
                    // （scalar 宣言は `[section]` 追加と両立しない）。
                    if (value_start >= end or source[value_start] != '{') return null;
                    const close = inlineTableClose(source, value_start, end) orelse return null;
                    if (findInlineKindOpen(source, value_start, close, kind)) |kind_open| {
                        const kind_close = inlineTableClose(source, kind_open, end) orelse return null;
                        const entry = try std.fmt.allocPrint(a, "{s} = {s}", .{ key, value });
                        return try spliceInlineTableEntry(a, source, kind_open, kind_close, entry);
                    }
                    const entry = try std.fmt.allocPrint(a, "{s} = {{ {s} = {s} }}", .{ kind, key, value });
                    return try spliceInlineTableEntry(a, source, value_start, close, entry);
                }
            }
        }
        advanceTomlLexState(source[index..end], &state);
        index = if (end < source.len) end + 1 else source.len;
    }
    return null;
}

/// `source[open]` の `{` に対応する `}` の位置を返す。basic/literal
/// string 内の brace は無視する。`limit`（行末）までに閉じなければ
/// null（TOML の inline table は単一行に限定される）。
fn inlineTableClose(source: []const u8, open: usize, limit: usize) ?usize {
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

fn skipInlineWs(source: []const u8, index: usize, limit: usize) usize {
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
fn findInlineKindOpen(source: []const u8, open: usize, close: usize, kind: []const u8) ?usize {
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
        switch (source[index]) {
            '{' => index = (inlineTableClose(source, index, close) orelse return null) + 1,
            '[' => index = (inlineBracketClose(source, index, close) orelse return null) + 1,
            '"', '\'' => {
                const quote = source[index];
                index += 1;
                while (index < close and source[index] != quote) : (index += 1) {
                    if (quote == '"' and source[index] == '\\') index += 1;
                }
                index += 1;
            },
            else => while (index < close and source[index] != ',') : (index += 1) {},
        }
    }
    return null;
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
fn spliceInlineTableEntry(a: Allocator, source: []const u8, open: usize, close: usize, entry: []const u8) ![]const u8 {
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

/// dotted key 宣言により `<parent>.<kind>`（例: `dependencies.path`）が
/// 既に定義されている manifest へ、互換の dotted 代入を挿入する。
/// A) `[<parent>]` 表内の `kind.<x> = ...` → 同表末尾へ `kind.<key> = v`。
/// B) 文書 root の `<parent>.<kind>.<x> = ...` → 宣言群の末尾へ
///    `<parent>.<kind>.<key> = v`。どちらも無ければ null。
fn insertDottedEntry(a: Allocator, source: []const u8, section: []const u8, key: []const u8, value: []const u8) !?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, section, '.') orelse return null;
    const parent = section[0..dot];
    const kind = section[dot + 1 ..];

    // A) `[<parent>]` 表内の `kind.<x> = ...`。
    if (findTableHeader(source, parent)) |header| {
        const boundary = nextHeader(source, header);
        var state: TomlLexState = .normal;
        var index = lineEnd(source, header);
        advanceTomlLexState(source[header..index], &state);
        while (index < boundary) {
            index += 1;
            if (index >= boundary) break;
            const end = lineEnd(source, index);
            if (!tomlLineStartsInMultiline(state)) {
                if (assignmentLhs(source[index..@min(end, boundary)])) |lhs| {
                    if (lhsHasPrefix(lhs, &.{kind})) {
                        const line = try std.fmt.allocPrint(a, "{s}.{s} = {s}\n", .{ kind, key, value });
                        var output: std.ArrayList(u8) = .empty;
                        try output.appendSlice(a, source[0..boundary]);
                        while (output.items.len > 0 and (output.items[output.items.len - 1] == '\n' or output.items[output.items.len - 1] == ' ' or output.items[output.items.len - 1] == '\t' or output.items[output.items.len - 1] == '\r')) {
                            _ = output.pop();
                        }
                        try output.append(a, '\n');
                        try output.appendSlice(a, line);
                        try output.append(a, '\n');
                        try output.appendSlice(a, source[boundary..]);
                        return output.items;
                    }
                }
            }
            advanceTomlLexState(source[index..end], &state);
            index = end;
        }
        return null;
    }

    // B) 文書 root（最初の `[` ヘッダより前）の
    //    `<parent>.<kind>.<x> = ...`。最後の宣言の直後へ挿入する。
    var last_end: ?usize = null;
    var index: usize = 0;
    var state: TomlLexState = .normal;
    while (index < source.len) {
        const end = lineEnd(source, index);
        const text = std.mem.trimStart(u8, source[index..end], " \t");
        if (!tomlLineStartsInMultiline(state) and text.len > 0 and text[0] == '[') break;
        if (!tomlLineStartsInMultiline(state)) {
            if (assignmentLhs(source[index..end])) |lhs| {
                if (lhsHasPrefix(lhs, &.{ parent, kind })) last_end = end;
            }
        }
        advanceTomlLexState(source[index..end], &state);
        index = if (end < source.len) end + 1 else source.len;
    }
    if (last_end == null) return null;
    const pos = if (last_end.? < source.len) last_end.? + 1 else last_end.?;
    const line = try std.fmt.allocPrint(a, "{s}.{s}.{s} = {s}\n", .{ parent, kind, key, value });
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(a, source[0..pos]);
    try output.appendSlice(a, line);
    try output.appendSlice(a, source[pos..]);
    return output.items;
}

/// 行テキストが `lhs = ...` 形式なら左辺を返す。ヘッダ・コメント・
/// 空行は null。引用 key 内の `=` まで考慮した完全な TOML 字句解析
/// ではないが、dep 宣言の検出には十分（`lhsMatchesDecl` と同じ前提）。
fn assignmentLhs(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    if (trimmed.len == 0 or trimmed[0] == '[' or trimmed[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    const lhs = std.mem.trim(u8, trimmed[0..eq], " \t");
    if (lhs.len == 0) return null;
    return lhs;
}

/// 代入左辺が `prefix` セグメント列で始まり、さらに後続セグメントを
/// 持つ dotted key か。各セグメントの引用は剥がす。
/// `path.lib` は `&.{"path"}`、`dependencies.path.lib` は
/// `&.{"dependencies", "path"}` に一致する。
fn lhsHasPrefix(lhs: []const u8, prefix: []const []const u8) bool {
    var it = std.mem.splitScalar(u8, lhs, '.');
    var matched: usize = 0;
    var extra = false;
    while (it.next()) |seg_raw| {
        const bare = std.mem.trim(u8, std.mem.trim(u8, seg_raw, " \t"), "\"'");
        if (bare.len == 0) return false;
        if (matched < prefix.len) {
            if (!std.mem.eql(u8, bare, prefix[matched])) return false;
            matched += 1;
        } else {
            extra = true;
        }
    }
    return matched == prefix.len and extra;
}

/// `offset` から始まる代入文（`key = value`）の終端 offset を返す。
/// inline table/array が行を跨ぐ場合は brace が閉じるまで読み進める。
/// 文字列リテラル（`"`・`'`・`"""`・`'''`）と `#` コメント内の
/// bracket は数えない。
fn statementEnd(source: []const u8, offset: usize) usize {
    const StringKind = enum { none, basic, literal, multi_basic, multi_literal };
    var index = offset;
    var depth: usize = 0;
    var string: StringKind = .none;
    var in_comment = false;
    while (index < source.len) {
        const ch = source[index];
        switch (string) {
            .basic => {
                if (ch == '\\') {
                    index += 2;
                    continue;
                }
                if (ch == '"') string = .none;
            },
            .literal => if (ch == '\'') {
                string = .none;
            },
            .multi_basic => {
                if (ch == '\\') {
                    index += 2;
                    continue;
                }
                if (ch == '"' and index + 2 < source.len and
                    source[index + 1] == '"' and source[index + 2] == '"')
                {
                    string = .none;
                    index += 2;
                }
            },
            .multi_literal => if (ch == '\'' and index + 2 < source.len and
                source[index + 1] == '\'' and source[index + 2] == '\'')
            {
                string = .none;
                index += 2;
            },
            .none => {
                if (in_comment) {
                    if (ch == '\n') {
                        // コメントを閉じる改行は文の終端でもある。
                        in_comment = false;
                        if (depth == 0) return index;
                    }
                } else switch (ch) {
                    '#' => in_comment = true,
                    '"' => {
                        // `"""`（multiline basic string）を先に判定する。
                        if (index + 2 < source.len and
                            source[index + 1] == '"' and source[index + 2] == '"')
                        {
                            string = .multi_basic;
                            index += 2;
                        } else {
                            string = .basic;
                        }
                    },
                    '\'' => {
                        if (index + 2 < source.len and
                            source[index + 1] == '\'' and source[index + 2] == '\'')
                        {
                            string = .multi_literal;
                            index += 2;
                        } else {
                            string = .literal;
                        }
                    },
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        if (depth == 0) return index;
                        depth -= 1;
                    },
                    '\n' => if (depth == 0) return index,
                    else => {},
                }
            },
        }
        index += 1;
    }
    return index;
}

/// dep 宣言（単一行 `key = ...` または `[section.name]` サブテーブル）を
/// source から除去する。`position` は manifest が記録した dep value の
/// byte offset。
fn removeEntry(a: Allocator, source: []const u8, section: []const u8, name: []const u8, position: diag.Position) !?[]const u8 {
    // 1) `[<section>.<name>]` サブテーブル形式（空白・引用も正規化して照合）
    {
        const target = try std.fmt.allocPrint(a, "{s}.{s}", .{ section, name });
        if (findTableHeader(source, target)) |header| {
            const table_end = nextHeader(source, header);
            var output: std.ArrayList(u8) = .empty;
            try output.appendSlice(a, source[0..header]);
            try output.appendSlice(a, source[table_end..]);
            return output.items;
        }
    }

    // 2) 単一行 `key = ...` 形式 — position の行をそのまま除去する。
    // `[dependencies] path.lib = { ... }` のような dotted key 宣言も
    // 対象とする（manifest parser は同一の依存として読む）。
    const section_dot = std.mem.lastIndexOfScalar(u8, section, '.') orelse return null;
    const parent = section[0..section_dot];
    const kind = section[section_dot + 1 ..];
    const start = lineStart(source, position.line) orelse return null;
    const end = lineEnd(source, start);
    // 安全確認: その行に `=` とキー名が含まれること。
    const text = source[start..end];
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    const lhs = std.mem.trim(u8, text[0..eq], " \t");
    if (!lhsMatchesDecl(lhs, parent, kind, name)) return null;
    // 複数行に跨る inline table/array は閉じるまでまとめて除去する。
    const stmt_end = statementEnd(source, start);
    const remove_end = if (stmt_end < source.len) stmt_end + 1 else stmt_end;
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(a, source[0..start]);
    try output.appendSlice(a, source[remove_end..]);
    return output.items;
}

/// TOML dotted key の1 segmentを、引用形式を保ったまま比較する。
/// escape を含む basic key は誤削除を避けて不一致にする。
fn tomlKeySegmentEquals(raw: []const u8, expected: []const u8) bool {
    const segment = std.mem.trim(u8, raw, " \t");
    if (segment.len == 0) return false;
    if (segment[0] == '\"' or segment[0] == '\'') {
        if (segment.len < 2 or segment[segment.len - 1] != segment[0]) return false;
        const inner = segment[1 .. segment.len - 1];
        if (segment[0] == '\"' and std.mem.indexOfScalar(u8, inner, '\\') != null) return false;
        return std.mem.eql(u8, inner, expected);
    }
    return std.mem.eql(u8, segment, expected);
}

/// 代入文の左辺が dep 宣言 `name` を指すか。`lib = ...` の単一 key、
/// `[dependencies] path.lib = ...`、document-root の dotted key を照合する。
/// TOML の引用 segment 内にある `.` は区切りとして扱わない。
fn lhsMatchesDecl(lhs: []const u8, parent: []const u8, kind: []const u8, name: []const u8) bool {
    var segments: [3][]const u8 = undefined;
    var count: usize = 0;
    var segment_start: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    for (lhs, 0..) |ch, index| {
        if (quote != 0) {
            if (quote == '\"' and escaped) {
                escaped = false;
                continue;
            }
            if (quote == '\"' and ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '\"' or ch == '\'') {
            quote = ch;
        } else if (ch == '.') {
            if (count == segments.len) return false;
            segments[count] = lhs[segment_start..index];
            count += 1;
            segment_start = index + 1;
        }
    }
    if (quote != 0 or count == segments.len) return false;
    segments[count] = lhs[segment_start..];
    count += 1;

    if (count == 1) return tomlKeySegmentEquals(segments[0], name);
    if (count == 2) return tomlKeySegmentEquals(segments[0], kind) and
        tomlKeySegmentEquals(segments[1], name);
    return count == 3 and tomlKeySegmentEquals(segments[0], parent) and
        tomlKeySegmentEquals(segments[1], kind) and tomlKeySegmentEquals(segments[2], name);
}

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

const lib_source_template =
    \\/// <name> ライブラリのエントリポイント。
    \\/// 利用側プロジェクトは `[dependencies.path]` または registry 依存として
    \\/// このパッケージを参照する。
    \\
    \\●(値を)二倍とは
    \\  値*2で戻る
    \\ここまで
    \\
;

const lib_example_template =
    \\/// <name> の利用例。このファイルはライブラリ開発中の動作確認用で、
    \\/// 相対 path でライブラリソースを取り込む。
    \\
    \\!「../src/lib.nako3」を取り込む
    \\
    \\21を二倍して表示
    \\
;

const lib_test_template =
    \\/// <name> のテスト。
    \\
    \\!「../src/lib.nako3」を取り込む
    \\
    \\●テスト:二倍関数とは
    \\  結果は21を二倍。
    \\  結果と42がASSERT等
    \\ここまで
    \\
;

/// scaffold の親 dir（`src`/`examples`/`tests`）を no-follow で開く。
/// 既存の実 dir はそのまま使い、無ければ作成する。leaf symlink・
/// reparse point・実 file は追随せず `error.InvalidScaffoldDir` と
/// する（init は既存物を置き換えず、symlink 経由で外部へ書かない）。
fn openScaffoldDir(io: std.Io, dir: std.Io.Dir, rel: []const u8) !std.Io.Dir {
    while (true) {
        var opened = dir.openDir(io, rel, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                dir.createDirPath(io, rel) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => return create_err,
                };
                continue;
            },
            // leaf symlink・実 file は追随せず init 失敗とする。
            error.SymLinkLoop, error.NotDir => return error.InvalidScaffoldDir,
            else => return err,
        };
        const stat = opened.stat(io) catch |err| {
            opened.close(io);
            return err;
        };
        if (stat.kind == .directory) return opened;
        opened.close(io);
        return error.InvalidScaffoldDir;
    }
}

/// `sub_path` へ新規 file を排他作成して書き込む。既存・symlink・
/// reparse point には `PathAlreadyExists`/`SymLinkLoop` で失敗し、
/// 既存ファイルや symlink 先を上書きしない（`access` 検査と書込の
/// 間に置かれた symlink も `exclusive` で捕捉できる）。親 dir は
/// no-follow で開いたハンドル相対で作成し、親が symlink の場合も
/// リンク先へ書き込まない。
fn writeInitFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, contents: []const u8) !void {
    var target_dir = dir;
    var leaf = sub_path;
    var owned_dir: ?std.Io.Dir = null;
    defer if (owned_dir) |*owned| owned.close(io);
    if (std.fs.path.dirname(sub_path)) |parent| {
        owned_dir = try openScaffoldDir(io, dir, parent);
        target_dir = owned_dir.?;
        leaf = std.fs.path.basename(sub_path);
    }
    var file = try target_dir.createFile(io, leaf, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

/// `path` が存在するか。`access`（symlink 追従）ではリンク切れの
/// symlink を見逃して対象を上書きし得るため、no-follow stat で
/// symlink/reparse point そのものも「存在する」と判定する。
fn initTargetExists(io: std.Io, path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// `init` が今回の呼出しで作成した出力だけを取り消す。scaffold 途中の
/// 失敗で manifest や部分的な生成物が残ると再試行が「既に存在」で
/// 拒否されるため、作成済みの file/dir を登録して失敗時に除去する。
/// 既存の file/dir は登録しないため一切触れない。個々の削除失敗は
/// 無視する（ロールバックの失敗で元の error を隠さない）。
/// 削除は常に pinned handle 相対で行う。登録した path の中間成分が
/// rollback 前に symlink へ置換されても、絶対 path 再解決で project
/// 外の file を消さない。
const InitRollback = struct {
    io: std.Io,
    /// init 対象 dir の pinned handle（所有しない。caller が close する
    /// 前に `run` が呼ばれるよう errdefer の宣言順で制御する）。
    root_dir: std.Io.Dir = std.Io.Dir.cwd(),
    /// 今回作成した `nako.toml`。createFile 成功後に登録する。
    manifest_created: bool = false,
    /// 今回作成したプロジェクト dir の親 handle（所有する）と basename。
    /// dir が既存だった場合は null。
    new_dir_parent: ?std.Io.Dir = null,
    new_dir_name: []const u8 = "",
    /// 今回作成した scaffold file（root_dir 相対、作成順）。
    files: std.ArrayList([]const u8) = .empty,
    /// 今回作成した scaffold 親 dir（root_dir 相対、作成順）。
    dirs: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *InitRollback, a: Allocator) void {
        self.files.deinit(a);
        self.dirs.deinit(a);
        if (self.new_dir_parent) |*parent| {
            parent.close(self.io);
            self.new_dir_parent = null;
        }
    }

    /// 登録済みの生成物を作成の逆順で削除する。file は親 dir を
    /// no-follow で開いてから leaf を消し、dir は空の場合のみ消える
    /// （`deleteDir` は leaf symlink を辿らない）。
    fn run(self: *InitRollback) void {
        for (self.files.items) |rel| {
            if (std.fs.path.dirname(rel)) |parent_rel| {
                var parent = self.root_dir.openDir(self.io, parent_rel, .{ .follow_symlinks = false }) catch continue;
                defer parent.close(self.io);
                parent.deleteFile(self.io, std.fs.path.basename(rel)) catch {};
            } else {
                self.root_dir.deleteFile(self.io, rel) catch {};
            }
        }
        var i = self.dirs.items.len;
        while (i > 0) {
            i -= 1;
            self.root_dir.deleteDir(self.io, self.dirs.items[i]) catch {};
        }
        if (self.manifest_created) self.root_dir.deleteFile(self.io, project.manifest_name) catch {};
        if (self.new_dir_parent) |*parent| {
            parent.deleteDir(self.io, self.new_dir_name) catch {};
            parent.close(self.io);
            self.new_dir_parent = null;
        }
    }
};

pub fn runInit(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, stderr: *std.Io.Writer) !void {
    var lib = false;
    var name_opt: ?[]const u8 = null;
    var dir_arg: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--lib")) {
            lib = true;
        } else if (std.mem.eql(u8, argument, "--name")) {
            name_opt = try flagValue(args, &index, "init", "--name", stderr);
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return failUsage(stderr, "init: 不明なオプションです: {s}\n", .{argument});
        } else if (dir_arg == null) {
            dir_arg = argument;
        } else {
            return failUsage(stderr, "init: 不明な引数です: {s}\n", .{argument});
        }
    }

    // --name は副作用（dir 作成・manifest 書込）より先に検証する。
    if (name_opt) |n| {
        if (!manifest_mod.isPackageName(n)) {
            return failUsage(stderr, "init: パッケージ名が規則に合いません: {s}（[a-z][a-z0-9-]{{0,63}}）\n", .{n});
        }
    }
    const cwd = std.Io.Dir.cwd();
    // dir 作成より先に package 名を検証する（basename が規則外で失敗
    // した場合に空 dir を残さない）。
    const dir_abs = if (dir_arg) |dir|
        try project_abs(a, io, dir, start_dir)
    else
        try std.Io.Dir.cwd().realPathFileAlloc(io, start_dir, a);
    const name = name_opt orelse std.fs.path.basename(dir_abs);
    // パッケージ名規則を先に検証する。dir 名が規則外の場合は --name で
    // 明示してもらう。
    if (!manifest_mod.isPackageName(name)) {
        return failUsage(stderr, "init: パッケージ名が規則に合いません: {s}（[a-z][a-z0-9-]{{0,63}}。--name で指定してください）\n", .{name});
    }
    var created_dir = false;
    if (dir_arg != null) {
        const dir_existed = try initTargetExists(io, dir_abs);
        if (!dir_existed) {
            try cwd.createDirPath(io, dir_abs);
            created_dir = true;
        }
    }
    // Hold a no-follow handle to the destination root. Besides rejecting an
    // explicit root symlink/junction, all writes below are relative to this
    // handle so replacing the path after validation cannot redirect them.
    var root_dir = cwd.openDir(io, dir_abs, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.SymLinkLoop, error.NotDir => return fail(stderr, "init: {s} は symlink またはディレクトリではありません\n", .{dir_abs}),
        else => return err,
    };
    defer root_dir.close(io);
    // scaffold 作成の途中失敗で `nako.toml` や部分的な生成物が残り
    // 再試行を妨げないよう、今回作成した出力だけを追跡して失敗時に
    // 除去する。既存の file/dir は対象に含めない。削除は `root_dir` の
    // pinned handle 相対で行うため、errdefer は close より後（=先に実行）
    // に登録する。
    var rollback = InitRollback{ .io = io, .root_dir = root_dir };
    defer rollback.deinit(a);
    errdefer rollback.run();
    if (created_dir) {
        // `dir_abs` 自身の削除は親 handle 相対で行う。親をここで pin
        // しておけば、rollback までに path が置換されても作成した dir
        // 以外を消さない。
        if (std.fs.path.dirname(dir_abs)) |parent_path| {
            const maybe_parent = cwd.openDir(io, parent_path, .{ .follow_symlinks = false }) catch null;
            if (maybe_parent) |parent| {
                rollback.new_dir_parent = parent;
                rollback.new_dir_name = std.fs.path.basename(dir_abs);
            }
        }
    }
    const root_stat = try root_dir.stat(io);
    if (root_stat.kind != .directory) {
        return fail(stderr, "init: {s} は symlink またはディレクトリではありません\n", .{dir_abs});
    }
    const manifest_path = try std.fs.path.join(a, &.{ dir_abs, project.manifest_name });
    if (try initTargetExists(io, manifest_path)) {
        return fail(stderr, "init: {s} は既に存在します\n", .{manifest_path});
    }

    // --lib の生成物も事前に存在検査する。ユーザの既存ファイルを
    // 黙って上書きしない。
    const scaffold_paths = [_][]const u8{
        "src" ++ std.fs.path.sep_str ++ "lib.nako3",
        "examples" ++ std.fs.path.sep_str ++ "main.nako3",
        "tests" ++ std.fs.path.sep_str ++ "lib_test.nako3",
    };
    if (lib) {
        for (scaffold_paths) |rel| {
            const target = try std.fs.path.join(a, &.{ dir_abs, rel });
            if (try initTargetExists(io, target)) {
                return fail(stderr, "init: {s} は既に存在します（既存ファイルを上書きしません）\n", .{target});
            }
        }
    }

    const name_toml = try tomlEscape(a, name);
    var manifest_text: std.ArrayList(u8) = .empty;
    try manifest_text.appendSlice(a, try std.fmt.allocPrint(a,
        \\[package]
        \\name = "{s}"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    , .{name_toml}));
    if (lib) {
        try manifest_text.appendSlice(a, try std.fmt.allocPrint(a,
            \\
            \\[[exports]]
            \\name = "{s}"
            \\path = "src/lib.nako3"
            \\
        , .{name_toml}));
    }
    // 事前検査と書込の間に置かれた file/symlink も `exclusive` で拒否
    // する（symlink 先の外部 file を上書きしない）。
    var manifest_file = root_dir.createFile(io, project.manifest_name, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return fail(stderr, "init: {s} は既に存在します\n", .{manifest_path}),
        else => return err,
    };
    rollback.manifest_created = true;
    // Windows では open 中の file を削除できないため、ロールバックが
    // manifest を除去できるよう書込直後に閉じる。
    manifest_file.writeStreamingAll(io, manifest_text.items) catch |err| {
        manifest_file.close(io);
        return err;
    };
    manifest_file.close(io);

    if (lib) {
        const lib_source = try std.mem.replaceOwned(u8, a, lib_source_template, "<name>", name);
        const example = try std.mem.replaceOwned(u8, a, lib_example_template, "<name>", name);
        const test_source = try std.mem.replaceOwned(u8, a, lib_test_template, "<name>", name);
        for ([_][]const u8{ lib_source, example, test_source }, scaffold_paths) |contents, rel| {
            const target = try std.fs.path.join(a, &.{ dir_abs, rel });
            // writeInitFile が親 dir を新規作成する場合に備え、生成前に
            // 存在しなかった dir はロールバック対象へ登録する。既存の
            // dir は登録しないためロールバックで残る。登録は root_dir
            // 相対で行う（rollback 中の path 置換に追随しない）。
            if (std.fs.path.dirname(rel)) |parent_rel| {
                const parent_abs = try std.fs.path.join(a, &.{ dir_abs, parent_rel });
                if (!try initTargetExists(io, parent_abs)) try rollback.dirs.append(a, parent_rel);
            }
            writeInitFile(io, root_dir, rel, contents) catch |err| {
                // 実 CLI の fail は exit するため errdefer が走らない。
                // 明示的にロールバックしてから失敗を返す。
                rollback.run();
                return switch (err) {
                    error.InvalidScaffoldDir => fail(stderr, "init: {s} の親 dir は symlink またはファイルのため作成できません\n", .{target}),
                    error.PathAlreadyExists => fail(stderr, "init: {s} は既に存在します（既存ファイルを上書きしません）\n", .{target}),
                    else => err,
                };
            };
            try rollback.files.append(a, rel);
        }
    }
    try stderr.print("init: {s} にプロジェクトを作成しました\n", .{dir_abs});
    try stderr.flush();
}

fn project_abs(a: Allocator, io: std.Io, path: []const u8, base_dir: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(a, &.{path}) catch return error.FileSystem;
    }
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, base_dir, a);
    return std.fs.path.resolve(a, &.{ base, path }) catch return error.FileSystem;
}

// ---------------------------------------------------------------------------
// add / remove
// ---------------------------------------------------------------------------

const AddRequest = struct {
    name: []const u8,
    range: []const u8 = "*",
    dev: bool = false,
    kind: enum { pkg, path, git, http, npm } = .pkg,
    path: ?[]const u8 = null,
    git_url: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    dep_path: ?[]const u8 = null,
    http_url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    npm: bool = false,
    /// path 依存の `mutable`。manifest の既定は false（lock の tree hash で
    /// pin）。true は編集中の作業用依存を意味し --locked を拒否する。
    mutable: bool = false,
};

/// `name[@range]` を分解する。`@` の後ろを version range とする。
fn splitNameRange(spec: []const u8) struct { name: []const u8, range: []const u8, has_range: bool } {
    if (std.mem.indexOfScalar(u8, spec, '@')) |at| {
        if (at > 0) return .{ .name = spec[0..at], .range = spec[at + 1 ..], .has_range = true };
    }
    return .{ .name = spec, .range = "*", .has_range = false };
}

/// TOML 基本文字列の中身として安全な形へエスケープする。`"`・`\`・
/// 制御文字をエスケープシーケンスへ変換する（Windows path の `\` や
/// URL 中の `"` が manifest を壊さないようにするため）。
fn tomlEscape(a: Allocator, text: []const u8) ![]const u8 {
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

fn depValueText(a: Allocator, request: AddRequest) ![]const u8 {
    switch (request.kind) {
        // `dependencies.pkg` は table 形式が必須（version は省略不可）。
        .pkg => return std.fmt.allocPrint(a, "{{ version = \"{s}\" }}", .{try tomlEscape(a, request.range)}),
        // npm 依存は lock へ記録できないため runAdd で拒否済み。防御的に
        // エスケープ済み文字列を返しておく。
        .npm => return std.fmt.allocPrint(a, "\"{s}\"", .{try tomlEscape(a, request.range)}),
        .path => {
            const mutable_suffix: []const u8 = if (request.mutable) ", mutable = true" else "";
            return std.fmt.allocPrint(a, "{{ path = \"{s}\"{s} }}", .{ try tomlEscape(a, request.path.?), mutable_suffix });
        },
        .git => {
            var parts: std.ArrayList(u8) = .empty;
            try parts.appendSlice(a, try std.fmt.allocPrint(a, "{{ url = \"{s}\"", .{try tomlEscape(a, request.git_url.?)}));
            if (request.commit) |commit| {
                try parts.appendSlice(a, try std.fmt.allocPrint(a, ", commit = \"{s}\"", .{try tomlEscape(a, commit)}));
            }
            if (request.dep_path) |dep_path| {
                try parts.appendSlice(a, try std.fmt.allocPrint(a, ", path = \"{s}\"", .{try tomlEscape(a, dep_path)}));
            }
            try parts.appendSlice(a, " }");
            return parts.items;
        },
        .http => {
            var parts: std.ArrayList(u8) = .empty;
            try parts.appendSlice(a, try std.fmt.allocPrint(a, "{{ url = \"{s}\"", .{try tomlEscape(a, request.http_url.?)}));
            if (request.hash) |hash| {
                try parts.appendSlice(a, try std.fmt.allocPrint(a, ", hash = \"{s}\"", .{try tomlEscape(a, hash)}));
            }
            try parts.appendSlice(a, " }");
            return parts.items;
        },
    }
}

/// manifest を書き換えた後に lock まで進める共通処理。失敗時は元の
/// manifest へ復元する（不完全な変更状態を残さない契約）。
fn writeAndLock(
    a: Allocator,
    io: std.Io,
    loaded: *project.Project,
    new_source: []const u8,
    flags: *const PrepFlags,
    environ_map: ?*const std.process.Environ.Map,
    verb: []const u8,
    stderr: *std.Io.Writer,
) !project.LockOutcome {
    // 候補テキストを検証してから書く（不完全な manifest を残さない）。
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var candidate = manifest_mod.parse(a, new_source, &diagnostics) catch {
        renderOrFail(&diagnostics, stderr, loaded.manifest_path);
        return fail(stderr, "{s}: 生成した manifest が不正です\n", .{verb});
    };
    defer candidate.deinit();
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, loaded.manifest_path);
        return fail(stderr, "{s}: 生成した manifest が不正です\n", .{verb});
    }

    const original = try a.dupe(u8, loaded.manifest_bytes);
    writeAtomic(io, loaded.manifest_path, new_source) catch |err| {
        return fail(stderr, "{s}: nako.toml を書き込めません: {s}\n", .{ verb, @errorName(err) });
    };

    // manifest を再読込して lock を最新化する。失敗したら manifest を復元。
    var reloaded = project.load(a, io, loaded.root, &diagnostics) catch |err| {
        _ = restoreManifest(io, loaded.manifest_path, original);
        return failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
    };
    defer reloaded.deinit();
    var options = flags.toOptions(environ_map);
    if (flags.locked) {
        project.verifyLocked(a, io, &reloaded, &options, &diagnostics) catch |err| {
            _ = restoreManifest(io, loaded.manifest_path, original);
            return failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
        };
    }
    const outcome = project.ensureLock(a, io, &reloaded, &options, &diagnostics) catch |err| {
        _ = restoreManifest(io, loaded.manifest_path, original);
        return failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
    };
    return outcome;
}

fn restoreManifest(io: std.Io, path: []const u8, original: []const u8) bool {
    writeAtomic(io, path, original) catch return false;
    return true;
}

fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

pub fn runAdd(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stderr: *std.Io.Writer) !void {
    var request = AddRequest{ .name = "" };
    var flags = PrepFlags{};
    defer flags.deinit(a);
    var positional: ?[]const u8 = null;
    // `--path`/`--git`/`--http`/`--npm` は排他。先に指定されたフラグ名を
    // 記録して後勝ち・併用を防ぐ。
    var source_flag: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--dev")) {
            request.dev = true;
        } else if (std.mem.eql(u8, argument, "--path") or
            std.mem.eql(u8, argument, "--git") or
            std.mem.eql(u8, argument, "--http"))
        {
            if (source_flag != null) {
                return failUsage(stderr, "add: --path/--git/--http/--npm は併用・重複指定できません（{s} と {s}）\n", .{ source_flag.?, argument });
            }
            source_flag = argument;
            if (std.mem.eql(u8, argument, "--path")) {
                request.kind = .path;
                request.path = try flagValue(args, &index, "add", "--path", stderr);
            } else if (std.mem.eql(u8, argument, "--git")) {
                request.kind = .git;
                request.git_url = try flagValue(args, &index, "add", "--git", stderr);
            } else {
                request.kind = .http;
                request.http_url = try flagValue(args, &index, "add", "--http", stderr);
            }
        } else if (std.mem.eql(u8, argument, "--npm")) {
            if (source_flag != null) {
                return failUsage(stderr, "add: --path/--git/--http/--npm は併用・重複指定できません（{s} と --npm）\n", .{source_flag.?});
            }
            source_flag = "--npm";
            request.kind = .npm;
        } else if (std.mem.eql(u8, argument, "--commit")) {
            request.commit = try flagValue(args, &index, "add", "--commit", stderr);
        } else if (std.mem.eql(u8, argument, "--dep-path")) {
            request.dep_path = try flagValue(args, &index, "add", "--dep-path", stderr);
        } else if (std.mem.eql(u8, argument, "--hash")) {
            request.hash = try flagValue(args, &index, "add", "--hash", stderr);
        } else if (std.mem.eql(u8, argument, "--mutable")) {
            request.mutable = true;
        } else if (std.mem.eql(u8, argument, "--locked")) {
            flags.locked = true;
        } else if (std.mem.eql(u8, argument, "--offline")) {
            flags.offline = true;
        } else if (std.mem.eql(u8, argument, "--profile")) {
            flags.profile = try flagValue(args, &index, "add", "--profile", stderr);
        } else if (std.mem.eql(u8, argument, "--features")) {
            const spec = try flagValue(args, &index, "add", "--features", stderr);
            var it = std.mem.splitScalar(u8, spec, ',');
            while (it.next()) |feature| {
                const trimmed = std.mem.trim(u8, feature, " ");
                if (trimmed.len > 0) try flags.features.append(a, trimmed);
            }
        } else if (std.mem.eql(u8, argument, "--no-default-features")) {
            flags.no_default_features = true;
        } else if (std.mem.eql(u8, argument, "--registry")) {
            flags.registry = try flagValue(args, &index, "add", "--registry", stderr);
        } else if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            flags.cache_dir = try flagValue(args, &index, "add", "--package-cache-dir", stderr);
        } else if (std.mem.eql(u8, argument, "--allow-plaintext-http")) {
            flags.allow_plaintext_http = true;
        } else if (std.mem.eql(u8, argument, "--json")) {
            return failUsage(stderr, "add: --json は add では使えません\n", .{});
        } else if (std.mem.eql(u8, argument, "--no-sync")) {
            return failUsage(stderr, "add: --no-sync は add では使えません\n", .{});
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return failUsage(stderr, "add: 不明なオプションです: {s}\n", .{argument});
        } else if (positional == null) {
            positional = argument;
        } else {
            return failUsage(stderr, "add: 不明な引数です: {s}\n", .{argument});
        }
    }
    const spec = positional orelse return failUsage(stderr, "add: パッケージ名（または name@range）が必要です\n", .{});
    const parts = splitNameRange(spec);
    if (parts.has_range and parts.range.len == 0) {
        return failUsage(stderr, "add: @ の後ろに version range が必要です\n", .{});
    }
    if (parts.has_range and request.kind != .pkg) {
        return failUsage(stderr, "add: name@range は pkg 依存のみで使用できます（source dependency と併用できません）\n", .{});
    }
    request.name = parts.name;
    if (parts.range.len > 0) request.range = parts.range;
    if (!manifest_mod.isPackageName(request.name)) {
        return failUsage(stderr, "add: パッケージ名が規則に合いません: {s}（[a-z][a-z0-9-]{{0,63}}）\n", .{request.name});
    }
    if (flags.locked) {
        return failUsage(stderr, "add: --locked は add では使えません（manifest を変更するため lock は必ず更新されます）\n", .{});
    }
    // kind 固有オプションの組み合わせを検証する（別 kind への指定は
    // 黙って捨てず用法エラーとする）。
    if (request.commit != null and request.kind != .git) {
        return failUsage(stderr, "add: --commit は --git と併用してください\n", .{});
    }
    if (request.dep_path != null and request.kind != .git) {
        return failUsage(stderr, "add: --dep-path は --git と併用してください\n", .{});
    }
    if (request.hash != null and request.kind != .http) {
        return failUsage(stderr, "add: --hash は --http と併用してください\n", .{});
    }
    if (request.mutable and request.kind != .path) {
        return failUsage(stderr, "add: --mutable は --path と併用してください\n", .{});
    }

    switch (request.kind) {
        .npm => return fail(stderr, "add: {s} --npm は現在未対応です（npm 依存は lock に記録できません）\n", .{request.name}),
        .path => if (request.path == null or request.path.?.len == 0)
            return failUsage(stderr, "add: --path には値が必要です\n", .{}),
        .git => {
            if (request.git_url == null) return failUsage(stderr, "add: --git には値が必要です\n", .{});
            // manifest 側で url+commit が必須のため、不足は manifest 編集
            // 前に用法エラーとする。
            if (request.commit == null) return failUsage(stderr, "add: --git には --commit が必要です\n", .{});
        },
        .http => {
            if (request.http_url == null) return failUsage(stderr, "add: --http には値が必要です\n", .{});
            if (request.hash == null) return failUsage(stderr, "add: --http には --hash が必要です\n", .{});
        },
        else => {},
    }

    // manifest の読込・候補生成・置換・lock 更新を同一ロック区間に入れ、
    // 同時実行の add/remove による変更喪失を防ぐ。
    var guard = try acquireEditLock(a, io, start_dir, "add", stderr);
    defer if (guard) |*g| g.unlock();
    var loaded = try loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();

    // 既存宣言との重複は TOML の duplicate key エラーではなく、明確な
    // メッセージで失敗させる。
    var declared = loaded.manifest.dependencyAliases(a) catch return error.OutOfMemory;
    defer declared.deinit();
    if (declared.contains(request.name)) {
        return fail(stderr, "add: {s} は既に依存にあります\n", .{request.name});
    }

    const section = try std.fmt.allocPrint(a, "{s}.{s}", .{
        if (request.dev) "dev-dependencies" else "dependencies",
        switch (request.kind) {
            .pkg => "pkg",
            .path => "path",
            .git => "git",
            .http => "http",
            .npm => "npm",
        },
    });
    const value = try depValueText(a, request);
    const new_source = try insertEntry(a, loaded.manifest_bytes, section, request.name, value);
    var outcome = try writeAndLock(a, io, &loaded, new_source, &flags, environ_map, "add", stderr);
    defer outcome.deinit();
    try stderr.print("add: {s} を {s} へ追加しました\n", .{ request.name, section });
    try stderr.flush();
}

fn findDepPosition(manifest: *const manifest_mod.Manifest, name: []const u8, dev: bool) ?struct { kind: []const u8, position: diag.Position } {
    const group = if (dev) &manifest.dev_dependencies else &manifest.dependencies;
    if (group.pkg.get(name)) |dep| return .{ .kind = "pkg", .position = dep.position };
    if (group.npm.get(name)) |dep| return .{ .kind = "npm", .position = dep.position };
    if (group.path.get(name)) |dep| return .{ .kind = "path", .position = dep.position };
    if (group.git.get(name)) |dep| return .{ .kind = "git", .position = dep.position };
    if (group.http.get(name)) |dep| return .{ .kind = "http", .position = dep.position };
    return null;
}

pub fn runRemove(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stderr: *std.Io.Writer) !void {
    var dev = false;
    var flags = PrepFlags{};
    defer flags.deinit(a);
    var positional: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--dev")) {
            dev = true;
        } else if (std.mem.eql(u8, argument, "--locked")) {
            flags.locked = true;
        } else if (std.mem.eql(u8, argument, "--offline")) {
            flags.offline = true;
        } else if (std.mem.eql(u8, argument, "--profile")) {
            flags.profile = try flagValue(args, &index, "remove", "--profile", stderr);
        } else if (std.mem.eql(u8, argument, "--features")) {
            const spec = try flagValue(args, &index, "remove", "--features", stderr);
            var it = std.mem.splitScalar(u8, spec, ',');
            while (it.next()) |feature| {
                const trimmed = std.mem.trim(u8, feature, " ");
                if (trimmed.len > 0) try flags.features.append(a, trimmed);
            }
        } else if (std.mem.eql(u8, argument, "--no-default-features")) {
            flags.no_default_features = true;
        } else if (std.mem.eql(u8, argument, "--registry")) {
            flags.registry = try flagValue(args, &index, "remove", "--registry", stderr);
        } else if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            flags.cache_dir = try flagValue(args, &index, "remove", "--package-cache-dir", stderr);
        } else if (std.mem.eql(u8, argument, "--allow-plaintext-http")) {
            flags.allow_plaintext_http = true;
        } else if (std.mem.eql(u8, argument, "--json")) {
            return failUsage(stderr, "remove: --json は remove では使えません\n", .{});
        } else if (std.mem.eql(u8, argument, "--no-sync")) {
            return failUsage(stderr, "remove: --no-sync は remove では使えません\n", .{});
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return failUsage(stderr, "remove: 不明なオプションです: {s}\n", .{argument});
        } else if (positional == null) {
            positional = argument;
        } else {
            return failUsage(stderr, "remove: 不明な引数です: {s}\n", .{argument});
        }
    }
    const name = positional orelse return failUsage(stderr, "remove: パッケージ名が必要です\n", .{});
    if (flags.locked) {
        return failUsage(stderr, "remove: --locked は remove では使えません（manifest を変更するため lock は必ず更新されます）\n", .{});
    }

    var guard = try acquireEditLock(a, io, start_dir, "remove", stderr);
    defer if (guard) |*g| g.unlock();
    var loaded = try loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();

    // dev 未指定なら両方のグループを探す。
    var found = findDepPosition(&loaded.manifest, name, dev);
    var actual_dev = dev;
    if (found == null and !dev) {
        found = findDepPosition(&loaded.manifest, name, true);
        actual_dev = true;
    }
    const dep = found orelse return fail(stderr, "remove: {s} は依存にありません\n", .{name});

    const section = try std.fmt.allocPrint(a, "{s}.{s}", .{
        if (actual_dev) "dev-dependencies" else "dependencies",
        dep.kind,
    });
    const new_source = (try removeEntry(a, loaded.manifest_bytes, section, name, dep.position)) orelse
        return fail(stderr, "remove: nako.toml の編集位置を特定できませんでした（{s}）\n", .{name});
    var outcome = try writeAndLock(a, io, &loaded, new_source, &flags, environ_map, "remove", stderr);
    defer outcome.deinit();
    try stderr.print("remove: {s} を削除しました\n", .{name});
    try stderr.flush();
}

test "depValueText は range 無しでも table 形式を生成する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try depValueText(a, .{ .name = "somepkg", .range = "*" });
    // `dependencies.pkg` は `version` 必須の table 形式（裸文字列は不正）。
    try std.testing.expectEqualStrings("{ version = \"*\" }", text);
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

test "insertEntry は空白・引用セグメントの既存テーブルへ挿入する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `[ dependencies.path ]` のように空白を含む既存テーブルへ追記する。
    const spaced = try insertEntry(a,
        \\[package]
        \\name = "app"
        \\
        \\[ dependencies.path ]
        \\lib = { path = "lib" }
        \\
        \\[other]
        \\x = 1
        \\
    , "dependencies.path", "lib2", "{ path = \"lib2\" }");
    // 新しい [dependencies.path] を末尾に複製せず既存テーブル内へ入れる。
    try std.testing.expect(std.mem.indexOf(u8, spaced, "[other]") != null);
    const other_pos = std.mem.indexOf(u8, spaced, "[other]").?;
    const new_pos = std.mem.indexOf(u8, spaced, "lib2").?;
    try std.testing.expect(new_pos < other_pos);
    try std.testing.expect(std.mem.indexOf(u8, spaced, "[dependencies.path]") == null);

    // セグメント引用 `[dependencies."path"]` も同一テーブルとして認識する。
    const quoted = try insertEntry(a,
        \\[package]
        \\name = "app"
        \\
        \\[dependencies."path"]
        \\lib = { path = "lib" }
        \\
    , "dependencies.path", "lib2", "{ path = \"lib2\" }");
    try std.testing.expect(std.mem.indexOf(u8, quoted, "lib2") != null);

    // literal 引用 `[dependencies.'path']` も TOML 上は同一テーブル。
    // 正規化しないと add が重複テーブルを追記して manifest を壊す。
    const literal = try insertEntry(a,
        \\[package]
        \\name = "app"
        \\
        \\[dependencies.'path']
        \\lib = { path = "lib" }
        \\
    , "dependencies.path", "lib2", "{ path = \"lib2\" }");
    try std.testing.expect(std.mem.indexOf(u8, literal, "lib2") != null);
    try std.testing.expect(std.mem.indexOf(u8, literal, "[dependencies.path]") == null);
    // 引用を含む既存テーブル内に挿入される（重複ヘッダを追加しない）。
    const lit_lib_pos = std.mem.indexOf(u8, literal, "lib =").?;
    const lit_lib2_pos = std.mem.indexOf(u8, literal, "lib2").?;
    try std.testing.expect(lit_lib_pos < lit_lib2_pos);
}

test "insertEntry は multiline string内の偽headerを依存tableと誤認しない" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[package]
        \\name = "app"
        \\description = """
        \\[dependencies.path]
        \\説明文中のheader風テキスト
        \\"""
        \\
    ;
    const inserted = try insertEntry(a, source, "dependencies.path", "lib", "{ path = \"lib\" }");
    const opening = std.mem.indexOf(u8, inserted, "description = \"\"\"").?;
    const fake_header = std.mem.indexOf(u8, inserted[opening..], "[dependencies.path]").? + opening;
    const closing = std.mem.indexOf(u8, inserted[fake_header..], "\"\"\"").? + fake_header + 3;
    const real_header = inserted[closing..];
    try std.testing.expect(std.mem.startsWith(u8, real_header, "\n\n[dependencies.path]\nlib = { path = \"lib\" }"));
}

test "insertEntry は dotted key 宣言の既存 table を再定義しない" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `[dependencies] path.lib = ...` は `dependencies.path` 表を暗黙に
    // 定義するため、`[dependencies.path]` ヘッダの追加は TOML の table
    // 再定義になる。同じ dotted 形式 `path.lib2 = ...` として挿入する。
    const dotted = try insertEntry(a,
        \\[package]
        \\name = "app"
        \\
        \\[dependencies]
        \\path.lib = { path = "lib" }
        \\pkg.http = { version = "1" }
        \\
    , "dependencies.path", "lib2", "{ path = \"lib2\" }");
    try std.testing.expect(std.mem.indexOf(u8, dotted, "[dependencies.path]") == null);
    try std.testing.expect(std.mem.indexOf(u8, dotted, "path.lib2 = { path = \"lib2\" }") != null);
    const lib_pos = std.mem.indexOf(u8, dotted, "path.lib =").?;
    const lib2_pos = std.mem.indexOf(u8, dotted, "path.lib2 =").?;
    try std.testing.expect(lib_pos < lib2_pos);

    // 文書 root（最初の `[` ヘッダより前）の `dependencies.path.lib` も
    // 同じ table 定義。宣言群の直後へ同じ dotted 形式で挿入する。
    const rooted = try insertEntry(a,
        \\dependencies.path.lib = { path = "lib" }
        \\
        \\[package]
        \\name = "app"
        \\
        \\[profiles]
        \\default = {}
        \\
    , "dependencies.path", "lib2", "{ path = \"lib2\" }");
    try std.testing.expect(std.mem.indexOf(u8, rooted, "[dependencies.path]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rooted, "dependencies.path.lib2 = { path = \"lib2\" }") != null);
    const package_pos = std.mem.indexOf(u8, rooted, "[package]").?;
    const new_pos = std.mem.indexOf(u8, rooted, "dependencies.path.lib2").?;
    // root セクション内（[package] より前）に挿入される。
    try std.testing.expect(new_pos < package_pos);

    // `[dependencies]` があっても `path` の dotted 宣言が無ければ
    // `[dependencies.path]` ヘッダを新設する（暗黙親の再定義ではない）。
    const plain = try insertEntry(a,
        \\[package]
        \\name = "app"
        \\
        \\[dependencies]
        \\pkg.http = { version = "1" }
        \\
    , "dependencies.path", "lib2", "{ path = \"lib2\" }");
    try std.testing.expect(std.mem.indexOf(u8, plain, "[dependencies.path]") != null);
}

test "headerMatches は名前全体の引用を別テーブルとして区別する" {
    var buf: [1024]u8 = undefined;
    // `["dependencies.path"]` は `dependencies.path` という名前のテーブル
    // であり `dependencies` → `path` の入れ子ではない（一致させない）。
    try std.testing.expect(!headerMatches("[ \"dependencies.path\" ]", "dependencies.path", &buf));
    try std.testing.expect(headerMatches("[ dependencies.\"path\" ]", "dependencies.path", &buf));
    try std.testing.expect(headerMatches("[dependencies.path]", "dependencies.path", &buf));
    // literal 引用も同一テーブル。ドットを跨ぐ literal 引用は別名。
    try std.testing.expect(headerMatches("[ dependencies.'path' ]", "dependencies.path", &buf));
    try std.testing.expect(headerMatches("[dependencies.'path']", "dependencies.path", &buf));
    try std.testing.expect(headerMatches("[dev-dependencies.'pkg']", "dev-dependencies.pkg", &buf));
    try std.testing.expect(!headerMatches("['dependencies.path']", "dependencies.path", &buf));
    try std.testing.expect(!headerMatches("[dependencies.'path.x']", "dependencies.path", &buf));
    try std.testing.expect(!headerMatches("[[dependencies.path]]", "dependencies.path", &buf));
}

test "removeEntry は複数行 inline table を丸ごと除去する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[dependencies.path]
        \\lib = {
        \\  path = "lib",
        \\}
        \\lib2 = { path = "lib2" }
        \\
    ;
    const removed = (try removeEntry(a, source, "dependencies.path", "lib", .{ .line = 2 })).?;
    try std.testing.expect(std.mem.indexOf(u8, removed, "lib = ") == null);
    // `}` や `lib2` の行が残らないこと。
    try std.testing.expect(std.mem.indexOf(u8, removed, "lib2") != null);
}

test "removeEntry は引用key内のドットを区切りと誤認しない" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[dependencies.path]
        \\"foo.bar" = { path = "foo-bar" }
        \\other = { path = "other" }
        \\
    ;
    const removed = (try removeEntry(a, source, "dependencies.path", "foo.bar", .{ .line = 2 })).?;
    try std.testing.expect(std.mem.indexOf(u8, removed, "foo.bar") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "other") != null);
}

test "removeEntry は dotted key 宣言も除去する" {
    // `[dependencies] path.lib = { ... }` は `[dependencies.path]` 表と
    // 同じ宣言。remove が単一行形式しか消せないと宣言が残るため、
    // 先頭セグメントが dep kind・末尾が dep 名の dotted key も除去対象。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[dependencies]
        \\path.lib = { path = "lib" }
        \\git.tool = { url = "https://example.com/t" }
        \\
    ;
    const removed = (try removeEntry(a, source, "dependencies.path", "lib", .{ .line = 2 })).?;
    try std.testing.expect(std.mem.indexOf(u8, removed, "path.lib") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "git.tool") != null);
    // kind が違う dotted key（git.lib）は path.lib の除去対象にしない。
    const other = try removeEntry(a, source, "dependencies.git", "lib", .{ .line = 2 });
    try std.testing.expect(other == null);

    // 文書 root の完全修飾 dotted 宣言も同じ依存として除去する。
    const root_source =
        \\dependencies.path.lib = { path = "lib" }
        \\dependencies.git.tool = { url = "https://example.invalid/tool" }
        \\dev-dependencies.path.lib = { path = "test-lib" }
        \\
    ;
    const root_removed = (try removeEntry(a, root_source, "dependencies.path", "lib", .{ .line = 1 })).?;
    try std.testing.expect(std.mem.indexOf(u8, root_removed, "\ndependencies.path.lib") == null);
    try std.testing.expect(std.mem.indexOf(u8, root_removed, "dependencies.git.tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, root_removed, "dev-dependencies.path.lib") != null);
    const dev_removed = (try removeEntry(a, root_source, "dev-dependencies.path", "lib", .{ .line = 3 })).?;
    try std.testing.expect(std.mem.indexOf(u8, dev_removed, "\ndev-dependencies.path.lib") == null);
    try std.testing.expect(std.mem.startsWith(u8, dev_removed, "dependencies.path.lib"));
}

test "initTargetExists は symlink も存在として検出する" {
    // `access`（symlink 追従）ではリンク切れの symlink を見逃し、init が
    // link 先を上書きし得る。no-follow stat で symlink 本体を検出する。
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.symLink(io, "missing-target", "nako.toml", .{});
    // リンク切れの symlink は realPathFileAlloc では解決できないため
    // tmpdir の実 path と連結する。
    const tmp_abs = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const link_abs = try std.fs.path.join(std.testing.allocator, &.{ tmp_abs, "nako.toml" });
    defer std.testing.allocator.free(link_abs);
    try std.testing.expect(try initTargetExists(io, link_abs));
}

test "init --lib は scaffold 失敗時に今回作成した生成物だけをロールバックする" {
    // `src` が symlink のため scaffold 作成は InvalidScaffoldDir で失敗する。
    // 途中まで作成した nako.toml が残ると再試行が「既に存在」で拒否される
    // ため、今回作成した file/dir を除去する。既存の symlink・file・dir
    // は対象に含めず残す。
    const io = std.testing.io;
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);

    // `src` を symlink、`examples` を中身付きの実 dir にして、1 件目の
    // scaffold（src/lib.nako3）は親が symlink で失敗、2 件目の
    // examples/main.nako3 まで進まない構成と既存物保護を両方検証する
    // ため、別の fixture で両パターンを試す。
    try temporary.dir.symLink(io, "elsewhere", "src", .{});
    try temporary.dir.createDirPath(io, "examples");
    try temporary.dir.writeFile(io, .{ .sub_path = "examples/keep.txt", .data = "keep" });

    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectError(error.Failed, runInit(a, io, &.{ "--lib", "--name", "testlib" }, root, &err.writer));

    // 作成した nako.toml は残さない。
    const manifest_abs = try std.fs.path.join(a, &.{ root, "nako.toml" });
    try std.testing.expect(!try initTargetExists(io, manifest_abs));
    // 既存の src symlink と examples/keep.txt は無傷で残る。
    const src_stat = try temporary.dir.statFile(io, "src", .{ .follow_symlinks = false });
    try std.testing.expect(src_stat.kind == .sym_link);
    try std.testing.expect(try initTargetExists(io, try std.fs.path.join(a, &.{ root, "examples", "keep.txt" })));

    // symlink を取り除けば再試行が成功する。
    try temporary.dir.deleteFile(io, "src");
    try runInit(a, io, &.{ "--lib", "--name", "testlib" }, root, &err.writer);
    try std.testing.expect(try initTargetExists(io, manifest_abs));
    try std.testing.expect(try initTargetExists(io, try std.fs.path.join(a, &.{ root, "src", "lib.nako3" })));
}

test "init --lib は scaffold 途中の失敗で先行 file と dir もロールバックする" {
    // `examples` が symlink のため、1 件目（src/lib.nako3）は成功してから
    // 2 件目で失敗する。先行して作成した src/lib.nako3・src dir・
    // nako.toml を全て除去し、既存の symlink は残す。
    const io = std.testing.io;
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    try temporary.dir.symLink(io, "elsewhere", "examples", .{});

    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectError(error.Failed, runInit(a, io, &.{ "--lib", "--name", "testlib" }, root, &err.writer));

    try std.testing.expect(!try initTargetExists(io, try std.fs.path.join(a, &.{ root, "nako.toml" })));
    try std.testing.expect(!try initTargetExists(io, try std.fs.path.join(a, &.{ root, "src" })));
    const examples_stat = try temporary.dir.statFile(io, "examples", .{ .follow_symlinks = false });
    try std.testing.expect(examples_stat.kind == .sym_link);
}

test "insertEntry は inline table 形式の依存表の内側へ追記する" {
    // `dependencies = { path = { lib = {...} } }` のような inline table
    // 宣言へ `[dependencies.path]` ヘッダを追加すると TOML の table 再定義
    // になるため、inline table の内側へ `key = value` を挿入する。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\dependencies = { path = { lib = { path = "lib" } } }
        \\
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    ;
    const edited = try insertEntry(a, source, "dependencies.path", "other", "{ path = \"other\" }");
    try std.testing.expect(std.mem.indexOf(u8, edited, "[dependencies.path]") == null);
    try std.testing.expect(std.mem.indexOf(u8, edited, "lib = { path = \"lib\" }, other = { path = \"other\" }") != null);
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(a, edited, &diagnostics);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expect(manifest.dependencies.path.get("other") != null);
    try std.testing.expect(manifest.dependencies.path.get("lib") != null);

    // `<parent>` inline table に `<kind>` が無い場合は kind の表ごと挿入。
    const no_kind = try insertEntry(a,
        \\dependencies = { git = { tool = { url = "https://example.com/tool.git", commit = "0123456789abcdef0123456789abcdef01234567" } } }
        \\
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    , "dependencies.path", "other", "{ path = \"other\" }");
    try std.testing.expect(std.mem.indexOf(u8, no_kind, "[dependencies.path]") == null);
    var diagnostics2 = diag.List.init(a);
    defer diagnostics2.deinit();
    var manifest2 = try manifest_mod.parse(a, no_kind, &diagnostics2);
    defer manifest2.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics2.errorCount());
    try std.testing.expect(manifest2.dependencies.path.get("other") != null);
    try std.testing.expect(manifest2.dependencies.git.get("tool") != null);

    // 空の inline table でも同じく内側へ入る。
    const edited3 = try insertEntry(a,
        \\dependencies = {}
        \\
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    , "dependencies.path", "other", "{ path = \"other\" }");
    try std.testing.expect(std.mem.indexOf(u8, edited3, "[dependencies.path]") == null);
    var diagnostics3 = diag.List.init(a);
    defer diagnostics3.deinit();
    var manifest3 = try manifest_mod.parse(a, edited3, &diagnostics3);
    defer manifest3.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics3.errorCount());
    try std.testing.expect(manifest3.dependencies.path.get("other") != null);
}

test "InitRollback は symlink 置換された親 dir を辿らず project 外を消さない" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // init 先と project 外の victim を用意する。
    try temporary.dir.createDirPath(io, "outside");
    try temporary.dir.writeFile(io, .{ .sub_path = "outside/victim.txt", .data = "keep" });
    var root = try temporary.dir.openDir(io, ".", .{ .follow_symlinks = false });
    defer root.close(io);
    // init が作成した生成物（manifest + src/lib.nako3 + src dir）を再現。
    try root.writeFile(io, .{ .sub_path = "nako.toml", .data = "[package]\n" });
    try root.createDirPath(io, "src");
    try root.writeFile(io, .{ .sub_path = "src/lib.nako3", .data = "x" });
    var rollback = InitRollback{ .io = io, .root_dir = root, .manifest_created = true };
    defer rollback.deinit(std.testing.allocator);
    try rollback.files.append(std.testing.allocator, "src/lib.nako3");
    try rollback.dirs.append(std.testing.allocator, "src");
    // rollback 前に `src` が outside への symlink へ置換された想定。
    // 絶対 path で `src/lib.nako3` を消すと outside 側まで辿って消える。
    try root.deleteTree(io, "src");
    try root.symLink(io, "../outside", "src", .{});
    rollback.run();
    try temporary.dir.access(io, "outside/victim.txt", .{});
    try std.testing.expectError(error.FileNotFound, root.access(io, "nako.toml", .{}));
    const src_stat = try root.statFile(io, "src", .{ .follow_symlinks = false });
    try std.testing.expect(src_stat.kind == .sym_link);
}
