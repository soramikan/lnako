const std = @import("std");
const fetch = @import("fetch.zig");
const diag = @import("diagnostics.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const npkg_files = @import("npkg_files.zig");
const npkg_verify = @import("npkg_verify.zig");

const Allocator = std.mem.Allocator;

pub const Session = fetch.Session;
pub const Policy = fetch.Policy;
pub const Error = fetch.Error;
pub const Failure = fetch.Failure;
pub const FailureKind = fetch.FailureKind;
pub const ResourceKind = fetch.ResourceKind;

/// 1 つの依存宣言から取得した検証可能な結果。source identity・metadata・
/// artifact bytes を resolver/lock 層がそのまま使える形で返す。
/// 全メモリは呼出し側の `Session` arena が所有する。
pub const Acquired = struct {
    /// 確定した source identity。`nako.lock` の `source` と同じ形。
    source: lock_model.Source,
    /// 取得した manifest（`nako.toml` または `.npkg` の `METADATA.toml`）。
    /// 取得できない source（生 bytes のみ等）は null。
    manifest: ?manifest_mod.Manifest = null,
    /// artifact 本体。path/git は source 参照のみで bytes を持たない。
    artifact_bytes: ?[]const u8 = null,
    /// artifact の SHA-256（64 桁 hex）。
    artifact_sha256: ?[]const u8 = null,
    /// artifact の `type`（`.npkg`/`raw` など）。bytes が無い場合は null。
    artifact_type: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// path provider
// ---------------------------------------------------------------------------

/// path 依存の取得。path は編集可能な参照であり、ディレクトリ内の
/// `nako.toml` を読んで manifest を返す。ネットワーク・git は使わないため
/// `--offline` でも動作する。Unicode path は byte 列としてそのまま扱う。
///
/// `base_dir` は manifest を置いたプロジェクトルート（依存宣言の基準 dir）。
pub fn acquirePath(
    session: *Session,
    dep: manifest_mod.PathDependency,
    base_dir: []const u8,
) Error!Acquired {
    const gpa = session.allocator();
    const dir_path = try std.fs.path.join(gpa, &.{ base_dir, dep.path });
    const manifest_path = try std.fs.path.join(gpa, &.{ dir_path, "nako.toml" });
    const parsed = try readDependencyManifest(session, manifest_path, dep.name, "path");
    return .{
        .source = .{ .kind = .path, .path = dep.path, .mutable = dep.mutable },
        .manifest = parsed,
    };
}

/// path・git provider 共通の manifest 読み取り。`max_bytes = 0` は上限なし
/// （HTTP 取得と同じ契約）として扱い、上限超過は `too_large` に分類する。
fn readDependencyManifest(session: *Session, manifest_path: []const u8, dep_name: []const u8, dep_kind: []const u8) Error!manifest_mod.Manifest {
    const gpa = session.allocator();
    const limit: std.Io.Limit = if (session.policy.max_bytes == 0) .unlimited else .limited(session.policy.max_bytes);
    const bytes = std.Io.Dir.cwd().readFileAlloc(session.io, manifest_path, gpa, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.FileNotFound => return session.fail(.not_found, .manifest, manifest_path, "{s} dependency \"{s}\" has no nako.toml at \"{s}\"", .{ dep_kind, dep_name, manifest_path }),
        error.StreamTooLong => return session.fail(.too_large, .manifest, manifest_path, "manifest at \"{s}\" exceeds the {d} byte limit", .{ manifest_path, session.policy.max_bytes }),
        else => return session.fail(.network, .manifest, manifest_path, "cannot read \"{s}\": {s}", .{ manifest_path, @errorName(err) }),
    };
    var scratch = diag.List.init(session.gpa);
    defer scratch.deinit();
    return manifest_mod.parse(gpa, bytes, session.diagSink(&scratch)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidManifest => return session.fail(.invalid_metadata, .manifest, manifest_path, "manifest at \"{s}\" is invalid", .{manifest_path}),
    };
}

// ---------------------------------------------------------------------------
// Git provider
// ---------------------------------------------------------------------------

/// Git 依存の取得。`dep.commit`（7–40 桁 hex の commit-ish）を完全な
/// 40 桁 commit SHA へ固定し、manifest を読み込む。Git 実行ファイルは
/// Git 依存を処理するときだけ要求する。
///
/// `checkout_dir` はこの依存専用の作業 dir。`<checkout_dir>/.git` が既に
/// 存在する場合は clone を省略して再利用する（offline 時も object があれば
/// 参照できる）。
///
/// `locked` に既存 lock の source を渡すと、宣言の `commit` が lock の
/// commit 接頭辞と一致する限り lock 側の完全 SHA を使う。リモート参照が
/// 動いても（tag の付け替え等）lock の commit を再解決しない。
pub fn acquireGit(
    session: *Session,
    dep: manifest_mod.GitDependency,
    checkout_dir: []const u8,
    locked: ?lock_model.Source,
) Error!Acquired {
    const gpa = session.allocator();
    const io = session.io;

    var pinned: ?[]const u8 = null;
    if (locked) |source| {
        if (source.kind != .git or !optEql(source.url, dep.url) or !optEql(source.path, dep.path)) {
            return session.fail(.source_collision, .repository, dep.url, "git dependency \"{s}\" conflicts with the locked source", .{dep.name});
        }
        if (source.commit) |commit| {
            if (commit.len == 40 and std.mem.startsWith(u8, commit, dep.commit)) {
                pinned = commit;
            }
        }
    }

    const dot_git = try std.fs.path.join(gpa, &.{ checkout_dir, ".git" });
    const has_checkout = blk: {
        std.Io.Dir.cwd().access(io, dot_git, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => break :blk true,
        };
        break :blk true;
    };

    if (!has_checkout) {
        if (session.policy.offline) {
            return session.fail(.offline, .repository, dep.url, "offline mode: git repository \"{s}\" is not available locally", .{dep.url});
        }
        try gitRun(session, &.{ "git", "clone", "--quiet", "--no-checkout", dep.url, checkout_dir }, null);
    }

    // 既存 checkout に commit-ish が無ければ、オンラインではリモートを
    // fetch してから再解決する（clone 後に追加された commit を拾う）。
    const full_commit = pinned orelse blk: {
        if (try resolveCommit(session, checkout_dir, dep.commit)) |commit| break :blk commit;
        if (session.policy.offline) {
            return session.fail(.offline, .repository, dep.url, "offline mode: commit-ish \"{s}\" of \"{s}\" is not available locally", .{ dep.commit, dep.url });
        }
        try gitRun(session, &.{ "git", "-C", checkout_dir, "fetch", "--quiet", "origin" }, dep.url);
        if (try resolveCommit(session, checkout_dir, dep.commit)) |commit| break :blk commit;
        return session.fail(.not_found, .repository, dep.url, "commit \"{s}\" of \"{s}\" was not found", .{ dep.commit, dep.url });
    };

    // object が clone 済みか確認し、checkout して manifest を読む。
    {
        const verify_arg = try std.fmt.allocPrint(gpa, "{s}^{{commit}}", .{full_commit});
        const result = try gitRunAllowFailure(session, gpa, &.{ "git", "-C", checkout_dir, "cat-file", "-e", verify_arg });
        if (!result.succeeded) {
            if (session.policy.offline) {
                return session.fail(.offline, .repository, dep.url, "offline mode: commit {s} of \"{s}\" is not available locally", .{ full_commit, dep.url });
            }
            try gitRun(session, &.{ "git", "-C", checkout_dir, "fetch", "--quiet", "origin", full_commit }, dep.url);
            const retry = try gitRunAllowFailure(session, gpa, &.{ "git", "-C", checkout_dir, "cat-file", "-e", verify_arg });
            if (!retry.succeeded) {
                return session.fail(.not_found, .repository, dep.url, "commit {s} of \"{s}\" was not found", .{ full_commit, dep.url });
            }
        }
    }
    try gitRun(session, &.{ "git", "-C", checkout_dir, "checkout", "--quiet", full_commit }, dep.url);

    // `dep.path` は checkout 内の subdirectory。`..`・絶対 path などで
    // checkout 境界の外へ出る指定は拒否する（npkg の規範 path 規則と同じ）。
    if (dep.path) |sub| {
        if (!npkg_files.isCanonicalPath(sub)) {
            return session.fail(.invalid_source, .repository, sub, "git dependency path \"{s}\" is not a canonical repository-relative path", .{sub});
        }
    }
    const manifest_dir = if (dep.path) |sub| try std.fs.path.join(gpa, &.{ checkout_dir, sub }) else checkout_dir;
    const manifest_path = try std.fs.path.join(gpa, &.{ manifest_dir, "nako.toml" });
    const parsed = try readDependencyManifest(session, manifest_path, dep.name, "git");
    return .{
        .source = .{ .kind = .git, .url = dep.url, .commit = full_commit, .path = dep.path },
        .manifest = parsed,
    };
}

/// commit-ish（7–40 桁 hex）を完全な commit SHA へ解決する。
/// `--disambiguate` で object を列挙するため、prefix と同名の移動した
/// tag/branch に衝突して誤った参照を選ばない。
/// ローカル object に見つからない場合は null を返す（失敗は記録しない。
/// 呼出し側が fetch 後の再試行や失敗分類を行う）。prefix が複数 commit
/// へ曖昧な場合は `invalid_source` として記録して失敗する。
fn resolveCommit(session: *Session, checkout_dir: []const u8, commitish: []const u8) Error!?[]const u8 {
    const gpa = session.allocator();
    const arg = try std.fmt.allocPrint(gpa, "--disambiguate={s}", .{commitish});
    const result = try gitRunAllowFailure(session, gpa, &.{ "git", "-C", checkout_dir, "rev-parse", arg });
    if (!result.succeeded) return null;
    var commit: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const candidate = std.mem.trim(u8, line, " \t\r");
        if (candidate.len != 40) continue;
        const type_result = try gitRunAllowFailure(session, gpa, &.{ "git", "-C", checkout_dir, "cat-file", "-t", candidate });
        if (!type_result.succeeded) continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, type_result.stdout, " \t\r\n"), "commit")) continue;
        if (commit != null) {
            return session.fail(.invalid_source, .repository, commitish, "commit prefix \"{s}\" is ambiguous", .{commitish});
        }
        commit = try gpa.dupe(u8, candidate);
    }
    return commit;
}

