//! `run`/`test`/`build` 共通の準備フラグ解析。
//! 値の意味・診断文・既定値は `project.zig` の実装と同一に保つ。

const std = @import("std");
const lnako = @import("lnako");
const project_cmd = @import("project.zig");

const project = lnako.package.project;
const CliError = project_cmd.CliError;
const failUsage = project_cmd.failUsage;

const Allocator = std.mem.Allocator;

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
    /// `check --strict-sharing`: 未検査 package が残れば E033 で失敗する。
    strict_sharing: bool = false,
    /// `check --load-plugins`: plugin を実際にロードして実登録照合を行う
    /// （opt-in。plugin の初期化コード実行を伴うため既定では動かない）。
    load_plugins: bool = false,
    /// 共有 writable ACL/mode を検出したら拒否（旧既定）。既定は警告+続行。
    strict_project_trust: bool = false,
    /// 共有 writable の警告を出さない（続行はする）。
    no_project_trust_warning: bool = false,
    /// `run`/`build --compat-js` の compat 実行。依存解決の ESM 許容と
    /// lock 鮮度入力へ伝える（prep フラグとしては抽出せず呼出し側が
    /// 設定する）。
    compat_js: bool = false,
    /// `build -O` の実効レベル（`"O0"`〜`"O3"`）。依存解決の
    /// optimize-gated 実装選択と lock 鮮度入力へ伝える。null は未指定。
    optimize: ?[]const u8 = null,

    pub fn deinit(self: *PrepFlags, a: Allocator) void {
        self.features.deinit(a);
    }

    /// v1 環境の再読込・鮮度検証へ渡す選択入力。`prepareForExecution` が
    /// 検証した `--profile` / `--features` / `--no-default-features` を
    /// compile 側でも同じ値にする。
    pub fn v1LoadOptions(self: *const PrepFlags) lnako.package.v1_runtime.LoadOptions {
        return .{
            .profile = self.profile,
            .features = self.features.items,
            .no_default_features = self.no_default_features,
        };
    }

    pub fn toOptions(self: *const PrepFlags, environ_map: ?*const std.process.Environ.Map) project.PrepareOptions {
        var options = project.PrepareOptions{
            .locked = self.locked,
            .profile = self.profile,
            .features = self.features.items,
            .no_default_features = self.no_default_features,
            .registry_url = self.registry,
            .cache_root = self.cache_dir,
            // run/test/build・lock 系の要求 runtime は lnako（`lnako sync
            // --runtime` は cli/commands/sync.zig が別途設定する）。
            .requested_runtime = "lnako",
            // engines 照合にこの処理系の version を供給する。未供給だと
            // `engines.nako`/`engines.lnako` 制約が解決へ効かない。
            // `cnako_version` も sync と同じ値を供給する。lock input の
            // version tuple が入口ごとに違うと、`lnako lock` が書いた
            // lock を `lnako sync` が stale 判定して書き戻す往復に
            // なるため、どの入口でも同じ組を記録する。
            .nako_version = lnako.package.semver.Version.parse(project.compat_nako_version) catch null,
            .cnako_version = lnako.package.semver.Version.parse(project.compat_nako_version) catch null,
            .lnako_version = lnako.package.semver.Version.parse(lnako.version) catch null,
            .compat_js = self.compat_js,
            .optimize = self.optimize,
        };
        options.policy.offline = self.offline;
        options.policy.allow_plaintext_http = self.allow_plaintext_http;
        if (options.registry_url == null) {
            if (environ_map) |map| {
                if (map.get("LNAKO_REGISTRY")) |url| options.registry_url = url;
            }
        }
        // npm の packument は npm registry の JSON schema で配信され、lnako の
        // static registry（index/record）とは別サービス。同じ URL を暗黙に
        // 使い回すと private registry 設定下で解決先を取り違えるため、npm 専用
        // の環境変数でのみ上書きする（既定は registry.npmjs.org）。
        if (options.npm_registry_url == null) {
            if (environ_map) |map| {
                if (map.get("LNAKO_NPM_REGISTRY")) |url| options.npm_registry_url = url;
            }
        }
        return options;
    }

    /// CLI / 環境変数から共有 writable の扱いを決める。
    /// `--strict-project-trust` と `--no-project-trust-warning` の同時指定は
    /// 呼出し側で用法エラーにする。
    pub fn writableMode(self: *const PrepFlags, environ_map: ?*const std.process.Environ.Map) lnako.package.project_trust.WritableMode {
        if (self.strict_project_trust) return .enforce;
        if (self.no_project_trust_warning) return .ignore;
        if (environ_map) |map| {
            if (map.get("LNAKO_PROJECT_TRUST")) |raw| {
                if (lnako.package.project_trust.WritableMode.parse(raw)) |mode| return mode;
            }
        }
        return .warn;
    }
};

