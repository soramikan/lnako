//! `lnako init`/`add`/`remove` — `nako.toml` を原子的に編集する
//! コマンド。共通の失敗・フラグ・プロジェクト読込基盤は
//! `project.zig`（`shared`）を使う。

const std = @import("std");
const lnako = @import("lnako");
const shared = @import("project.zig");
const toml_inline = @import("toml_inline.zig");
const toml_scan = @import("toml_scan.zig");
const manifest_rollback = @import("manifest_rollback.zig");

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
const loadPinnedProjectOrFail = shared.loadPinnedProjectOrFail;
const acquireEditLock = shared.acquireProjectEditLock;

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

/// `[<section>]` 内に `key = <value>` 行を挿入した新しい source を返す。
/// テーブルが無ければ末尾へ新設する。ただし `[dependencies] path.lib = ...`
/// や文書 root の `dependencies.path.lib = ...` のような dotted key で
/// `<section>` が暗黙に定義済みの場合、`[section]` ヘッダの追加は TOML
/// table 再定義になるため、互換の dotted 代入として挿入する。
fn insertEntry(a: Allocator, source: []const u8, section: []const u8, name: []const u8, value: []const u8) ![]const u8 {
    const key = try emitKey(a, name);
    const line = try std.fmt.allocPrint(a, "{s} = {s}\n", .{ key, value });
    if (toml_scan.findTableHeader(source, section)) |header| {
        // テーブル末尾（次のヘッダ直前）へ挿入する。
        const boundary = toml_scan.nextHeader(source, header);
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
    var state: toml_scan.TomlLexState = .normal;
    while (index < source.len) {
        const end = toml_scan.lineEnd(source, index);
        const text = std.mem.trimStart(u8, source[index..end], " \t");
        if (!toml_scan.tomlLineStartsInMultiline(state) and text.len > 0 and text[0] == '[') break;
        if (!toml_scan.tomlLineStartsInMultiline(state)) {
            if (assignmentLhs(source[index..end])) |lhs| {
                if (toml_inline.tomlKeySegmentEquals(lhs, parent)) {
                    const eq = index + (toml_scan.assignmentOperatorIndex(source[index..end]) orelse unreachable);
                    var value_start = eq + 1;
                    while (value_start < end and (source[value_start] == ' ' or source[value_start] == '\t')) value_start += 1;
                    // `<parent>` が inline table でなければ編集対象外
                    // （scalar 宣言は `[section]` 追加と両立しない）。
                    if (value_start >= end or source[value_start] != '{') return null;
                    const close = toml_inline.inlineTableClose(source, value_start, end) orelse return null;
                    if (toml_inline.findInlineKindOpen(source, value_start, close, kind)) |kind_open| {
                        const kind_close = toml_inline.inlineTableClose(source, kind_open, end) orelse return null;
                        const entry = try std.fmt.allocPrint(a, "{s} = {s}", .{ key, value });
                        return try toml_inline.spliceInlineTableEntry(a, source, kind_open, kind_close, entry);
                    }
                    const entry = try std.fmt.allocPrint(a, "{s} = {{ {s} = {s} }}", .{ kind, key, value });
                    return try toml_inline.spliceInlineTableEntry(a, source, value_start, close, entry);
                }
            }
        }
        toml_scan.advanceTomlLexState(source[index..end], &state);
        index = if (end < source.len) end + 1 else source.len;
    }
    return null;
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
    if (toml_scan.findTableHeader(source, parent)) |header| {
        const boundary = toml_scan.nextHeader(source, header);
        var state: toml_scan.TomlLexState = .normal;
        var index = toml_scan.lineEnd(source, header);
        toml_scan.advanceTomlLexState(source[header..index], &state);
        while (index < boundary) {
            index += 1;
            if (index >= boundary) break;
            const end = toml_scan.lineEnd(source, index);
            if (!toml_scan.tomlLineStartsInMultiline(state)) {
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
            toml_scan.advanceTomlLexState(source[index..end], &state);
            index = end;
        }
        return null;
    }

    // B) 文書 root（最初の `[` ヘッダより前）の
    //    `<parent>.<kind>.<x> = ...`。最後の宣言の直後へ挿入する。
    var last_end: ?usize = null;
    var index: usize = 0;
    var state: toml_scan.TomlLexState = .normal;
    while (index < source.len) {
        const end = toml_scan.lineEnd(source, index);
        const text = std.mem.trimStart(u8, source[index..end], " \t");
        if (!toml_scan.tomlLineStartsInMultiline(state) and text.len > 0 and text[0] == '[') break;
        if (!toml_scan.tomlLineStartsInMultiline(state)) {
            if (assignmentLhs(source[index..end])) |lhs| {
                if (lhsHasPrefix(lhs, &.{ parent, kind })) last_end = end;
            }
        }
        toml_scan.advanceTomlLexState(source[index..end], &state);
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
    // `"foo=bar"` のような引用 key 内の `=` は区切りではない。
    const eq = toml_scan.assignmentOperatorIndex(trimmed) orelse return null;
    const lhs = std.mem.trim(u8, trimmed[0..eq], " \t");
    if (lhs.len == 0) return null;
    return lhs;
}

/// 代入左辺が `prefix` セグメント列で始まり、さらに後続セグメントを
/// 持つ dotted key か。prefix の比較は引用・escape を意味上の文字列へ
/// 正規化して行う（`"pa\u0074h".lib` は `&.{"path"}` に一致）。
/// `path.lib` は `&.{"path"}`、`dependencies.path.lib` は
/// `&.{"dependencies", "path"}` に一致する。
fn lhsHasPrefix(lhs: []const u8, prefix: []const []const u8) bool {
    var rest = lhs;
    var matched: usize = 0;
    var extra = false;
    while (rest.len > 0) {
        // 引用 segment 内の `.` は区切りにしない（lhsMatchesDecl と同じ
        // 走査）。`"pa.th".lib` は1 segment `"pa.th"` として扱う。
        const step = toml_scan.nextKeySegment(rest) orelse return false;
        const seg = std.mem.trim(u8, step.segment, " \t");
        if (seg.len == 0) return false;
        if (matched < prefix.len) {
            // `"pa\u0074h"` のような basic quoted key は escape を復号
            // して比較する（toml_inline.tomlKeySegmentEquals と同じ基準）。
            if (!toml_inline.tomlKeySegmentEquals(step.segment, prefix[matched])) return false;
            matched += 1;
        } else {
            extra = true;
        }
        rest = step.rest;
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
    const section_dot = std.mem.lastIndexOfScalar(u8, section, '.') orelse return null;
    const parent = section[0..section_dot];
    const kind = section[section_dot + 1 ..];

    // 1) `[<section>.<name>]` サブテーブル形式（空白・引用も正規化して照合）。
    // `name` 自体に `.` を含む宣言（`[dependencies.path."foo.bar"]`）は
    // 結合文字列では4 segment の別テーブルと区別が付かないため、
    // segment 列 `{parent, kind, name}` で照合する。
    {
        if (toml_scan.findTableHeaderSegments(source, &.{ parent, kind, name })) |header| {
            const table_end = toml_scan.nextHeader(source, header);
            var output: std.ArrayList(u8) = .empty;
            try output.appendSlice(a, source[0..header]);
            try output.appendSlice(a, source[table_end..]);
            return output.items;
        }
    }

    // 2) 単一行 `key = ...` 形式 — position の行をそのまま除去する。
    // `[dependencies] path.lib = { ... }` のような dotted key 宣言も
    // 対象とする（manifest parser は同一の依存として読む）。
    const start = lineStart(source, position.line) orelse return null;
    const end = toml_scan.lineEnd(source, start);
    // 安全確認: その行に `=` とキー名が含まれること。
    const text = source[start..end];
    const eq = toml_scan.assignmentOperatorIndex(text) orelse return null;
    const lhs = std.mem.trim(u8, text[0..eq], " \t");
    if (!lhsMatchesDecl(lhs, parent, kind, name)) {
        // `dependencies = { path = { lib = ... } }` の inline table 宣言は
        // lhs が `<parent>` 自身なので行単位の除去は適用できない。内側の
        // `<kind>` table から `<name>` entry だけを取り除く。
        return try toml_inline.removeInlineEntry(a, source, parent, kind, name, start, end);
    }
    // 複数行に跨る inline table/array は閉じるまでまとめて除去する。
    const stmt_end = statementEnd(source, start);
    const remove_end = if (stmt_end < source.len) stmt_end + 1 else stmt_end;
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(a, source[0..start]);
    try output.appendSlice(a, source[remove_end..]);
    return output.items;
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

    if (count == 1) return toml_inline.tomlKeySegmentEquals(segments[0], name);
    if (count == 2) return toml_inline.tomlKeySegmentEquals(segments[0], kind) and
        toml_inline.tomlKeySegmentEquals(segments[1], name);
    return count == 3 and toml_inline.tomlKeySegmentEquals(segments[0], parent) and
        toml_inline.tomlKeySegmentEquals(segments[1], kind) and toml_inline.tomlKeySegmentEquals(segments[2], name);
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

fn depValueText(a: Allocator, request: AddRequest) ![]const u8 {
    switch (request.kind) {
        // `dependencies.pkg` は table 形式が必須（version は省略不可）。
        .pkg => return std.fmt.allocPrint(a, "{{ version = \"{s}\" }}", .{try toml_scan.tomlEscape(a, request.range)}),
        // npm 依存は lock へ記録できないため runAdd で拒否済み。防御的に
        // エスケープ済み文字列を返しておく。
        .npm => return std.fmt.allocPrint(a, "\"{s}\"", .{try toml_scan.tomlEscape(a, request.range)}),
        .path => {
            const mutable_suffix: []const u8 = if (request.mutable) ", mutable = true" else "";
            return std.fmt.allocPrint(a, "{{ path = \"{s}\"{s} }}", .{ try toml_scan.tomlEscape(a, request.path.?), mutable_suffix });
        },
        .git => {
            var parts: std.ArrayList(u8) = .empty;
            try parts.appendSlice(a, try std.fmt.allocPrint(a, "{{ url = \"{s}\"", .{try toml_scan.tomlEscape(a, request.git_url.?)}));
            if (request.commit) |commit| {
                try parts.appendSlice(a, try std.fmt.allocPrint(a, ", commit = \"{s}\"", .{try toml_scan.tomlEscape(a, commit)}));
            }
            if (request.dep_path) |dep_path| {
                try parts.appendSlice(a, try std.fmt.allocPrint(a, ", path = \"{s}\"", .{try toml_scan.tomlEscape(a, dep_path)}));
            }
            try parts.appendSlice(a, " }");
            return parts.items;
        },
        .http => {
            var parts: std.ArrayList(u8) = .empty;
            try parts.appendSlice(a, try std.fmt.allocPrint(a, "{{ url = \"{s}\"", .{try toml_scan.tomlEscape(a, request.http_url.?)}));
            if (request.hash) |hash| {
                try parts.appendSlice(a, try std.fmt.allocPrint(a, ", hash = \"{s}\"", .{try toml_scan.tomlEscape(a, hash)}));
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
    manifest_rollback.writeAtomic(io, loaded.root_dir, new_source) catch |err| {
        return fail(stderr, "{s}: nako.toml を書き込めません: {s}\n", .{ verb, @errorName(err) });
    };

    // manifest を再読込して lock を最新化する。失敗したら manifest を復元。
    // `loaded.root` を path で再解決すると途中の rename/置換で別 dir を
    // 読み得るため、pinned handle から同じ dir を開き直して読み込む。
    const reloaded_dir = loaded.root_dir.openDir(io, ".", .{ .follow_symlinks = false }) catch |err| {
        return manifest_rollback.failLockedEdit(a, io, loaded.root_dir, new_source, original, verb, err, &diagnostics, stderr, loaded.manifest_path);
    };
    var reloaded = project.loadFromDir(a, io, loaded.root, reloaded_dir, &diagnostics) catch |err| {
        return manifest_rollback.failLockedEdit(a, io, loaded.root_dir, new_source, original, verb, err, &diagnostics, stderr, loaded.manifest_path);
    };
    defer reloaded.deinit();
    var options = flags.toOptions(environ_map);
    if (flags.locked) {
        project.verifyLocked(a, io, &reloaded, &options, &diagnostics) catch |err| {
            return manifest_rollback.failLockedEdit(a, io, loaded.root_dir, new_source, original, verb, err, &diagnostics, stderr, loaded.manifest_path);
        };
    }
    const outcome = project.ensureLock(a, io, &reloaded, &options, &diagnostics) catch |err| {
        return manifest_rollback.failLockedEdit(a, io, loaded.root_dir, new_source, original, verb, err, &diagnostics, stderr, loaded.manifest_path);
    };
    return outcome;
}

pub fn runAdd(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stderr: *std.Io.Writer) !void {
    var request = AddRequest{ .name = "" };
    var flags = PrepFlags{};
    defer flags.deinit(a);
    var positional: ?[]const u8 = null;
    // `--path`/`--git`/`--http`/`--npm` は排他。先に指定されたフラグ名を
    // 記録して後勝ち・併用を防ぐ。
    var source_flag: ?[]const u8 = null;
    // `--` 以降は `-` 始まりでも全て位置引数（ハイフン始まりの依存キー
    // は schema 上有効なため `add --path lib -- -local` で渡せるようにする）。
    var options_ended = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (options_ended) {
            if (positional == null) {
                positional = argument;
            } else {
                return failUsage(stderr, "add: 不明な引数です: {s}\n", .{argument});
            }
            continue;
        }
        if (std.mem.eql(u8, argument, "--")) {
            options_ended = true;
            continue;
        }
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
    var locked = try acquireEditLock(a, io, start_dir, "add", stderr);
    defer if (locked) |*l| l.deinit(a, io);
    var loaded = if (locked) |*l|
        try loadPinnedProjectOrFail(a, io, l, stderr)
    else
        try loadProjectOrFail(a, io, start_dir, stderr);
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

/// `findDepPosition` の結果。`key` は TOML 上の宣言キー（`name` が
/// alias の場合は解決済みの宣言キー）で、`removeEntry` はこの key で
/// 該当行・テーブルを特定する。
const DepFound = struct { kind: []const u8, key: []const u8, position: diag.Position };

/// `name` に対応する依存を探す。まず宣言キーそのものとして検索し、
/// 見つからなければ `alias` フィールドを走査して宣言キーへ解決する
/// （`lib = { ..., alias = "req" }` の宣言を `remove req` で除去できる
/// ようにする）。npm/path 依存は alias を持たない。
fn findDepPosition(manifest: *const manifest_mod.Manifest, name: []const u8, dev: bool) ?DepFound {
    const group = if (dev) &manifest.dev_dependencies else &manifest.dependencies;
    if (group.pkg.get(name)) |dep| return .{ .kind = "pkg", .key = name, .position = dep.position };
    if (group.npm.get(name)) |dep| return .{ .kind = "npm", .key = name, .position = dep.position };
    if (group.path.get(name)) |dep| return .{ .kind = "path", .key = name, .position = dep.position };
    if (group.git.get(name)) |dep| return .{ .kind = "git", .key = name, .position = dep.position };
    if (group.http.get(name)) |dep| return .{ .kind = "http", .key = name, .position = dep.position };
    var pkg_it = group.pkg.iterator();
    while (pkg_it.next()) |entry| {
        if (entry.value_ptr.alias) |alias| {
            if (std.mem.eql(u8, alias, name)) return .{ .kind = "pkg", .key = entry.key_ptr.*, .position = entry.value_ptr.position };
        }
    }
    var git_it = group.git.iterator();
    while (git_it.next()) |entry| {
        if (entry.value_ptr.alias) |alias| {
            if (std.mem.eql(u8, alias, name)) return .{ .kind = "git", .key = entry.key_ptr.*, .position = entry.value_ptr.position };
        }
    }
    var http_it = group.http.iterator();
    while (http_it.next()) |entry| {
        if (entry.value_ptr.alias) |alias| {
            if (std.mem.eql(u8, alias, name)) return .{ .kind = "http", .key = entry.key_ptr.*, .position = entry.value_ptr.position };
        }
    }
    return null;
}

pub fn runRemove(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stderr: *std.Io.Writer) !void {
    var dev = false;
    var flags = PrepFlags{};
    defer flags.deinit(a);
    var positional: ?[]const u8 = null;
    // `--` 以降は `-` 始まりでも全て位置引数（`remove -- -local` で
    // ハイフン始まりの依存キーを削除できるようにする）。
    var options_ended = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (options_ended) {
            if (positional == null) {
                positional = argument;
            } else {
                return failUsage(stderr, "remove: 不明な引数です: {s}\n", .{argument});
            }
            continue;
        }
        if (std.mem.eql(u8, argument, "--")) {
            options_ended = true;
            continue;
        }
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

    var locked = try acquireEditLock(a, io, start_dir, "remove", stderr);
    defer if (locked) |*l| l.deinit(a, io);
    var loaded = if (locked) |*l|
        try loadPinnedProjectOrFail(a, io, l, stderr)
    else
        try loadProjectOrFail(a, io, start_dir, stderr);
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
    // `dep.key` は宣言キー（`name` が alias の場合は解決済み）。TOML の
    // 該当行・テーブルは宣言キーで特定する。
    const new_source = (try removeEntry(a, loaded.manifest_bytes, section, dep.key, dep.position)) orelse
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
    try std.testing.expect(!toml_scan.headerMatches("[ \"dependencies.path\" ]", "dependencies.path", &buf));
    try std.testing.expect(toml_scan.headerMatches("[ dependencies.\"path\" ]", "dependencies.path", &buf));
    try std.testing.expect(toml_scan.headerMatches("[dependencies.path]", "dependencies.path", &buf));
    // literal 引用も同一テーブル。ドットを跨ぐ literal 引用は別名。
    try std.testing.expect(toml_scan.headerMatches("[ dependencies.'path' ]", "dependencies.path", &buf));
    try std.testing.expect(toml_scan.headerMatches("[dependencies.'path']", "dependencies.path", &buf));
    try std.testing.expect(toml_scan.headerMatches("[dev-dependencies.'pkg']", "dev-dependencies.pkg", &buf));
    try std.testing.expect(!toml_scan.headerMatches("['dependencies.path']", "dependencies.path", &buf));
    try std.testing.expect(!toml_scan.headerMatches("[dependencies.'path.x']", "dependencies.path", &buf));
    try std.testing.expect(!toml_scan.headerMatches("[[dependencies.path]]", "dependencies.path", &buf));
}

test "headerMatches は basic 引用 key のエスケープを復号して比較する" {
    var buf: [1024]u8 = undefined;
    // `\uXXXX` は復号後に比較する（"pa\u0074h" == "path"）。
    try std.testing.expect(toml_scan.headerMatches("[dependencies.\"pa\\u0074h\"]", "dependencies.path", &buf));
    try std.testing.expect(toml_scan.headerMatches("[dependencies.\"\\u0070ath\"]", "dependencies.path", &buf));
    try std.testing.expect(toml_scan.headerMatches("[dependencies.\"pa\\U00000074h\"]", "dependencies.path", &buf));
    // 制御文字 escape も復号される（"pa\th" != "path"）。
    try std.testing.expect(!toml_scan.headerMatches("[dependencies.\"pa\\th\"]", "dependencies.path", &buf));
    // 復号しても別名なら不一致。全体引用の別名化も変わらない。
    try std.testing.expect(!toml_scan.headerMatches("[dependencies.\"pa\\u0074h.x\"]", "dependencies.path", &buf));
    try std.testing.expect(!toml_scan.headerMatches("[\"dependencies.path\"]", "dependencies.path", &buf));
    // 壊れた escape / 閉じない引用は一致とみなさない。
    try std.testing.expect(!toml_scan.headerMatches("[dependencies.\"pa\\x\"]", "dependencies.path", &buf));
    try std.testing.expect(!toml_scan.headerMatches("[dependencies.\"pa\\u0\"]", "dependencies.path", &buf));
    try std.testing.expect(!toml_scan.headerMatches("[dependencies.\"pa\\u0074h", "dependencies.path", &buf));
}

test "insertEntry はエスケープを含む引用 key の依存 table を認識する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `[dependencies."pa\u0074h"]` は `[dependencies.path]` と同一 table。
    // 復号しないと add が重複 table を追記して manifest を壊す。
    const inserted = try insertEntry(a,
        \\[package]
        \\name = "app"
        \\
        \\[dependencies."pa\u0074h"]
        \\lib = { path = "lib" }
        \\
    , "dependencies.path", "lib2", "{ path = \"lib2\" }");
    const lib_pos = std.mem.indexOf(u8, inserted, "lib =").?;
    const lib2_pos = std.mem.indexOf(u8, inserted, "lib2").?;
    try std.testing.expect(lib_pos < lib2_pos);
    try std.testing.expect(std.mem.indexOf(u8, inserted, "[dependencies.path]") == null);
}

test "insertEntry は escape を含む引用セグメントの dotted 宣言を同一 table とみなす" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `[dependencies]` 内の `"pa\u0074h".lib` は `path.lib` と同じ
    // `dependencies.path` 表を暗黙に定義する。セグメントの escape を
    // 復号しないと `[dependencies.path]` を追加して TOML の table
    // 再定義になる。
    const inserted = try insertEntry(a,
        \\[package]
        \\name = "app"
        \\
        \\[dependencies]
        \\"pa\u0074h".lib = { path = "lib" }
        \\
    , "dependencies.path", "lib2", "{ path = \"lib2\" }");
    try std.testing.expect(std.mem.indexOf(u8, inserted, "[dependencies.path]") == null);
    try std.testing.expect(std.mem.indexOf(u8, inserted, "path.lib2 = { path = \"lib2\" }") != null);

    // 文書 root の `dependencies."pa\u0074h".lib` も同じ table。
    const rooted = try insertEntry(a,
        \\dependencies."pa\u0074h".lib = { path = "lib" }
        \\
        \\[package]
        \\name = "app"
        \\
    , "dependencies.path", "lib2", "{ path = \"lib2\" }");
    try std.testing.expect(std.mem.indexOf(u8, rooted, "[dependencies.path]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rooted, "dependencies.path.lib2 = { path = \"lib2\" }") != null);
    const package_pos = std.mem.indexOf(u8, rooted, "[package]").?;
    const new_pos = std.mem.indexOf(u8, rooted, "dependencies.path.lib2").?;
    try std.testing.expect(new_pos < package_pos);

    // 復号不能な escape を含むセグメントは別 key として扱い、
    // `[dependencies.path]` を新設する（不正 TOML を同名扱いしない）。
    const malformed = try insertEntry(a,
        \\[package]
        \\name = "app"
        \\
        \\[dependencies]
        \\"pa\x".lib = { path = "lib" }
        \\
    , "dependencies.path", "lib2", "{ path = \"lib2\" }");
    try std.testing.expect(std.mem.indexOf(u8, malformed, "[dependencies.path]") != null);
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

test "removeEntry は inline table 形式の依存表から entry を除去する" {
    // `dependencies = { path = { lib = ... } }` の inline table 宣言では
    // 依存の位置が `<parent> = {` の行を指し、lhs は `dependencies`
    // 自身。行ごと消すと依存表全体が失われるため、内側の `<name>`
    // entry だけを除去する。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // kind 内の先頭 entry を除去 → 残り entry と別 kind は保持する。
    const source =
        \\dependencies = { path = { lib = { path = "lib" }, other = { path = "other" } }, git = { tool = { url = "https://example.com/tool.git", commit = "0123456789abcdef0123456789abcdef01234567" } } }
        \\
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    ;
    const removed = (try removeEntry(a, source, "dependencies.path", "lib", .{ .line = 1 })).?;
    try std.testing.expect(std.mem.indexOf(u8, removed, "lib = { path = \"lib\" }") == null);
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(a, removed, &diagnostics);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expect(manifest.dependencies.path.get("lib") == null);
    try std.testing.expect(manifest.dependencies.path.get("other") != null);
    try std.testing.expect(manifest.dependencies.git.get("tool") != null);

    // kind 内の末尾 entry を除去 → 先行 `,` ごと切って構文を保つ。
    const tail_removed = (try removeEntry(a, source, "dependencies.path", "other", .{ .line = 1 })).?;
    var diagnostics2 = diag.List.init(a);
    defer diagnostics2.deinit();
    var manifest2 = try manifest_mod.parse(a, tail_removed, &diagnostics2);
    defer manifest2.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics2.errorCount());
    try std.testing.expect(manifest2.dependencies.path.get("lib") != null);
    try std.testing.expect(manifest2.dependencies.path.get("other") == null);

    // `<kind>` の唯一の entry を消すと `<kind> = {}` を残さず pair ごと除去。
    const only_kind =
        \\dependencies = { path = { lib = { path = "lib" } }, git = { tool = { url = "https://example.com/tool.git", commit = "0123456789abcdef0123456789abcdef01234567" } } }
        \\
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    ;
    const kind_removed = (try removeEntry(a, only_kind, "dependencies.path", "lib", .{ .line = 1 })).?;
    var diagnostics3 = diag.List.init(a);
    defer diagnostics3.deinit();
    var manifest3 = try manifest_mod.parse(a, kind_removed, &diagnostics3);
    defer manifest3.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics3.errorCount());
    try std.testing.expectEqual(@as(usize, 0), manifest3.dependencies.path.count());
    try std.testing.expect(manifest3.dependencies.git.get("tool") != null);

    // `<parent>` の唯一の kind なら空の `dependencies = {}` を残さず行ごと除去。
    const only_dep =
        \\dependencies = { path = { lib = { path = "lib" } } }
        \\
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    ;
    const line_removed = (try removeEntry(a, only_dep, "dependencies.path", "lib", .{ .line = 1 })).?;
    try std.testing.expect(std.mem.indexOf(u8, line_removed, "dependencies") == null);
    var diagnostics4 = diag.List.init(a);
    defer diagnostics4.deinit();
    var manifest4 = try manifest_mod.parse(a, line_removed, &diagnostics4);
    defer manifest4.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics4.errorCount());
    try std.testing.expectEqual(@as(usize, 0), manifest4.dependencies.path.count());

    // `<parent>.<kind> = { lib = ... }` の dotted key + inline table も
    // value の top-level entry から除去する。
    const dotted_inline =
        \\dependencies.path = { lib = { path = "lib" }, other = { path = "other" } }
        \\
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    ;
    const dotted_removed = (try removeEntry(a, dotted_inline, "dependencies.path", "lib", .{ .line = 1 })).?;
    var diagnostics5 = diag.List.init(a);
    defer diagnostics5.deinit();
    var manifest5 = try manifest_mod.parse(a, dotted_removed, &diagnostics5);
    defer manifest5.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics5.errorCount());
    try std.testing.expect(manifest5.dependencies.path.get("lib") == null);
    try std.testing.expect(manifest5.dependencies.path.get("other") != null);
}

test "inline table の引用 key も escape を復号して比較する" {
    // `dependencies = { "pa\u0074h" = {...} }` の引用 key は `path` と
    // 同義。復号せず byte 比較すると add が重複 `path` pair を挿入して
    // TOML の重複 key エラーになり、remove も対象を見つけられない。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // insert: 既存の `"pa\u0074h"` table の内側へ入り `path` を重複させない。
    const source =
        \\dependencies = { "pa\u0074h" = { lib = { path = "lib" } } }
        \\
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    ;
    const edited = try insertEntry(a, source, "dependencies.path", "other", "{ path = \"other\" }");
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(a, edited, &diagnostics);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expect(manifest.dependencies.path.get("lib") != null);
    try std.testing.expect(manifest.dependencies.path.get("other") != null);

    // remove: escape 付き kind/name の entry も特定して除去できる。
    const escaped_name =
        \\dependencies = { "pa\u0074h" = { "l\u0069b" = { path = "lib" }, other = { path = "other" } } }
        \\
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    ;
    const removed = (try removeEntry(a, escaped_name, "dependencies.path", "lib", .{ .line = 1 })).?;
    var diagnostics2 = diag.List.init(a);
    defer diagnostics2.deinit();
    var manifest2 = try manifest_mod.parse(a, removed, &diagnostics2);
    defer manifest2.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics2.errorCount());
    try std.testing.expect(manifest2.dependencies.path.get("lib") == null);
    try std.testing.expect(manifest2.dependencies.path.get("other") != null);

    // dotted key + inline table の引用 segment も復号して除去する。
    const dotted_escaped =
        \\dependencies."pa\u0074h" = { lib = { path = "lib" }, other = { path = "other" } }
        \\
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    ;
    const dotted_removed = (try removeEntry(a, dotted_escaped, "dependencies.path", "lib", .{ .line = 1 })).?;
    var diagnostics3 = diag.List.init(a);
    defer diagnostics3.deinit();
    var manifest3 = try manifest_mod.parse(a, dotted_removed, &diagnostics3);
    defer manifest3.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics3.errorCount());
    try std.testing.expect(manifest3.dependencies.path.get("lib") == null);
    try std.testing.expect(manifest3.dependencies.path.get("other") != null);
}

test "removeEntry は引用 key 内の = を代入区切りと誤認しない" {
    // `"foo=bar"` の引用内 `=` は key の一部。raw の `=` 探索では
    // lhs が `"foo` へ切れて宣言として認識されず除去できない。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[dependencies.path]
        \\"foo=bar" = { path = "lib" }
        \\other = { path = "other" }
        \\
    ;
    const removed = (try removeEntry(a, source, "dependencies.path", "foo=bar", .{ .line = 2 })).?;
    try std.testing.expect(std.mem.indexOf(u8, removed, "foo=bar") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "other") != null);

    // `[dependencies]` 内の dotted 宣言 `path."foo=bar"` も同じ。
    const dotted =
        \\[dependencies]
        \\path."foo=bar" = { path = "lib" }
        \\path.other = { path = "other" }
        \\
    ;
    const removed_dotted = (try removeEntry(a, dotted, "dependencies.path", "foo=bar", .{ .line = 2 })).?;
    try std.testing.expect(std.mem.indexOf(u8, removed_dotted, "foo=bar") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed_dotted, "path.other") != null);
}

test "removeEntry は引用でドットを含む依存名のサブテーブルを除去する" {
    // `[dependencies.path."foo.bar"]` の `"foo.bar"` は引用された1
    // segment の依存名。結合文字列で照合すると4 segment の別テーブル
    // `[dependencies.path.foo.bar]` と区別が付かないため、segment 列で
    // 照合する。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[dependencies.path."foo.bar"]
        \\path = "lib"
        \\
        \\[dependencies.path.other]
        \\path = "other"
        \\
    ;
    const removed = (try removeEntry(a, source, "dependencies.path", "foo.bar", .{ .line = 1 })).?;
    try std.testing.expect(std.mem.indexOf(u8, removed, "\"foo.bar\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "other") != null);

    // escape を含む basic quoted key も復号後の名前で一致する。
    const escaped_source =
        \\[dependencies.path."foo\u002Ebar"]
        \\path = "lib"
        \\
    ;
    const removed_escaped = (try removeEntry(a, escaped_source, "dependencies.path", "foo.bar", .{ .line = 1 })).?;
    try std.testing.expect(std.mem.indexOf(u8, removed_escaped, "dependencies.path") == null);

    // 4 segment の別テーブルは引用名 `foo.bar` の照合に一致せず、
    // 引用テーブルは裸名 `bar` の照合に一致しない（相互に誤爆しない）。
    const bare_dotted =
        \\[dependencies.path.foo.bar]
        \\path = "lib"
        \\
    ;
    try std.testing.expect((try removeEntry(a, bare_dotted, "dependencies.path", "foo.bar", .{ .line = 1 })) == null);
    try std.testing.expect((try removeEntry(a, source, "dependencies.path", "bar", .{ .line = 1 })) == null);
}

test "nextKeySegment は引用 segment 内のドットを区切りにしない" {
    const first = toml_scan.nextKeySegment("\"a.b\".lib").?;
    try std.testing.expectEqualStrings("\"a.b\"", first.segment);
    try std.testing.expectEqualStrings("lib", first.rest);
    // `\` で逃げた引用符は segment を閉じない。
    const escaped = toml_scan.nextKeySegment("\"a\\\".b\".lib").?;
    try std.testing.expectEqualStrings("\"a\\\".b\"", escaped.segment);
    try std.testing.expectEqualStrings("lib", escaped.rest);
    const single = toml_scan.nextKeySegment("lib").?;
    try std.testing.expectEqualStrings("lib", single.segment);
    try std.testing.expectEqualStrings("", single.rest);
    try std.testing.expect(toml_scan.nextKeySegment("\"a.b") == null);
}

test "remove -- は以降を位置引数として扱う" {
    // `"-local"` のようなハイフン始まり dep key は schema 上有効だが、
    // `--` 無しでは `-` 始まりを option として拒否し `--` 自体も未知
    // option となるため CLI から削除できなかった。
    const io = std.testing.io;
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/nako.toml", .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\"-local" = { path = "lib" }
        \\
    });
    const root = try temporary.dir.realPathFileAlloc(io, "app", a);

    var err: std.Io.Writer.Allocating = .init(a);
    // `-` 始まりの裸引数は従来どおり option として拒否する。
    try std.testing.expectError(error.Usage, runRemove(a, io, &.{"-local"}, root, null, &err.writer));
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "不明なオプション") != null);
    // `--` 以降は位置引数なのでハイフン始まりの dep key を削除できる。
    try runRemove(a, io, &.{ "--", "-local" }, root, null, &err.writer);
    const manifest = try temporary.dir.readFileAlloc(io, "app/nako.toml", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, manifest, "-local") == null);
}

