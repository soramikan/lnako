//! プロジェクト依存管理コマンド（`init`/`add`/`remove`/`lock`/`update`/
//! `tree`/`why`/`check`/`cache`）と、`run`/`test`/`build` 前の自動準備。
//!
//! `nako.toml` の編集から依存解決（`nako.lock`）、`.nako` 環境の準備までを
//! 一貫した CLI として提供する。機械可読な結果（JSON）は stdout、診断は
//! stderr へ分離する。

const std = @import("std");
const lnako = @import("lnako");

const diag = lnako.package.diagnostics;
const project = lnako.package.project;
const manifest_mod = lnako.package.manifest;
const lock_model = lnako.package.lock;
const cache = lnako.package.cache;

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// 共通
// ---------------------------------------------------------------------------

/// CLI 失敗の error 集合。テスト時は process exit の代わりに error を
/// 返して異常路を検証できるようにする（本番では常に exit するため
/// 呼出し側の `return fail(...)` は到達しない）。
pub const CliError = error{ Failed, Usage };

fn fail(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) CliError {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    if (@import("builtin").is_test) return error.Failed;
    std.process.exit(1);
}

fn failUsage(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) CliError {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    if (@import("builtin").is_test) return error.Usage;
    std.process.exit(2);
}

/// `run`/`test`/`build` および lock 系コマンド共通の制御フラグ。
pub const PrepFlags = struct {
    locked: bool = false,
    offline: bool = false,
    no_sync: bool = false,
    profile: ?[]const u8 = null,
    features: std.ArrayList([]const u8) = .empty,
    no_default_features: bool = false,
    registry: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    allow_plaintext_http: bool = false,
    json: bool = false,

    pub fn deinit(self: *PrepFlags, a: Allocator) void {
        self.features.deinit(a);
    }

    fn toOptions(self: *const PrepFlags, environ_map: ?*const std.process.Environ.Map) project.PrepareOptions {
        var options = project.PrepareOptions{
            .profile = self.profile,
            .features = self.features.items,
            .no_default_features = self.no_default_features,
            .registry_url = self.registry,
            .cache_root = self.cache_dir,
        };
        options.policy.offline = self.offline;
        options.policy.allow_plaintext_http = self.allow_plaintext_http;
        if (options.registry_url == null) {
            if (environ_map) |map| {
                if (map.get("LNAKO_REGISTRY")) |url| options.registry_url = url;
            }
        }
        return options;
    }
};

/// 値を取るフラグの次の引数を値として取り出す。末尾に値が無い場合や、
/// 次の引数が別のオプション（`-` 始まり）なら用法エラーとする。
fn flagValue(args: []const []const u8, index: *usize, verb: []const u8, flag: []const u8, stderr: *std.Io.Writer) CliError![]const u8 {
    if (index.* + 1 >= args.len or std.mem.startsWith(u8, args[index.* + 1], "-")) {
        return failUsage(stderr, "{s}: {s} には値が必要です\n", .{ verb, flag });
    }
    index.* += 1;
    return args[index.*];
}

const PrepParseResult = struct { flags: PrepFlags, rest: []const []const u8 };

/// `args` から共通フラグを取り出し、残りの位置引数を返す。
/// 未知オプションは failUsage。
fn parsePrepFlags(a: Allocator, args: []const []const u8, verb: []const u8, stderr: *std.Io.Writer) (CliError || error{OutOfMemory})!PrepParseResult {
    var flags = PrepFlags{};
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--locked")) {
            flags.locked = true;
        } else if (std.mem.eql(u8, argument, "--offline")) {
            flags.offline = true;
        } else if (std.mem.eql(u8, argument, "--no-sync")) {
            flags.no_sync = true;
        } else if (std.mem.eql(u8, argument, "--profile")) {
            flags.profile = try flagValue(args, &index, verb, "--profile", stderr);
        } else if (std.mem.eql(u8, argument, "--features")) {
            const spec = try flagValue(args, &index, verb, "--features", stderr);
            var it = std.mem.splitScalar(u8, spec, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " ");
                if (trimmed.len > 0) try flags.features.append(a, trimmed);
            }
        } else if (std.mem.eql(u8, argument, "--no-default-features")) {
            flags.no_default_features = true;
        } else if (std.mem.eql(u8, argument, "--registry")) {
            flags.registry = try flagValue(args, &index, verb, "--registry", stderr);
        } else if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            flags.cache_dir = try flagValue(args, &index, verb, "--package-cache-dir", stderr);
        } else if (std.mem.eql(u8, argument, "--allow-plaintext-http")) {
            flags.allow_plaintext_http = true;
        } else if (std.mem.eql(u8, argument, "--json")) {
            flags.json = true;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return failUsage(stderr, "{s}: 不明なオプションです: {s}\n", .{ verb, argument });
        } else {
            try rest.append(a, argument);
        }
    }
    return .{ .flags = flags, .rest = rest.items };
}

/// verb ごとに意味を持つフラグの許可集合。許可外のフラグが指定された
/// 場合は黙って無視せず用法エラーとする。
const FlagMask = struct {
    locked: bool = false,
    offline: bool = false,
    no_sync: bool = false,
    profile: bool = false,
    features: bool = false,
    no_default_features: bool = false,
    registry: bool = false,
    cache_dir: bool = false,
    allow_plaintext_http: bool = false,
    json: bool = false,
};

