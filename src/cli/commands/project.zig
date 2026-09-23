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

fn fail(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

fn failUsage(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
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

/// 値を取るプロジェクト系オプション名（`--profile x` の値を位置引数と
/// 誤認しないため）。
const value_flags = [_][]const u8{ "--profile", "--features", "--registry", "--package-cache-dir", "-o" };
const flag_names = [_][]const u8{
    "--locked",   "--offline",           "--no-sync",
    "--profile",  "--features",          "--no-default-features",
    "--registry", "--package-cache-dir", "--allow-plaintext-http",
    "--json",
};

/// `args` から共通フラグを取り出す。`consume_positionals` が真なら残りの
/// 位置引数を返す。未知オプションは failUsage。
fn parsePrepFlags(a: Allocator, args: []const []const u8, verb: []const u8, stderr: *std.Io.Writer) struct { flags: PrepFlags, rest: []const []const u8 } {
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
            index += 1;
            if (index >= args.len) failUsage(stderr, "{s}: --profile には名前が必要です\n", .{verb});
            flags.profile = args[index];
        } else if (std.mem.eql(u8, argument, "--features")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "{s}: --features には名前（カンマ区切り）が必要です\n", .{verb});
            var it = std.mem.splitScalar(u8, args[index], ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " ");
                if (trimmed.len > 0) flags.features.append(a, trimmed) catch return .{ .flags = flags, .rest = rest.items };
            }
        } else if (std.mem.eql(u8, argument, "--no-default-features")) {
            flags.no_default_features = true;
        } else if (std.mem.eql(u8, argument, "--registry")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "{s}: --registry には URL が必要です\n", .{verb});
            flags.registry = args[index];
        } else if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "{s}: --package-cache-dir にはパスが必要です\n", .{verb});
            flags.cache_dir = args[index];
        } else if (std.mem.eql(u8, argument, "--allow-plaintext-http")) {
            flags.allow_plaintext_http = true;
        } else if (std.mem.eql(u8, argument, "--json")) {
            flags.json = true;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            failUsage(stderr, "{s}: 不明なオプションです: {s}\n", .{ verb, argument });
        } else {
            rest.append(a, argument) catch {};
        }
    }
    return .{ .flags = flags, .rest = rest.items };
}

/// prep 系フラグを `args` から `flags` へ移し、残りの引数配列を返す。
/// 値を取るフラグは値も一緒に消費する。認識しない引数（dncl 系・位置
/// 引数・未知オプション）は残りへ保持し、呼出し側の既存検証に委ねる。
/// `run`/`test`/`build` の自動準備統合用。
pub fn extractPrepFlags(a: Allocator, args: []const []const u8, flags: *PrepFlags) ![]const []const u8 {
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
            if (index + 1 >= args.len) {
                // 値が無い既存挙動に合わせて残りへ戻す。
                try rest.append(a, argument);
                continue;
            }
            index += 1;
            const value = args[index];
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

/// `--profile x` のような値を取るオプションを考慮しつつ、位置引数でない
/// 未知の `-` オプションを検出する。run/test/build 統合用。
pub fn findUnknownPrepFlag(args: []const []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        var is_value_flag = false;
        for (value_flags) |name| {
            if (std.mem.eql(u8, argument, name)) {
                is_value_flag = true;
                break;
            }
        }
        if (is_value_flag) {
            index += 1;
            continue;
        }
        if (!std.mem.startsWith(u8, argument, "-")) continue;
        var known = false;
        for (flag_names) |name| {
            if (std.mem.eql(u8, argument, name)) {
                known = true;
                break;
            }
        }
        if (!known) return argument;
    }
    return null;
}

/// プロジェクトを `start_dir` から上方探索して読み込む。見つからない・
/// manifest が不正なら診断を出力して終了する。
fn loadProjectOrFail(a: Allocator, io: std.Io, start_dir: []const u8, stderr: *std.Io.Writer) project.Project {
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const loaded = project.discoverAndLoad(a, io, start_dir, &diagnostics) catch |err| {
        renderOrFail(&diagnostics, stderr, start_dir);
        fail(stderr, "nako.toml を読み込めません: {s}\n", .{@errorName(err)});
    };
    const result = loaded orelse fail(stderr, "このディレクトリはプロジェクトではありません（nako.toml が見つかりません）\n", .{});
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, result.manifest_path);
        std.process.exit(1);
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
        error.LockNotFound => "nako.lock が見つかりません（`lnako lock` を実行してください）",
        error.LockInvalid => "nako.lock が不正です",
        error.StaleLock => "nako.lock が manifest と一致しません",
        error.Busy => "別の処理が cache/環境を使用中です",
        else => @errorName(err),
    };
}