test "findDepPosition は依存 alias を宣言キーへ解決する" {
    // `lib = { ..., alias = "req" }` の宣言を `remove req` で除去
    // できるよう、宣言キーに無い名前は alias を走査して宣言キーへ
    // 解決する。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(a,
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.pkg]
        \\one = { version = "^1", alias = "shared" }
        \\
        \\[dependencies.git]
        \\lib = { url = "https://example.com/lib.git", commit = "0123456789abcdef0123456789abcdef01234567", alias = "req" }
        \\
        \\[dependencies.http]
        \\blob = { url = "https://example.com/b.tar", hash = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", alias = "data" }
        \\
    , &diagnostics);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());

    // 宣言キーで見つかる従来契約は維持する。
    const by_key = findDepPosition(&manifest, "one", false).?;
    try std.testing.expectEqualStrings("one", by_key.key);
    try std.testing.expectEqualStrings("pkg", by_key.kind);
    // alias は宣言キー・kind・宣言位置へ解決する。
    const by_alias = findDepPosition(&manifest, "shared", false).?;
    try std.testing.expectEqualStrings("one", by_alias.key);
    try std.testing.expectEqualStrings("pkg", by_alias.kind);
    const git_alias = findDepPosition(&manifest, "req", false).?;
    try std.testing.expectEqualStrings("lib", git_alias.key);
    try std.testing.expectEqualStrings("git", git_alias.kind);
    const http_alias = findDepPosition(&manifest, "data", false).?;
    try std.testing.expectEqualStrings("blob", http_alias.key);
    try std.testing.expectEqualStrings("http", http_alias.kind);
    // 宣言キー・alias のどちらにも無い名前は従来どおり null。
    try std.testing.expect(findDepPosition(&manifest, "missing", false) == null);
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