fn rejectInertFlags(flags: *const PrepFlags, verb: []const u8, comptime allowed: FlagMask, stderr: *std.Io.Writer) CliError!void {
    const bad: ?[]const u8 = if (!allowed.locked and flags.locked)
        "--locked"
    else if (!allowed.offline and flags.offline)
        "--offline"
    else if (!allowed.no_sync and flags.no_sync)
        "--no-sync"
    else if (!allowed.profile and flags.profile != null)
        "--profile"
    else if (!allowed.features and flags.features.items.len > 0)
        "--features"
    else if (!allowed.no_default_features and flags.no_default_features)
        "--no-default-features"
    else if (!allowed.registry and flags.registry != null)
        "--registry"
    else if (!allowed.cache_dir and flags.cache_dir != null)
        "--package-cache-dir"
    else if (!allowed.allow_plaintext_http and flags.allow_plaintext_http)
        "--allow-plaintext-http"
    else if (!allowed.json and flags.json)
        "--json"
    else
        null;
    if (bad) |flag| return failUsage(stderr, "{s}: {s} はこのコマンドでは使えません\n", .{ verb, flag });
}

/// prep 系フラグを `args` から `flags` へ移し、残りの引数配列を返す。
/// 値を取るフラグは値も一緒に消費する。認識しない引数（dncl 系・位置
/// 引数・未知オプション）は残りへ保持し、呼出し側の既存検証に委ねる。
/// `run`/`test`/`build` の自動準備統合用。
/// 値を取るフラグの直後が別のオプション（`-` 始まり）なら値取りこぼし
/// とみなして用法エラーとする（`--profile --dncl` の誤消費を防ぐ）。
pub fn extractPrepFlags(a: Allocator, args: []const []const u8, flags: *PrepFlags, verb: []const u8, stderr: *std.Io.Writer) ![]const []const u8 {
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--locked")) {
            flags.locked = true;
        } else if (std.mem.eql(u8, argument, "--offline")) {
            flags.offline = true;
        } else if (std.mem.eql(u8, argument, "--no-sync")) {
            flags.no_sync = true;
        } else if (std.mem.eql(u8, argument, "--no-default-features")) {
            flags.no_default_features = true;
        } else if (std.mem.eql(u8, argument, "--allow-plaintext-http")) {
            flags.allow_plaintext_http = true;
        } else if (std.mem.eql(u8, argument, "--profile") or
            std.mem.eql(u8, argument, "--features") or
            std.mem.eql(u8, argument, "--registry") or
            std.mem.eql(u8, argument, "--package-cache-dir"))
        {
            const value = try flagValue(args, &index, verb, argument, stderr);
            if (std.mem.eql(u8, argument, "--profile")) {
                flags.profile = value;
            } else if (std.mem.eql(u8, argument, "--features")) {
                var it = std.mem.splitScalar(u8, value, ',');
                while (it.next()) |name| {
                    const trimmed = std.mem.trim(u8, name, " ");
                    if (trimmed.len > 0) try flags.features.append(a, trimmed);
                }
            } else if (std.mem.eql(u8, argument, "--registry")) {
                flags.registry = value;
            } else {
                flags.cache_dir = value;
            }
        } else {
            try rest.append(a, argument);
        }
    }
    return rest.items;
}

/// プロジェクトを `start_dir` から上方探索して読み込む。見つからない・
/// manifest が不正なら診断を出力して失敗する。
fn loadProjectOrFail(a: Allocator, io: std.Io, start_dir: []const u8, stderr: *std.Io.Writer) CliError!project.Project {
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const loaded = project.discoverAndLoad(a, io, start_dir, &diagnostics) catch |err| {
        renderOrFail(&diagnostics, stderr, start_dir);
        return fail(stderr, "nako.toml を読み込めません: {s}\n", .{@errorName(err)});
    };
    const result = loaded orelse return fail(stderr, "このディレクトリはプロジェクトではありません（nako.toml が見つかりません）\n", .{});
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, result.manifest_path);
        return error.Failed;
    }
    return result;
}

fn renderOrFail(diagnostics: *diag.List, stderr: *std.Io.Writer, source_name: []const u8) void {
    if (diagnostics.errorCount() > 0) {
        diagnostics.render(stderr, source_name) catch {};
        stderr.flush() catch {};
    }
}

fn projectErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ProjectNotFound => "プロジェクトが見つかりません",
        error.InvalidManifest => "nako.toml が不正です",
        error.InvalidLock => "nako.lock が不正または破損しています",
        error.LockedNotSatisfied => "nako.lock が不足・陳腐のため --locked を満たせません",
        error.MissingEnvironment => ".nako 環境が不足・不一致です（`lnako sync` を実行してください）",
        error.ResolveFailed => "依存解決に失敗しました",
        error.DependencyCycle => "依存が循環しています",
        error.RegistryRequired => "pkg 依存の解決に registry URL が必要です（--registry または LNAKO_REGISTRY）",
        error.UnsupportedDependency => "lock に表現できない依存形態です",
        error.UnknownProfile => "profile が見つかりません",
        error.Offline => "オフラインモードでは取得できません",
        error.NotFound => "依存を取得できません（上記の診断を参照）",
        error.InvalidSource => "依存の source が不正です（上記の診断を参照）",
        error.InvalidMetadata => "依存のメタデータが不正です（上記の診断を参照）",
        error.ProviderUnavailable => "依存の取得先へ接続できません（上記の診断を参照）",
        error.SourceCollision => "依存の source が衝突しています（上記の診断を参照）",
        error.LockNotFound => "nako.lock が見つかりません（`lnako lock` を実行してください）",
        error.LockInvalid => "nako.lock が不正です",
        error.StaleLock => "nako.lock が manifest と一致しません",
        error.Busy => "別の処理が cache/環境を使用中です",
        else => @errorName(err),
    };
}