fn failProject(stderr: *std.Io.Writer, verb: []const u8, err: anyerror, diagnostics: *diag.List, source_name: []const u8) noreturn {
    renderOrFail(diagnostics, stderr, source_name);
    fail(stderr, "{s}: {s}\n", .{ verb, projectErrorMessage(err) });
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

/// `[<section>]` テーブルヘッダの行開始 offset を探す。
fn findTableHeader(source: []const u8, section: []const u8) ?usize {
    var index: usize = 0;
    const wanted = std.fmt.allocPrint(std.heap.page_allocator, "[{s}]", .{section}) catch return null;
    defer std.heap.page_allocator.free(wanted);
    while (index < source.len) {
        const end = lineEnd(source, index);
        const text = std.mem.trim(u8, source[index..end], " \t\r");
        if (std.mem.eql(u8, text, wanted)) return index;
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

/// dep 宣言（単一行 `key = ...` または `[section.name]` サブテーブル）を
/// source から除去する。`position` は manifest が記録した dep value の
/// byte offset。
fn removeEntry(a: Allocator, source: []const u8, section: []const u8, name: []const u8, position: diag.Position) !?[]const u8 {
    // 1) `[<section>.<name>]` / `[<section>."<name>"]` サブテーブル形式
    {
        const bare = try std.fmt.allocPrint(a, "[{s}.{s}]", .{ section, name });
        const quoted = try std.fmt.allocPrint(a, "[{s}.\"{s}\"]", .{ section, name });
        var index: usize = 0;
        while (index < source.len) {
            const end = lineEnd(source, index);
            const text = std.mem.trim(u8, source[index..end], " \t\r");
            if (std.mem.eql(u8, text, bare) or std.mem.eql(u8, text, quoted)) {
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
    const remove_end = if (end < source.len) end + 1 else end;
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
    \\●(値の)二倍とは
    \\  それは値×2。
    \\ここまで
    \\
;

const lib_example_template =
    \\/// <name> の利用例。このファイルはライブラリ開発中の動作確認用で、
    \\/// 相対 path でライブラリソースを取り込む。
    \\
    \\『../src/lib.nako3』を取り込む。
    \\
    \\21を二倍して表示。
    \\
;

const lib_test_template =
    \\/// <name> のテスト。
    \\
    \\『../src/lib.nako3』を取り込む。
    \\
    \\●テスト:二倍とは
    \\  21を二倍した結果と42がASSERT等
    \\ここまで
    \\
;

fn writeInitFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = contents });
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
            index += 1;
            if (index >= args.len) failUsage(stderr, "init: --name には名前が必要です\n", .{});
            name_opt = args[index];
        } else if (std.mem.startsWith(u8, argument, "-")) {
            failUsage(stderr, "init: 不明なオプションです: {s}\n", .{argument});
        } else if (dir_arg == null) {
            dir_arg = argument;
        } else {
            failUsage(stderr, "init: 不明な引数です: {s}\n", .{argument});
        }
    }

    const cwd = std.Io.Dir.cwd();
    const dir_abs = if (dir_arg) |dir| blk: {
        const resolved = try project_abs(a, io, dir, start_dir);
        try cwd.createDirPath(io, resolved);
        break :blk resolved;
    } else blk: {
        break :blk try std.Io.Dir.cwd().realPathFileAlloc(io, start_dir, a);
    };
    const name = name_opt orelse std.fs.path.basename(dir_abs);
    const manifest_path = try std.fs.path.join(a, &.{ dir_abs, project.manifest_name });
    const exists = blk: {
        cwd.access(io, manifest_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (exists) {
        fail(stderr, "init: {s} は既に存在します\n", .{manifest_path});
    }

    var manifest_text: std.ArrayList(u8) = .empty;
    try manifest_text.appendSlice(a, try std.fmt.allocPrint(a,
        \\[package]
        \\name = "{s}"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    , .{name}));
    if (lib) {
        try manifest_text.appendSlice(a, try std.fmt.allocPrint(a,
            \\
            \\[[exports]]
            \\name = "{s}"
            \\path = "src/lib.nako3"
            \\
        , .{name}));
    }
    try cwd.writeFile(io, .{ .sub_path = manifest_path, .data = manifest_text.items });

    if (lib) {
        const lib_source = try std.fmt.allocPrint(a, "{s}", .{lib_source_template});
        const example = try std.fmt.allocPrint(a, "{s}", .{lib_example_template});
        const test_source = try std.fmt.allocPrint(a, "{s}", .{lib_test_template});
        try writeInitFile(io, cwd, try std.fs.path.join(a, &.{ dir_abs, "src", "lib.nako3" }), lib_source);
        try writeInitFile(io, cwd, try std.fs.path.join(a, &.{ dir_abs, "examples", "main.nako3" }), example);
        try writeInitFile(io, cwd, try std.fs.path.join(a, &.{ dir_abs, "tests", "lib_test.nako3" }), test_source);
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

fn depValueText(a: Allocator, request: AddRequest) ![]const u8 {
    switch (request.kind) {
        .pkg => {
            if (std.mem.eql(u8, request.range, "*")) {
                return std.fmt.allocPrint(a, "\"*\"", .{});
            }
            return std.fmt.allocPrint(a, "{{ version = \"{s}\" }}", .{request.range});
        },
        .npm => return std.fmt.allocPrint(a, "\"{s}\"", .{request.range}),
        .path => {
            var mutable_suffix: []const u8 = "";
            if (request.mutable) mutable_suffix = ", mutable = true";
            return std.fmt.allocPrint(a, "{{ path = \"{s}\"{s} }}", .{ request.path.?, mutable_suffix });
        },
        .git => {
            var parts: std.ArrayList(u8) = .empty;
            try parts.appendSlice(a, try std.fmt.allocPrint(a, "{{ url = \"{s}\"", .{request.git_url.?}));
            if (request.commit) |commit| {
                try parts.appendSlice(a, try std.fmt.allocPrint(a, ", commit = \"{s}\"", .{commit}));
            }
            if (request.dep_path) |dep_path| {
                try parts.appendSlice(a, try std.fmt.allocPrint(a, ", path = \"{s}\"", .{dep_path}));
            }
            try parts.appendSlice(a, " }");
            return parts.items;
        },
        .http => {
            var parts: std.ArrayList(u8) = .empty;
            try parts.appendSlice(a, try std.fmt.allocPrint(a, "{{ url = \"{s}\"", .{request.http_url.?}));
            if (request.hash) |hash| {
                try parts.appendSlice(a, try std.fmt.allocPrint(a, ", hash = \"{s}\"", .{hash}));
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
        fail(stderr, "{s}: 生成した manifest が不正です\n", .{verb});
    };
    defer candidate.deinit();
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, loaded.manifest_path);
        fail(stderr, "{s}: 生成した manifest が不正です\n", .{verb});
    }

    const original = try a.dupe(u8, loaded.manifest_bytes);
    writeAtomic(io, loaded.manifest_path, new_source) catch |err| {
        fail(stderr, "{s}: nako.toml を書き込めません: {s}\n", .{ verb, @errorName(err) });
    };

    // manifest を再読込して lock を最新化する。失敗したら manifest を復元。
    var reloaded = project.load(a, io, loaded.root, &diagnostics) catch |err| {
        _ = restoreManifest(io, loaded.manifest_path, original);
        failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
    };
    defer reloaded.deinit();
    var options = flags.toOptions(environ_map);
    if (flags.locked) {
        project.verifyLocked(a, io, &reloaded, &options, &diagnostics) catch |err| {
            _ = restoreManifest(io, loaded.manifest_path, original);
            failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
        };
    }
    const outcome = project.ensureLock(a, io, &reloaded, &options, &diagnostics) catch |err| {
        _ = restoreManifest(io, loaded.manifest_path, original);
        failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
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
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--dev")) {
            request.dev = true;
        } else if (std.mem.eql(u8, argument, "--path")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "add: --path にはパスが必要です\n", .{});
            request.kind = .path;
            request.path = args[index];
        } else if (std.mem.eql(u8, argument, "--git")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "add: --git には URL が必要です\n", .{});
            request.kind = .git;
            request.git_url = args[index];
        } else if (std.mem.eql(u8, argument, "--commit")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "add: --commit には ID が必要です\n", .{});
            request.commit = args[index];
        } else if (std.mem.eql(u8, argument, "--dep-path")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "add: --dep-path にはサブパスが必要です\n", .{});
            request.dep_path = args[index];
        } else if (std.mem.eql(u8, argument, "--http")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "add: --http には URL が必要です\n", .{});
            request.kind = .http;
            request.http_url = args[index];
        } else if (std.mem.eql(u8, argument, "--hash")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "add: --hash には sha256 が必要です\n", .{});
            request.hash = args[index];
        } else if (std.mem.eql(u8, argument, "--npm")) {
            request.kind = .npm;
        } else if (std.mem.eql(u8, argument, "--mutable")) {
            request.mutable = true;
        } else if (std.mem.eql(u8, argument, "--locked")) {
            flags.locked = true;
        } else if (std.mem.eql(u8, argument, "--offline")) {
            flags.offline = true;
        } else if (std.mem.eql(u8, argument, "--registry")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "add: --registry には URL が必要です\n", .{});
            flags.registry = args[index];
        } else if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "add: --package-cache-dir にはパスが必要です\n", .{});
            flags.cache_dir = args[index];
        } else if (std.mem.startsWith(u8, argument, "-")) {
            failUsage(stderr, "add: 不明なオプションです: {s}\n", .{argument});
        } else if (positional == null) {
            positional = argument;
        } else {
            failUsage(stderr, "add: 不明な引数です: {s}\n", .{argument});
        }
    }
    const spec = positional orelse failUsage(stderr, "add: パッケージ名（または name@range）が必要です\n", .{});
    const parts = splitNameRange(spec);
    request.name = parts.name;
    if (parts.range.len > 0) request.range = parts.range;
    if (request.name.len == 0) failUsage(stderr, "add: パッケージ名が空です\n", .{});

    switch (request.kind) {
        .path => if (request.path == null) failUsage(stderr, "add: --path には値が必要です\n", .{}),
        .git => if (request.git_url == null) failUsage(stderr, "add: --git には値が必要です\n", .{}),
        .http => if (request.http_url == null) failUsage(stderr, "add: --http には値が必要です\n", .{}),
        else => {},
    }

    var loaded = loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();

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
        } else if (std.mem.eql(u8, argument, "--registry")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "remove: --registry には URL が必要です\n", .{});
            flags.registry = args[index];
        } else if (std.mem.startsWith(u8, argument, "-")) {
            failUsage(stderr, "remove: 不明なオプションです: {s}\n", .{argument});
        } else if (positional == null) {
            positional = argument;
        } else {
            failUsage(stderr, "remove: 不明な引数です: {s}\n", .{argument});
        }
    }
    const name = positional orelse failUsage(stderr, "remove: パッケージ名が必要です\n", .{});

    var loaded = loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();

    // dev 未指定なら両方のグループを探す。
    var found = findDepPosition(&loaded.manifest, name, dev);
    var actual_dev = dev;
    if (found == null and !dev) {
        found = findDepPosition(&loaded.manifest, name, true);
        actual_dev = true;
    }
    const dep = found orelse fail(stderr, "remove: {s} は依存にありません\n", .{name});

    const section = try std.fmt.allocPrint(a, "{s}.{s}", .{
        if (actual_dev) "dev-dependencies" else "dependencies",
        dep.kind,
    });
    const new_source = (try removeEntry(a, loaded.manifest_bytes, section, name, dep.position)) orelse
        fail(stderr, "remove: nako.toml の編集位置を特定できませんでした（{s}）\n", .{name});
    var outcome = try writeAndLock(a, io, &loaded, new_source, &flags, environ_map, "remove", stderr);
    defer outcome.deinit();
    try stderr.print("remove: {s} を削除しました\n", .{name});
    try stderr.flush();
}