/// 値を取るフラグの次の引数を値として取り出す。末尾に値が無い場合や、
/// 次の引数が別のオプション（`-` 始まり）なら用法エラーとする。
pub fn flagValue(args: []const []const u8, index: *usize, verb: []const u8, flag: []const u8, stderr: *std.Io.Writer) CliError![]const u8 {
    if (index.* + 1 >= args.len or std.mem.startsWith(u8, args[index.* + 1], "-")) {
        return failUsage(stderr, "{s}: {s} には値が必要です\n", .{ verb, flag });
    }
    index.* += 1;
    return args[index.*];
}

pub const PrepParseResult = struct { flags: PrepFlags, rest: []const []const u8 };

/// `args` から共通フラグを取り出し、残りの位置引数を返す。
/// 未知オプションは failUsage。
pub fn parsePrepFlags(a: Allocator, args: []const []const u8, verb: []const u8, stderr: *std.Io.Writer) (CliError || error{OutOfMemory})!PrepParseResult {
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
        } else if (std.mem.eql(u8, argument, "--strict-sharing")) {
            flags.strict_sharing = true;
        } else if (std.mem.eql(u8, argument, "--load-plugins")) {
            flags.load_plugins = true;
        } else if (std.mem.eql(u8, argument, "--strict-project-trust")) {
            flags.strict_project_trust = true;
        } else if (std.mem.eql(u8, argument, "--no-project-trust-warning")) {
            flags.no_project_trust_warning = true;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return failUsage(stderr, "{s}: 不明なオプションです: {s}\n", .{ verb, argument });
        } else {
            try rest.append(a, argument);
        }
    }
    if (flags.strict_project_trust and flags.no_project_trust_warning) {
        return failUsage(stderr, "{s}: --strict-project-trust と --no-project-trust-warning は同時に指定できません\n", .{verb});
    }
    return .{ .flags = flags, .rest = rest.items };
}

/// verb ごとに意味を持つフラグの許可集合。許可外のフラグが指定された
/// 場合は黙って無視せず用法エラーとする。
pub const FlagMask = struct {
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
    strict_sharing: bool = false,
    load_plugins: bool = false,
    strict_project_trust: bool = false,
    no_project_trust_warning: bool = false,
};

pub fn rejectInertFlags(flags: *const PrepFlags, verb: []const u8, comptime allowed: FlagMask, stderr: *std.Io.Writer) CliError!void {
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
    else if (!allowed.strict_sharing and flags.strict_sharing)
        "--strict-sharing"
    else if (!allowed.load_plugins and flags.load_plugins)
        "--load-plugins"
    else if (!allowed.strict_project_trust and flags.strict_project_trust)
        "--strict-project-trust"
    else if (!allowed.no_project_trust_warning and flags.no_project_trust_warning)
        "--no-project-trust-warning"
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
        } else if (std.mem.eql(u8, argument, "--strict-project-trust")) {
            flags.strict_project_trust = true;
        } else if (std.mem.eql(u8, argument, "--no-project-trust-warning")) {
            flags.no_project_trust_warning = true;
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
    if (flags.strict_project_trust and flags.no_project_trust_warning) {
        return failUsage(stderr, "{s}: --strict-project-trust と --no-project-trust-warning は同時に指定できません\n", .{verb});
    }
    return rest.items;
}