fn failProject(stderr: *std.Io.Writer, verb: []const u8, err: anyerror, diagnostics: *diag.List, source_name: []const u8) CliError {
    renderOrFail(diagnostics, stderr, source_name);
    return fail(stderr, "{s}: {s}\n", .{ verb, projectErrorMessage(err) });
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

/// 行テキストが `[<section>]` ヘッダか判定する。`[ dependencies.path ]`
/// のような空白や、`[dependencies."path"]` のようなセグメント引用は
/// TOML 上同一のテーブルなので正規化して比較する。
/// `["dependencies.path"]`（名前全体の引用）は別名テーブルなので一致
/// させない（セグメント分割で引用が崩れた場合は不一致）。
fn headerMatches(text: []const u8, section: []const u8, buf: []u8) bool {
    const t = std.mem.trim(u8, text, " \t\r");
    if (t.len < 3 or t[0] != '[' or t[t.len - 1] != ']') return false;
    const inner = t[1 .. t.len - 1];
    var out: usize = 0;
    var it = std.mem.splitScalar(u8, inner, '.');
    var first = true;
    while (it.next()) |seg_raw| {
        const seg = std.mem.trim(u8, seg_raw, " \t");
        var name = seg;
        if (seg.len >= 2 and seg[0] == '"' and seg[seg.len - 1] == '"') {
            // 引用セグメント。内部に '.' や escape が来る入力は依存
            // セクション名に現れないため単純に剥がす。
            name = seg[1 .. seg.len - 1];
        } else if (seg.len >= 1 and seg[0] == '"') {
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
    while (index < source.len) {
        const end = lineEnd(source, index);
        const text = source[index..end];
        if (headerMatches(text, section, &buf)) return index;
        index = if (end < source.len) end + 1 else source.len;
    }
    return null;
}

/// `header_offset` 以降で次の `[` ヘッダ（または `[[`）の行開始 offset。
/// 無ければ source.len。
fn nextHeader(source: []const u8, header_offset: usize) usize {
    var index = lineEnd(source, header_offset);
    while (index < source.len) {
        index += 1; // '\n' を越える
        if (index >= source.len) break;
        const end = lineEnd(source, index);
        const text = std.mem.trimStart(u8, source[index..end], " \t");
        if (text.len > 0 and text[0] == '[') return index;
        index = end;
    }
    return source.len;
}

/// `[<section>]` 内に `key = <value>` 行を挿入した新しい source を返す。
/// テーブルが無ければ末尾へ新設する。
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
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(a, source);
    while (output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
        _ = output.pop();
    }
    try output.appendSlice(a, try std.fmt.allocPrint(a, "\n\n[{s}]\n{s}", .{ section, line }));
    return output.items;
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
        var buf: [1024]u8 = undefined;
        var index: usize = 0;
        while (index < source.len) {
            const end = lineEnd(source, index);
            const text = source[index..end];
            if (headerMatches(text, target, &buf)) {
                const table_end = nextHeader(source, index);
                var output: std.ArrayList(u8) = .empty;
                try output.appendSlice(a, source[0..index]);
                try output.appendSlice(a, source[table_end..]);
                return output.items;
            }
            index = if (end < source.len) end + 1 else source.len;
        }
    }

    // 2) 単一行 `key = ...` 形式 — position の行をそのまま除去する。
    const start = lineStart(source, position.line) orelse return null;
    const end = lineEnd(source, start);
    // 安全確認: その行に `=` とキー名が含まれること。
    const text = source[start..end];
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    const lhs = std.mem.trim(u8, text[0..eq], " \t");
    const bare = std.mem.trim(u8, lhs, "\"'");
    if (!std.mem.eql(u8, bare, name)) return null;
    // 複数行に跨る inline table/array は閉じるまでまとめて除去する。
    const stmt_end = statementEnd(source, start);
    const remove_end = if (stmt_end < source.len) stmt_end + 1 else stmt_end;
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(a, source[0..start]);
    try output.appendSlice(a, source[remove_end..]);
    return output.items;
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

fn writeInitFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = contents });
}