// ---------------------------------------------------------------------------
// lock / update
// ---------------------------------------------------------------------------

fn runLock(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = parsePrepFlags(a, args, "lock", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len > 0) failUsage(stderr, "lock: 不明な引数です: {s}\n", .{parsed.rest[0]});

    var loaded = loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = flags.toOptions(environ_map);
    if (flags.locked) {
        project.verifyLocked(a, io, &loaded, &options, &diagnostics) catch |err| {
            failProject(stderr, "lock", err, &diagnostics, loaded.manifest_path);
        };
    }
    var outcome = project.ensureLock(a, io, &loaded, &options, &diagnostics) catch |err| {
        failProject(stderr, "lock", err, &diagnostics, loaded.manifest_path);
    };
    defer outcome.deinit();
    if (flags.json) {
        try stdout.print("{{\"profile\":\"{s}\",\"packages\":{d},\"wrote\":{s}}}\n", .{ outcome.profile, outcome.lock.packages.len, if (outcome.wrote) "true" else "false" });
        try stdout.flush();
    } else {
        try stderr.print("lock: {d} 個の package を {s} に記録しました（profile: {s}）\n", .{ outcome.lock.packages.len, project.lock_name, outcome.profile });
        try stderr.flush();
    }
}

fn runUpdate(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stderr: *std.Io.Writer) !void {
    const parsed = parsePrepFlags(a, args, "update", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (flags.locked) fail(stderr, "update: --locked と update は両立しません\n", .{});

    var loaded = loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = flags.toOptions(environ_map);
    options.update_targets = parsed.rest;
    options.update_all = parsed.rest.len == 0;
    // fresh な lock でも再解決して新版を拾うのが update の契約。
    options.force_resolve = true;
    var outcome = project.ensureLock(a, io, &loaded, &options, &diagnostics) catch |err| {
        failProject(stderr, "update", err, &diagnostics, loaded.manifest_path);
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

fn lockForQuery(a: Allocator, io: std.Io, loaded: *project.Project, flags: *const PrepFlags, environ_map: ?*const std.process.Environ.Map, verb: []const u8, stderr: *std.Io.Writer) project.LockOutcome {
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = flags.toOptions(environ_map);
    if (flags.locked) {
        project.verifyLocked(a, io, loaded, &options, &diagnostics) catch |err| {
            failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
        };
    }
    return project.ensureLock(a, io, loaded, &options, &diagnostics) catch |err| {
        failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
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

fn runTree(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = parsePrepFlags(a, args, "tree", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len > 0) failUsage(stderr, "tree: 不明な引数です: {s}\n", .{parsed.rest[0]});

    var loaded = loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var outcome = lockForQuery(a, io, &loaded, &flags, environ_map, "tree", stderr);
    defer outcome.deinit();

    const packages = outcome.lock.packagesForProfile(outcome.profile) orelse outcome.lock.packages;
    // 被参照でない package を root として表示する（lock は全 package の
    // 和集合で、直接依存は他の依存から参照されない）。
    var referenced = std.StringHashMap(void).init(a);
    defer referenced.deinit();
    for (packages) |entry| {
        for (entry.dependencies) |dep_id| try referenced.put(dep_id, {});
    }
    try stdout.print("{s} {f} (profile: {s})\n", .{ loaded.manifest.package.name, loaded.manifest.package.version, outcome.profile });
    for (packages) |entry| {
        if (referenced.contains(entry.id)) continue;
        try printTreeNode(a, stdout, packages, entry, "", true, &.{});
    }
    try stdout.flush();
}

fn findEntry(packages: []const lock_model.PackageEntry, id: []const u8) ?lock_model.PackageEntry {
    for (packages) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn printTreeNode(a: Allocator, stdout: *std.Io.Writer, packages: []const lock_model.PackageEntry, entry: lock_model.PackageEntry, prefix: []const u8, last: bool, seen: []const []const u8) !void {
    const branch = if (last) "└── " else "├── ";
    try stdout.print("{s}{s}{s} {s} [{s}{s}]\n", .{ prefix, branch, entry.name, entry.version, sourceTag(entry), if (entry.implementation) |impl| std.fmt.allocPrint(a, ", {s}", .{impl}) catch "" else "" });
    for (seen) |id| {
        if (std.mem.eql(u8, id, entry.id)) return;
    }
    var next_seen: std.ArrayList([]const u8) = .empty;
    try next_seen.appendSlice(a, seen);
    try next_seen.append(a, entry.id);
    const child_prefix = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, if (last) "    " else "│   " });
    for (entry.dependencies, 0..) |dep_id, i| {
        const child = findEntry(packages, dep_id) orelse continue;
        try printTreeNode(a, stdout, packages, child, child_prefix, i == entry.dependencies.len - 1, next_seen.items);
    }
}

fn runWhy(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = parsePrepFlags(a, args, "why", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len == 0) failUsage(stderr, "why: パッケージ名が必要です\n", .{});
    if (parsed.rest.len > 1) failUsage(stderr, "why: 不明な引数です: {s}\n", .{parsed.rest[1]});
    const name = parsed.rest[0];

    var loaded = loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var outcome = lockForQuery(a, io, &loaded, &flags, environ_map, "why", stderr);
    defer outcome.deinit();

    const packages = outcome.lock.packagesForProfile(outcome.profile) orelse outcome.lock.packages;
    var target: ?lock_model.PackageEntry = null;
    for (packages) |entry| {
        if (std.mem.eql(u8, entry.name, name) or std.mem.eql(u8, entry.id, name)) {
            target = entry;
            break;
        }
    }
    const entry = target orelse fail(stderr, "why: {s} は解決済み依存にありません\n", .{name});

    try stdout.print("{s} {s} [{s}{s}]\n", .{ entry.name, entry.version, sourceTag(entry), if (entry.implementation) |impl| std.fmt.allocPrint(a, ", {s}", .{impl}) catch "" else "" });
    // manifest の直接宣言かを確認する。
    if (manifestDeclares(&loaded.manifest, name)) |declared| {
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
    if (!found_dependent and manifestDeclares(&loaded.manifest, name) == null) {
        try stdout.print("  理由: 解決グラフに含まれます（参照元は lock に記録されていません）\n", .{});
    }
    try stdout.flush();
}

fn manifestDeclares(manifest: *const manifest_mod.Manifest, name: []const u8) ?[]const u8 {
    for ([_]*const manifest_mod.DependencyGroup{ &manifest.dependencies, &manifest.dev_dependencies }) |group| {
        var pkg_it = group.pkg.iterator();
        while (pkg_it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, name)) return "dependencies.pkg";
        var npm_it = group.npm.iterator();
        while (npm_it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, name)) return "dependencies.npm";
        var path_it = group.path.iterator();
        while (path_it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, name)) return "dependencies.path";
        var git_it = group.git.iterator();
        while (git_it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, name)) return "dependencies.git";
        var http_it = group.http.iterator();
        while (http_it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, name)) return "dependencies.http";
    }
    return null;
}