const GitResult = struct {
    succeeded: bool,
    stdout: []const u8,
    stderr: []const u8,
};

fn gitRunAllowFailure(session: *Session, gpa: Allocator, argv: []const []const u8) Error!GitResult {
    var env_map = try fetch.sanitizedGitEnvMap(gpa);
    defer if (env_map) |*m| m.deinit();
    const result = std.process.run(gpa, session.io, .{
        .argv = argv,
        .environ_map = if (env_map) |*m| m else null,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
        .timeout = if (session.policy.timeout_ns == 0) .none else .{ .duration = .{ .raw = .fromNanoseconds(@intCast(session.policy.timeout_ns)), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return session.fail(.timeout, .repository, argv[argv.len - 1], "git command timed out", .{}),
        error.FileNotFound => return session.fail(.unavailable, .repository, "git", "git executable is required for git dependencies but was not found", .{}),
        else => return session.fail(.network, .repository, argv[argv.len - 1], "git command failed to start: {s}", .{@errorName(err)}),
    };
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .succeeded = succeeded, .stdout = result.stdout, .stderr = result.stderr };
}

/// git を実行し、非ゼロ終了・spawn 失敗を分類済み失敗へ写像する。
fn gitRun(session: *Session, argv: []const []const u8, target: ?[]const u8) Error!void {
    const gpa = session.allocator();
    const result = try gitRunAllowFailure(session, gpa, argv);
    if (!result.succeeded) {
        const detail = std.mem.trim(u8, result.stderr, " \t\r\n");
        return session.fail(.network, .repository, target orelse argv[argv.len - 1], "git command failed: {s}", .{detail});
    }
}

// ---------------------------------------------------------------------------
// HTTP provider
// ---------------------------------------------------------------------------

/// HTTP URL 依存の取得。`dep.hash` で内容を照合し、`.npkg`（ZIP）であれば
/// `npkg_verify` で検証して manifest を取り出す。別 source への暗黙切替や
/// hash 未検証の受理は行わない。
pub fn acquireHttp(session: *Session, dep: manifest_mod.HttpDependency) Error!Acquired {
    const bytes = try fetch.fetchBytes(session, dep.url, .artifact);
    try fetch.verifyHash(session, bytes, dep.hash, dep.url, .artifact);

    var acquired = Acquired{
        .source = .{ .kind = .http, .url = dep.url, .hash = dep.hash },
        .artifact_bytes = bytes,
        .artifact_sha256 = try fetch.sha256Hex(session.allocator(), bytes),
        .artifact_type = "raw",
    };

    // `.npkg`（ZIP 格納形式）は先頭が local file header 署名 `PK\x03\x04`。
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04")) {
        var scratch = diag.List.init(session.gpa);
        defer scratch.deinit();
        // `Verified` の arena は session arena を backing にするため、deinit
        // せず session の寿命まで `verified.manifest` を有効に保つ。
        const verified = npkg_verify.verify(session.allocator(), bytes, .{}, session.diagSink(&scratch)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return session.fail(.invalid_metadata, .artifact, dep.url, "downloaded .npkg at \"{s}\" failed verification", .{dep.url}),
        };
        acquired.manifest = verified.manifest;
        acquired.artifact_type = ".npkg";
    }
    return acquired;
}

// ---------------------------------------------------------------------------
// source identity と衝突検出
// ---------------------------------------------------------------------------

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// 宣言された source と既存 lock の source が矛盾しないか検査する。
/// kind の変更（registry→git などの暗黙切替）は `source_collision` で拒否
/// する。static→registry（中央化移行）は URL が同じなら内容が不変なため許可
/// する（SPECIFICATION.md §5.3）。
pub fn checkLockedSource(session: *Session, declared: lock_model.Source, locked: lock_model.Source, name: []const u8) Error!void {
    var compatible = declared.kind == locked.kind;
    // 静的 registry → 中央 registry の移行は artifact 不変のため許容する。
    if (!compatible) {
        const pair = [_]lock_model.SourceKind{ declared.kind, locked.kind };
        const static_registry = (pair[0] == .static and pair[1] == .registry) or (pair[0] == .registry and pair[1] == .static);
        if (static_registry and optEql(declared.url, locked.url)) compatible = true;
    }
    if (!compatible) {
        return session.fail(.source_collision, .manifest, name, "source of \"{s}\" changed from {s} to {s}", .{ name, @tagName(locked.kind), @tagName(declared.kind) });
    }
    switch (declared.kind) {
        .git => {
            const declared_commit = declared.commit orelse "";
            const locked_commit = locked.commit orelse "";
            // lock の完全 SHA が宣言 commit-ish の接頭辞一致なら同一 commit。
            if (!(std.mem.startsWith(u8, locked_commit, declared_commit) or std.mem.startsWith(u8, declared_commit, locked_commit))) {
                return session.fail(.source_collision, .repository, name, "git commit of \"{s}\" changed from {s} to {s}", .{ name, locked_commit, declared_commit });
            }
        },
        .http => {
            if (!optEql(declared.hash, locked.hash)) {
                return session.fail(.source_collision, .artifact, name, "http hash of \"{s}\" does not match the lock", .{name});
            }
        },
        .path => {
            if (!optEql(declared.path, locked.path)) {
                return session.fail(.source_collision, .manifest, name, "path of \"{s}\" changed", .{name});
            }
        },
        .registry, .static => {
            if (!optEql(declared.url, locked.url)) {
                return session.fail(.source_collision, .package, name, "registry url of \"{s}\" changed", .{name});
            }
        },
    }
    if (!optEql(declared.url, locked.url)) {
        return session.fail(.source_collision, .manifest, name, "source url of \"{s}\" changed", .{name});
    }
}

/// 複数依存宣言の source identity 衝突を検出する索引。
/// 同一 name に異なる identity を割り当てる宣言を `source_collision` で
/// 拒否する。同一 identity を別 name が指すのは alias として許容する。
/// key/value は `session.gpa` が所有し `deinit` で解放する。
pub const SourceIndex = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *SourceIndex, gpa: Allocator) void {
        var iterator = self.map.iterator();
        while (iterator.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.map.deinit(gpa);
    }

    /// name→identity の対応を登録する。既存登録と矛盾したら失敗。
    pub fn add(self: *SourceIndex, session: *Session, name: []const u8, source: lock_model.Source) Error!void {
        const gpa = session.gpa;
        const identity = try identityText(gpa, source);
        const owned_name = gpa.dupe(u8, name) catch |err| {
            gpa.free(identity);
            return err;
        };
        const gop = self.map.getOrPut(gpa, owned_name) catch |err| {
            gpa.free(identity);
            gpa.free(owned_name);
            return err;
        };
        if (gop.found_existing) {
            // 既存 key が残るため今回割当てた name/identity は破棄する。
            gpa.free(owned_name);
            const matches = std.mem.eql(u8, gop.value_ptr.*, identity);
            gpa.free(identity);
            if (!matches) {
                return session.fail(.source_collision, .manifest, name, "dependency \"{s}\" is bound to conflicting sources", .{name});
            }
            return;
        }
        gop.value_ptr.* = identity;
    }
};

/// source identity の正準表現（衝突判定用キー）。
pub fn identityText(gpa: Allocator, source: lock_model.Source) ![]u8 {
    return switch (source.kind) {
        .git => std.fmt.allocPrint(gpa, "git:{s}@{s}:{s}", .{ source.url orelse "", source.commit orelse "", source.path orelse "" }),
        .http => std.fmt.allocPrint(gpa, "http:{s}#{s}", .{ source.url orelse "", source.hash orelse "" }),
        .path => std.fmt.allocPrint(gpa, "path:{s}", .{source.path orelse ""}),
        .registry, .static => std.fmt.allocPrint(gpa, "{s}:{s}", .{ @tagName(source.kind), source.url orelse "" }),
    };
}

test {
    _ = @import("provider_test.zig");
}