fn initTargetExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn runInit(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, stderr: *std.Io.Writer) !void {
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
    if (dir_arg != null) try cwd.createDirPath(io, dir_abs);
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
    try cwd.writeFile(io, .{ .sub_path = manifest_path, .data = manifest_text.items });

    if (lib) {
        const lib_source = try std.mem.replaceOwned(u8, a, lib_source_template, "<name>", name);
        const example = try std.mem.replaceOwned(u8, a, lib_example_template, "<name>", name);
        const test_source = try std.mem.replaceOwned(u8, a, lib_test_template, "<name>", name);
        try writeInitFile(io, cwd, try std.fs.path.join(a, &.{ dir_abs, scaffold_paths[0] }), lib_source);
        try writeInitFile(io, cwd, try std.fs.path.join(a, &.{ dir_abs, scaffold_paths[1] }), example);
        try writeInitFile(io, cwd, try std.fs.path.join(a, &.{ dir_abs, scaffold_paths[2] }), test_source);
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
fn splitNameRange(spec: []const u8) struct { name: []const u8, range: []const u8 } {
    if (std.mem.indexOfScalar(u8, spec, '@')) |at| {
        if (at > 0) return .{ .name = spec[0..at], .range = spec[at + 1 ..] };
    }
    return .{ .name = spec, .range = "*" };
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

fn runAdd(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stderr: *std.Io.Writer) !void {
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

fn runRemove(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stderr: *std.Io.Writer) !void {
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

// ---------------------------------------------------------------------------
// lock / update
// ---------------------------------------------------------------------------

fn runLock(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = try parsePrepFlags(a, args, "lock", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len > 0) return failUsage(stderr, "lock: 不明な引数です: {s}\n", .{parsed.rest[0]});
    // lock は環境構築を行わないため --no-sync は意味を持たない。
    try rejectInertFlags(&flags, "lock", .{
        .locked = true,
        .offline = true,
        .profile = true,
        .features = true,
        .no_default_features = true,
        .registry = true,
        .cache_dir = true,
        .allow_plaintext_http = true,
        .json = true,
    }, stderr);

    var loaded = try loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = flags.toOptions(environ_map);
    if (flags.locked) {
        project.verifyLocked(a, io, &loaded, &options, &diagnostics) catch |err| {
            return failProject(stderr, "lock", err, &diagnostics, loaded.manifest_path);
        };
    }
    var outcome = project.ensureLock(a, io, &loaded, &options, &diagnostics) catch |err| {
        return failProject(stderr, "lock", err, &diagnostics, loaded.manifest_path);
    };
    defer outcome.deinit();
    if (flags.json) {
        try stdout.print("{{\"profile\":\"{s}\",\"packages\":{d},\"wrote\":{s}}}\n", .{ outcome.profile, outcome.lock.packages.len, if (outcome.wrote) "true" else "false" });
        try stdout.flush();
    } else if (outcome.wrote) {
        try stderr.print("lock: {d} 個の package を {s} に記録しました（profile: {s}）\n", .{ outcome.lock.packages.len, project.lock_name, outcome.profile });
        try stderr.flush();
    } else {
        try stderr.print("lock: {s} は最新です（{d} 個の package, profile: {s}）\n", .{ project.lock_name, outcome.lock.packages.len, outcome.profile });
        try stderr.flush();
    }
}

fn runUpdate(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stderr: *std.Io.Writer) !void {
    const parsed = try parsePrepFlags(a, args, "update", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (flags.locked) return failUsage(stderr, "update: --locked と update は両立しません\n", .{});
    try rejectInertFlags(&flags, "update", .{
        .offline = true,
        .profile = true,
        .features = true,
        .no_default_features = true,
        .registry = true,
        .cache_dir = true,
        .allow_plaintext_http = true,
    }, stderr);

    var loaded = try loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = flags.toOptions(environ_map);
    // 対象名は manifest の宣言依存に限る。未宣言名を黙って成功させない。
    var declared = loaded.manifest.dependencyAliases(a) catch return error.OutOfMemory;
    defer declared.deinit();
    for (parsed.rest) |target| {
        if (!declared.contains(target)) {
            return fail(stderr, "update: {s} は依存にありません\n", .{target});
        }
    }
    options.update_targets = parsed.rest;
    options.update_all = parsed.rest.len == 0;
    // fresh な lock でも再解決して新版を拾うのが update の契約。
    options.force_resolve = true;
    var outcome = project.ensureLock(a, io, &loaded, &options, &diagnostics) catch |err| {
        return failProject(stderr, "update", err, &diagnostics, loaded.manifest_path);
    };
    defer outcome.deinit();
    var updated: usize = 0;
    if (outcome.report) |report| {
        for (report.changes) |change| {
            if (change.reason != .unchanged) updated += 1;
        }
    }
    try stderr.print("update: {d} 個の package を更新しました\n", .{updated});
    try stderr.flush();
}

// ---------------------------------------------------------------------------
// tree / why
// ---------------------------------------------------------------------------

/// `tree`/`why` 用の lock 取得。問い合わせコマンドは `nako.lock` を
/// 書き換えない（読み取り専用）。lock が無い・陳腐なら必要な操作を
/// 案内して失敗する。
fn lockForQuery(a: Allocator, io: std.Io, loaded: *project.Project, flags: *const PrepFlags, environ_map: ?*const std.process.Environ.Map, verb: []const u8, stderr: *std.Io.Writer) !project.LockOutcome {
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = flags.toOptions(environ_map);
    if (flags.locked) {
        project.verifyLocked(a, io, loaded, &options, &diagnostics) catch |err| {
            return failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
        };
    }
    return project.loadFreshLock(a, io, loaded, &options, &diagnostics) catch |err| {
        return failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
    };
}

fn sourceTag(entry: lock_model.PackageEntry) []const u8 {
    const source = entry.source orelse return "registry";
    return switch (source.kind) {
        .path => "path",
        .git => "git",
        .http => "http",
        else => "registry",
    };
}

/// 宣言 dep key・alias と解決済み entry id の対応表。dep key と
/// package 名が異なる（alias・同名 package）ときに宣言側の名前を
/// 表示・検索できるようにする。呼出し側が `deinit` する。
const DepKeyMaps = struct {
    /// 解決済み entry id → 宣言 dep key（tree の表示用）。
    by_id: std.StringHashMap([]const u8),
    /// dep key または alias → 解決済み entry id（why の検索用）。
    by_name: std.StringHashMap([]const u8),

    fn deinit(self: *DepKeyMaps) void {
        self.by_id.deinit();
        self.by_name.deinit();
    }
};

fn depKeyIdMap(a: Allocator, manifest: *const manifest_mod.Manifest, packages: []const lock_model.PackageEntry) !DepKeyMaps {
    var maps = DepKeyMaps{
        .by_id = std.StringHashMap([]const u8).init(a),
        .by_name = std.StringHashMap([]const u8).init(a),
    };
    errdefer maps.deinit();
    for ([_]*const manifest_mod.DependencyGroup{ &manifest.dependencies, &manifest.dev_dependencies }) |group| {
        var path_it = group.path.iterator();
        while (path_it.next()) |item| {
            const id = try project.publicIdForDepKey(a, "path", item.key_ptr.*);
            try maps.by_id.put(id, item.key_ptr.*);
            try maps.by_name.put(item.key_ptr.*, id);
        }
        var git_it = group.git.iterator();
        while (git_it.next()) |item| {
            const id = try project.publicIdForDepKey(a, "git", item.key_ptr.*);
            try maps.by_id.put(id, item.key_ptr.*);
            try maps.by_name.put(item.key_ptr.*, id);
            if (item.value_ptr.alias) |alias| try maps.by_name.put(alias, id);
        }
        var http_it = group.http.iterator();
        while (http_it.next()) |item| {
            const id = try project.publicIdForDepKey(a, "http", item.key_ptr.*);
            try maps.by_id.put(id, item.key_ptr.*);
            try maps.by_name.put(item.key_ptr.*, id);
            if (item.value_ptr.alias) |alias| try maps.by_name.put(alias, id);
        }
        var pkg_it = group.pkg.iterator();
        while (pkg_it.next()) |item| {
            // pkg 依存は public id を manifest から導出できないため、
            // 解決済み package 名（宣言名 `name`。`alias` はプログラム側の
            // 参照名で package 名ではない）で対応付ける。
            for (packages) |entry| {
                if (std.mem.eql(u8, entry.name, item.value_ptr.name)) {
                    try maps.by_id.put(entry.id, item.key_ptr.*);
                    try maps.by_name.put(item.key_ptr.*, entry.id);
                    if (item.value_ptr.alias) |alias| try maps.by_name.put(alias, entry.id);
                    break;
                }
            }
        }
    }
    return maps;
}

fn runTree(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = try parsePrepFlags(a, args, "tree", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len > 0) return failUsage(stderr, "tree: 不明な引数です: {s}\n", .{parsed.rest[0]});
    // tree は読み取り専用の問い合わせ。lock 鮮度入力と検証に関係する
    // フラグのみ受け付ける。
    try rejectInertFlags(&flags, "tree", .{
        .locked = true,
        .profile = true,
        .features = true,
        .no_default_features = true,
    }, stderr);

    var loaded = try loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var outcome = try lockForQuery(a, io, &loaded, &flags, environ_map, "tree", stderr);
    defer outcome.deinit();

    const packages = outcome.lock.packagesForProfile(outcome.profile) orelse outcome.lock.packages;
    // 被参照でない package を root として表示する（lock は全 package の
    // 和集合で、直接依存は他の依存から参照されない）。
    var referenced = std.StringHashMap(void).init(a);
    defer referenced.deinit();
    for (packages) |entry| {
        for (entry.dependencies) |dep_id| try referenced.put(dep_id, {});
    }
    var maps = try depKeyIdMap(a, &loaded.manifest, packages);
    defer maps.deinit();
    try stdout.print("{s} {f} (profile: {s})\n", .{ loaded.manifest.package.name, loaded.manifest.package.version, outcome.profile });
    var printed_any = false;
    for (packages) |entry| {
        if (referenced.contains(entry.id)) continue;
        printed_any = true;
        try printTreeNode(a, stdout, packages, entry, "", true, &.{}, maps.by_id.get(entry.id));
    }
    // 全 package が相互参照している純粋な循環では root が空になり
    // ヘッダしか出ないため、全 package を列挙して辺を表示する。
    if (!printed_any) {
        for (packages) |entry| {
            try printTreeNode(a, stdout, packages, entry, "", true, &.{}, maps.by_id.get(entry.id));
        }
    }
    try stdout.flush();
}

fn findEntry(packages: []const lock_model.PackageEntry, id: []const u8) ?lock_model.PackageEntry {
    for (packages) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

/// tree 表示の再帰深さ上限。`seen` は経路上の祖先 id なので
/// `seen.len` がそのまま深さになる。resolver 生成の graph では
/// 実際にこの深さへ達しないが、細工した lock でも stack を使い切ら
/// ないよう上限を設ける。
const max_tree_depth = 128;

fn printTreeNode(a: Allocator, stdout: *std.Io.Writer, packages: []const lock_model.PackageEntry, entry: lock_model.PackageEntry, prefix: []const u8, last: bool, seen: []const []const u8, label: ?[]const u8) !void {
    const branch = if (last) "└── " else "├── ";
    if (label != null and !std.mem.eql(u8, label.?, entry.name)) {
        // dep key（宣言名）と package 名が異なる場合は両方表示する。
        try stdout.print("{s}{s}{s} -> {s} {s} [{s}{s}]\n", .{ prefix, branch, label.?, entry.name, entry.version, sourceTag(entry), if (entry.implementation) |impl| std.fmt.allocPrint(a, ", {s}", .{impl}) catch "" else "" });
    } else {
        try stdout.print("{s}{s}{s} {s} [{s}{s}]\n", .{ prefix, branch, entry.name, entry.version, sourceTag(entry), if (entry.implementation) |impl| std.fmt.allocPrint(a, ", {s}", .{impl}) catch "" else "" });
    }
    for (seen) |id| {
        if (std.mem.eql(u8, id, entry.id)) return;
    }
    var next_seen: std.ArrayList([]const u8) = .empty;
    try next_seen.appendSlice(a, seen);
    try next_seen.append(a, entry.id);
    if (next_seen.items.len >= max_tree_depth) {
        try stdout.print("{s}    └── … (深さ上限)\n", .{prefix});
        return;
    }
    const child_prefix = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, if (last) "    " else "│   " });
    for (entry.dependencies, 0..) |dep_id, i| {
        const child = findEntry(packages, dep_id) orelse continue;
        const last_child = i == entry.dependencies.len - 1;
        // 循環辺は再帰せず (cycle) として表示する。
        var in_seen = false;
        for (next_seen.items) |id| {
            if (std.mem.eql(u8, id, dep_id)) {
                in_seen = true;
                break;
            }
        }
        if (in_seen) {
            const child_branch = if (last_child) "└── " else "├── ";
            try stdout.print("{s}{s}{s} {s} (cycle)\n", .{ child_prefix, child_branch, child.name, child.version });
            continue;
        }
        try printTreeNode(a, stdout, packages, child, child_prefix, last_child, next_seen.items, null);
    }
}

fn runWhy(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = try parsePrepFlags(a, args, "why", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len == 0) return failUsage(stderr, "why: パッケージ名が必要です\n", .{});
    if (parsed.rest.len > 1) return failUsage(stderr, "why: 不明な引数です: {s}\n", .{parsed.rest[1]});
    try rejectInertFlags(&flags, "why", .{
        .locked = true,
        .profile = true,
        .features = true,
        .no_default_features = true,
    }, stderr);
    const name = parsed.rest[0];

    var loaded = try loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var outcome = try lockForQuery(a, io, &loaded, &flags, environ_map, "why", stderr);
    defer outcome.deinit();

    const packages = outcome.lock.packagesForProfile(outcome.profile) orelse outcome.lock.packages;
    var target: ?lock_model.PackageEntry = null;
    for (packages) |entry| {
        if (std.mem.eql(u8, entry.name, name) or std.mem.eql(u8, entry.id, name)) {
            target = entry;
            break;
        }
    }
    if (target == null) {
        // 宣言 dep key や alias（プログラム側の参照名）でも引ける
        // ようにする。
        var maps = try depKeyIdMap(a, &loaded.manifest, packages);
        defer maps.deinit();
        if (maps.by_name.get(name)) |id| {
            target = findEntry(packages, id);
        }
    }
    const entry = target orelse return fail(stderr, "why: {s} は解決済み依存にありません\n", .{name});

    try stdout.print("{s} {s} [{s}{s}]\n", .{ entry.name, entry.version, sourceTag(entry), if (entry.implementation) |impl| std.fmt.allocPrint(a, ", {s}", .{impl}) catch "" else "" });
    // manifest の直接宣言かを確認する。
    const declared_section = try manifestDeclares(a, &loaded.manifest, packages, name);
    if (declared_section) |declared| {
        try stdout.print("  理由: {s}（直接宣言）\n", .{declared});
    }
    // 逆依存（この package を必要とする他 package）を列挙する。
    var found_dependent = false;
    for (packages) |parent| {
        for (parent.dependencies) |dep_id| {
            if (!std.mem.eql(u8, dep_id, entry.id)) continue;
            try stdout.print("  理由: {s} {s} の依存として導入\n", .{ parent.name, parent.version });
            found_dependent = true;
        }
    }
    if (!found_dependent and declared_section == null) {
        try stdout.print("  理由: 解決グラフに含まれます（参照元は lock に記録されていません）\n", .{});
    }
    try stdout.flush();
}

/// manifest が `name`（dep key または解決済み package 名）を直接宣言
/// しているか。宣言されていれば `dependencies.path` のような節名を返す。
/// dep key と package 名が異なる場合は `dep key` を併記する。
fn manifestDeclares(a: Allocator, manifest: *const manifest_mod.Manifest, packages: []const lock_model.PackageEntry, name: []const u8) !?[]const u8 {
    const groups = [_]struct { prefix: []const u8, group: *const manifest_mod.DependencyGroup }{
        .{ .prefix = "dependencies", .group = &manifest.dependencies },
        .{ .prefix = "dev-dependencies", .group = &manifest.dev_dependencies },
    };
    for (groups) |item| {
        const group = item.group;
        var path_it = group.path.iterator();
        while (path_it.next()) |dep| {
            if (try declaredMatch(a, packages, "path", item.prefix, dep.key_ptr.*, null, name)) |text| return text;
        }
        var git_it = group.git.iterator();
        while (git_it.next()) |dep| {
            if (try declaredMatch(a, packages, "git", item.prefix, dep.key_ptr.*, dep.value_ptr.alias, name)) |text| return text;
        }
        var http_it = group.http.iterator();
        while (http_it.next()) |dep| {
            if (try declaredMatch(a, packages, "http", item.prefix, dep.key_ptr.*, dep.value_ptr.alias, name)) |text| return text;
        }
        var pkg_it = group.pkg.iterator();
        while (pkg_it.next()) |dep| {
            // pkg の dep key は宣言 package 名そのもの。alias は
            // プログラム側の参照名なので別名として照合する。
            if (std.mem.eql(u8, dep.key_ptr.*, name)) return try std.fmt.allocPrint(a, "{s}.pkg", .{item.prefix});
            if (dep.value_ptr.alias) |alias| {
                if (std.mem.eql(u8, alias, name)) return try std.fmt.allocPrint(a, "{s}.pkg（alias: {s} → {s}）", .{ item.prefix, alias, dep.key_ptr.* });
            }
        }
        var npm_it = group.npm.iterator();
        while (npm_it.next()) |dep| {
            if (std.mem.eql(u8, dep.key_ptr.*, name)) return try std.fmt.allocPrint(a, "{s}.npm", .{item.prefix});
        }
    }
    return null;
}

/// source 系 dep（path/git/http）の dep key・alias・解決済み package 名が
/// `name` と一致するか調べ、該当すれば節名テキストを返す。
fn declaredMatch(a: Allocator, packages: []const lock_model.PackageEntry, kind: []const u8, prefix: []const u8, dep_key: []const u8, alias: ?[]const u8, name: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, dep_key, name)) return try std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, kind });
    if (alias) |al| {
        if (std.mem.eql(u8, al, name)) return try std.fmt.allocPrint(a, "{s}.{s}（alias: {s} → {s}）", .{ prefix, kind, al, dep_key });
    }
    const id = try project.publicIdForDepKey(a, kind, dep_key);
    const entry = findEntry(packages, id) orelse return null;
    if (!std.mem.eql(u8, entry.name, name)) return null;
    return try std.fmt.allocPrint(a, "{s}.{s}（dep key: {s}）", .{ prefix, kind, dep_key });
}

// ---------------------------------------------------------------------------
// check（副作用なし）
// ---------------------------------------------------------------------------

/// 既存環境が現行 lock と整合するか検査する。`.nako` を作成しない。
pub fn checkProject(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = try parsePrepFlags(a, args, "check", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len > 0) return failUsage(stderr, "check: 不明な引数です: {s}\n", .{parsed.rest[0]});
    // check は副作用なしの検査コマンド。sync・取得系フラグは意味を持た
    // ないため拒否する。
    try rejectInertFlags(&flags, "check", .{
        .locked = true,
        .profile = true,
        .features = true,
        .no_default_features = true,
        .json = true,
    }, stderr);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const found = project.discoverAndLoad(a, io, start_dir, &diagnostics) catch |err| {
        return failProject(stderr, "check", err, &diagnostics, ".");
    };
    const loaded = found orelse return fail(stderr, "check: このディレクトリはプロジェクトではありません（nako.toml が見つかりません）\n", .{});
    var project_var = loaded;
    defer project_var.deinit();
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, project_var.manifest_path);
        return error.Failed;
    }

    var options = flags.toOptions(environ_map);
    // --locked は lock の無変更検証を強制する（check 自体は書き込まない
    // ため verifyLocked と矛盾しない）。
    if (flags.locked) {
        project.verifyLocked(a, io, &project_var, &options, &diagnostics) catch |err| {
            return failProject(stderr, "check", err, &diagnostics, project_var.manifest_path);
        };
    }
    const inspect = project.inspectForCheck(a, io, &project_var, &options, &diagnostics) catch |err| {
        return failProject(stderr, "check", err, &diagnostics, project_var.manifest_path);
    };
    const lock_state: []const u8 = switch (inspect.lock_state) {
        .missing => "missing",
        .invalid => "invalid",
        .fresh => "fresh",
        .stale => "stale",
    };

    var needed: std.ArrayList([]const u8) = .empty;
    if (inspect.lock_state != .fresh) try needed.append(a, "lnako lock");
    if (!inspect.environment_current) try needed.append(a, "lnako sync");

    if (flags.json) {
        var needed_json: std.ArrayList(u8) = .empty;
        for (needed.items, 0..) |cmd, i| {
            if (i > 0) try needed_json.appendSlice(a, ",");
            try needed_json.appendSlice(a, try std.fmt.allocPrint(a, "\"{s}\"", .{cmd}));
        }
        try stdout.print("{{\"schemaVersion\":1,\"manifest\":\"ok\",\"lock\":\"{s}\",\"environment\":\"{s}\",\"needed\":[{s}]}}\n", .{
            lock_state,
            if (inspect.environment == null) "missing" else if (inspect.environment_current) "current" else "stale",
            needed_json.items,
        });
        try stdout.flush();
    } else {
        try stdout.print("プロジェクト: {s}（{s}）\n", .{ project_var.manifest.package.name, project_var.root });
        try stdout.print("  nako.toml: OK\n", .{});
        try stdout.print("  nako.lock: {s}\n", .{lock_state});
        try stdout.print("  .nako 環境: {s}\n", .{if (inspect.environment == null) "missing" else if (inspect.environment_current) "current" else "stale"});
        if (needed.items.len > 0) {
            try stdout.print("  必要な操作:", .{});
            for (needed.items) |cmd| try stdout.print(" {s};", .{cmd});
            try stdout.print("\n", .{});
        }
        try stdout.flush();
    }
}