// ---------------------------------------------------------------------------
// check（副作用なし）
// ---------------------------------------------------------------------------

/// 既存環境が現行 lock と整合するか検査する。`.nako` を作成しない。
pub fn checkProject(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = parsePrepFlags(a, args, "check", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const found = project.discoverAndLoad(a, io, start_dir, &diagnostics) catch |err| {
        failProject(stderr, "check", err, &diagnostics, ".");
    };
    const loaded = found orelse fail(stderr, "check: このディレクトリはプロジェクトではありません（nako.toml が見つかりません）\n", .{});
    var project_var = loaded;
    defer project_var.deinit();
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, project_var.manifest_path);
        std.process.exit(1);
    }

    var options = flags.toOptions(environ_map);
    const inspect = project.inspectForCheck(a, io, &project_var, &options, &diagnostics) catch |err| {
        failProject(stderr, "check", err, &diagnostics, project_var.manifest_path);
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
    if (args.len == 0) failUsage(stderr, "cache: サブコマンドが必要です（dir|clean）\n", .{});
    const verb = args[0];
    var cache_dir: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            index += 1;
            if (index >= args.len) failUsage(stderr, "cache: --package-cache-dir にはパスが必要です\n", .{});
            cache_dir = args[index];
        } else {
            failUsage(stderr, "cache: 不明な引数です: {s}\n", .{argument});
        }
    }
    const default_root = try cache.defaultRoot(a);
    defer if (default_root) |r| a.free(r);
    const root = cache_dir orelse default_root orelse
        fail(stderr, "cache: キャッシュディレクトリを決定できません（--package-cache-dir を指定してください）\n", .{});
    if (std.mem.eql(u8, verb, "dir")) {
        try stdout.print("{s}\n", .{root});
        try stdout.flush();
        return;
    }
    if (std.mem.eql(u8, verb, "clean")) {
        var store = cache.Store.open(a, io, root) catch |err| {
            fail(stderr, "cache: キャッシュを開けません: {s}\n", .{@errorName(err)});
        };
        defer store.deinit();
        var guard = store.lockWait() catch {
            fail(stderr, "cache: 別の処理がキャッシュを使用中です\n", .{});
        };
        defer guard.unlock();
        const removed = store.cleanAll() catch |err| {
            fail(stderr, "cache: クリーンに失敗しました: {s}\n", .{@errorName(err)});
        };
        try stderr.print("cache: {d} 個の entry を削除しました\n", .{removed});
        try stderr.flush();
        return;
    }
    failUsage(stderr, "cache: 不明なサブコマンドです: {s}（dir|clean）\n", .{verb});
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
) void {
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const start_dir = inputDir(a, io, input) catch return;
    defer a.free(start_dir);
    // 探索自体の失敗（破損した manifest 等）は黙って実行しない。
    const loaded = project.discoverAndLoad(a, io, start_dir, &diagnostics) catch |err| {
        renderOrFail(&diagnostics, stderr, start_dir);
        fail(stderr, "{s}: プロジェクトを読み込めません: {s}\n", .{ verb, @errorName(err) });
    };
    const found = loaded orelse return; // 非プロジェクト: 従来動作
    var project_var = found;
    defer project_var.deinit();
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, project_var.manifest_path);
        std.process.exit(1);
    }

    var options = flags.toOptions(environ_map);
    if (flags.no_sync) {
        // 自動準備禁止: 既存環境だけを静的検査する。
        ensureEnvironmentUsable(a, io, &project_var, &options, &diagnostics, verb, stderr);
        return;
    }
    if (flags.locked) {
        project.verifyLocked(a, io, &project_var, &options, &diagnostics) catch |err| {
            failProject(stderr, verb, err, &diagnostics, project_var.manifest_path);
        };
    }
    const outcome = project.ensureEnvironment(a, io, &project_var, &options, &diagnostics) catch |err| {
        failProject(stderr, verb, err, &diagnostics, project_var.manifest_path);
    };
    if (outcome.synced or outcome.lock_wrote) {
        stderr.print("{s}: 依存環境を準備しました（profile: {s}）\n", .{ verb, outcome.profile }) catch {};
        stderr.flush() catch {};
    }
}