// ---------------------------------------------------------------------------
// cache
// ---------------------------------------------------------------------------

fn runCache(a: Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len == 0) return failUsage(stderr, "cache: サブコマンドが必要です（dir|clean）\n", .{});
    const verb = args[0];
    var cache_dir: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            cache_dir = try flagValue(args, &index, "cache", "--package-cache-dir", stderr);
        } else {
            return failUsage(stderr, "cache: 不明な引数です: {s}\n", .{argument});
        }
    }
    const default_root = try cache.defaultRoot(a);
    defer if (default_root) |r| a.free(r);
    const root = cache_dir orelse default_root orelse
        return fail(stderr, "cache: キャッシュディレクトリを決定できません（--package-cache-dir を指定してください）\n", .{});
    if (std.mem.eql(u8, verb, "dir")) {
        try stdout.print("{s}\n", .{root});
        try stdout.flush();
        return;
    }
    if (std.mem.eql(u8, verb, "clean")) {
        var store = cache.Store.open(a, io, root) catch |err| {
            return fail(stderr, "cache: キャッシュを開けません: {s}\n", .{@errorName(err)});
        };
        defer store.deinit();
        var guard = store.lockWait() catch {
            return fail(stderr, "cache: 別の処理がキャッシュを使用中です\n", .{});
        };
        defer guard.unlock();
        const removed = store.cleanAll() catch |err| {
            return fail(stderr, "cache: クリーンに失敗しました: {s}\n", .{@errorName(err)});
        };
        try stderr.print("cache: {d} 個の entry を削除しました\n", .{removed});
        try stderr.flush();
        return;
    }
    return failUsage(stderr, "cache: 不明なサブコマンドです: {s}（dir|clean）\n", .{verb});
}

// ---------------------------------------------------------------------------
// run/test/build 自動準備
// ---------------------------------------------------------------------------

/// 入力ファイル（またはディレクトリ）がプロジェクト配下なら依存準備を
/// 行う。`--locked`/`--offline`/`--no-sync` の禁止事項を守る。
/// プロジェクト外なら何もしない。
pub fn prepareForExecution(
    a: Allocator,
    io: std.Io,
    input: []const u8,
    flags: *const PrepFlags,
    environ_map: ?*const std.process.Environ.Map,
    verb: []const u8,
    stderr: *std.Io.Writer,
) !void {
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const start_dir = inputDir(a, io, input) catch return;
    defer a.free(start_dir);
    // 探索自体の失敗（破損した manifest 等）は黙って実行しない。
    const loaded = project.discoverAndLoad(a, io, start_dir, &diagnostics) catch |err| {
        renderOrFail(&diagnostics, stderr, start_dir);
        return fail(stderr, "{s}: プロジェクトを読み込めません: {s}\n", .{ verb, @errorName(err) });
    };
    const found = loaded orelse return; // 非プロジェクト: 従来動作
    var project_var = found;
    defer project_var.deinit();
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, project_var.manifest_path);
        return error.Failed;
    }

    var options = flags.toOptions(environ_map);
    // --locked は --no-sync と併用されても必ず検証する（書き込みを伴わ
    // ない静的検査のため sync 禁止と矛盾しない）。
    if (flags.locked) {
        project.verifyLocked(a, io, &project_var, &options, &diagnostics) catch |err| {
            return failProject(stderr, verb, err, &diagnostics, project_var.manifest_path);
        };
    }
    if (flags.no_sync) {
        // 自動準備禁止: 既存環境だけを静的検査する。
        try ensureEnvironmentUsable(a, io, &project_var, options.profile orelse "default", &diagnostics, verb, stderr);
        return;
    }
    const outcome = project.ensureEnvironment(a, io, &project_var, &options, &diagnostics) catch |err| {
        return failProject(stderr, verb, err, &diagnostics, project_var.manifest_path);
    };
    if (outcome.synced or outcome.lock_wrote) {
        stderr.print("{s}: 依存環境を準備しました（profile: {s}）\n", .{ verb, outcome.profile }) catch {};
        stderr.flush() catch {};
    }
}