/// `--no-sync` 時の静的環境検査。lock 存在・鮮度と `.nako` の整合を確認
/// し、不足があれば必要な操作を診断して失敗する。
fn ensureEnvironmentUsable(a: Allocator, io: std.Io, loaded: *project.Project, options: *const project.PrepareOptions, diagnostics: *diag.List, verb: []const u8, stderr: *std.Io.Writer) void {
    var digest: [32]u8 = undefined;
    const has_lock = project.lockDigest(a, io, loaded.root, &digest) catch false;
    const env = project.readEnvironmentInfo(a, io, loaded.root) catch null;
    const env_ok = has_lock and env != null and
        project.environmentMatchesLock(env.?, &digest) and
        env.?.schema_version == 1;
    if (!env_ok) {
        if (env == null) {
            fail(stderr, "{s}: .nako 環境がありません（--no-sync のため自動準備しません。`lnako sync` を実行してください）\n", .{verb});
        } else {
            fail(stderr, "{s}: .nako 環境が nako.lock と一致しません（`lnako sync` で再構築してください）\n", .{verb});
        }
    }
    _ = options;
    _ = diagnostics;
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
    failUsage(stderr, "不明なプロジェクトコマンドです: {s}\n", .{verb});
}

test {
    _ = @import("project_test.zig");
}