/// `--no-sync` 時の静的環境検査。lock 存在・鮮度と `.nako` の整合を確認
/// し、不足があれば必要な操作を診断して失敗する。`expected_profile` は
/// 選択 profile（未指定時は default）。`ensureEnvironment` と同じ
/// profile・runtime 条件で環境を照合する。
fn ensureEnvironmentUsable(a: Allocator, io: std.Io, loaded: *project.Project, expected_profile: []const u8, diagnostics: *diag.List, verb: []const u8, stderr: *std.Io.Writer) !void {
    var digest: [32]u8 = undefined;
    const has_lock = project.lockDigest(a, io, loaded.root, &digest) catch false;
    const env = project.readEnvironmentInfo(a, io, loaded.root) catch null;
    const env_ok = has_lock and env != null and
        project.environmentMatchesLock(env.?, &digest) and
        env.?.schema_version == 1 and
        (env.?.profile == null or std.mem.eql(u8, env.?.profile.?, expected_profile)) and
        (env.?.runtime == null or std.mem.eql(u8, env.?.runtime.?, "lnako")) and
        // 参照世代 dir が消えた環境は不一致とする。
        (env.?.generation != null and project.generationExists(io, loaded.root, env.?.generation.?));
    if (!env_ok) {
        if (env == null) {
            return fail(stderr, "{s}: .nako 環境がありません（--no-sync のため自動準備しません。`lnako sync` を実行してください）\n", .{verb});
        } else {
            return fail(stderr, "{s}: .nako 環境が nako.lock と一致しません（`lnako sync` で再構築してください）\n", .{verb});
        }
    }
    // `mutable = false` の path 依存は pin hash も照合する。不一致なら
    // 環境が古い内容を参照しているため --no-sync でも失敗とする。
    const pin_bad = project.pinnedPathMismatch(a, io, loaded, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return fail(stderr, "{s}: OutOfMemory\n", .{verb}),
        else => null,
    };
    if (pin_bad) |name| {
        return fail(stderr, "{s}: path 依存 \"{s}\" の内容が nako.lock の pin hash と一致しません（`lnako lock` で更新してください）\n", .{ verb, name });
    }
}

fn inputDir(a: Allocator, io: std.Io, input: []const u8) ![]const u8 {
    const stat = std.Io.Dir.cwd().statFile(io, input, .{}) catch {
        const dir = std.fs.path.dirname(input) orelse return a.dupe(u8, ".");
        return a.dupe(u8, dir);
    };
    if (stat.kind == .directory) return a.dupe(u8, input);
    const dir = std.fs.path.dirname(input) orelse return a.dupe(u8, ".");
    return a.dupe(u8, dir);
}

// ---------------------------------------------------------------------------
// ディスパッチ
// ---------------------------------------------------------------------------

pub fn run(
    allocator: Allocator,
    io: std.Io,
    verb: []const u8,
    args: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    return runIn(allocator, io, verb, args, ".", environ_map, stdout, stderr);
}

/// `start_dir` を起点にプロジェクトを探索してコマンドを実行する。
/// テストから任意の作業ディレクトリで駆動できるよう分離してある。
pub fn runIn(
    allocator: Allocator,
    io: std.Io,
    verb: []const u8,
    args: []const []const u8,
    start_dir: []const u8,
    environ_map: ?*const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    if (std.mem.eql(u8, verb, "init")) return runInit(allocator, io, args, start_dir, stderr);
    if (std.mem.eql(u8, verb, "add")) return runAdd(allocator, io, args, start_dir, environ_map, stderr);
    if (std.mem.eql(u8, verb, "remove") or std.mem.eql(u8, verb, "rm")) return runRemove(allocator, io, args, start_dir, environ_map, stderr);
    if (std.mem.eql(u8, verb, "lock")) return runLock(allocator, io, args, start_dir, environ_map, stdout, stderr);
    if (std.mem.eql(u8, verb, "update")) return runUpdate(allocator, io, args, start_dir, environ_map, stderr);
    if (std.mem.eql(u8, verb, "tree")) return runTree(allocator, io, args, start_dir, environ_map, stdout, stderr);
    if (std.mem.eql(u8, verb, "why")) return runWhy(allocator, io, args, start_dir, environ_map, stdout, stderr);
    if (std.mem.eql(u8, verb, "check")) return checkProject(allocator, io, args, start_dir, environ_map, stdout, stderr);
    if (std.mem.eql(u8, verb, "cache")) return runCache(allocator, io, args, stdout, stderr);
    return failUsage(stderr, "不明なプロジェクトコマンドです: {s}\n", .{verb});
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
}

test "headerMatches は名前全体の引用を別テーブルとして区別する" {
    var buf: [1024]u8 = undefined;
    // `["dependencies.path"]` は `dependencies.path` という名前のテーブル
    // であり `dependencies` → `path` の入れ子ではない（一致させない）。
    try std.testing.expect(!headerMatches("[ \"dependencies.path\" ]", "dependencies.path", &buf));
    try std.testing.expect(headerMatches("[ dependencies.\"path\" ]", "dependencies.path", &buf));
    try std.testing.expect(headerMatches("[dependencies.path]", "dependencies.path", &buf));
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

test {
    _ = @import("project_test.zig");
}
