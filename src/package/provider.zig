const std = @import("std");
const builtin = @import("builtin");
const fetch = @import("fetch.zig");
const diag = @import("diagnostics.zig");
const lock_model = @import("lock_model.zig");
const environment = @import("environment.zig");
const manifest_mod = @import("manifest.zig");
const manifest_validate = @import("manifest_validate.zig");
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

/// path 依存の宣言 path が絶対 path か。POSIX の先頭 backslash は通常文字、
/// Windows の単一 rooted path は絶対 path。UNC は server/share が揃う場合だけ
/// 絶対扱いし、生成環境をまたぐ lock の文字列も正しく保持する。
pub fn isAbsoluteDepPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (builtin.os.tag != .windows) {
        // POSIX では `\\server\share` は backslash を含む正当な相対名。
        // drive-letter 判定と同じく UNC 解釈も Windows のみで行い、
        // POSIX 上の正規ファイル名を絶対 path と誤認しない。
        return std.fs.path.isAbsolute(path);
    }
    const double_separator = path.len >= 2 and isWindowsSeparator(path[0]) and isWindowsSeparator(path[1]);
    if (double_separator) return isCompleteWindowsUnc(path);
    return std.fs.path.isAbsoluteWindows(path);
}

fn isCompleteWindowsUnc(path: []const u8) bool {
    if (path.len < 5 or !isWindowsSeparator(path[0]) or !isWindowsSeparator(path[1])) return false;
    var i: usize = 2;
    while (i < path.len and isWindowsSeparator(path[i])) : (i += 1) {}
    const server_start = i;
    while (i < path.len and !isWindowsSeparator(path[i])) : (i += 1) {}
    if (i == server_start or i == path.len) return false;
    while (i < path.len and isWindowsSeparator(path[i])) : (i += 1) {}
    const share_start = i;
    while (i < path.len and !isWindowsSeparator(path[i])) : (i += 1) {}
    return i > share_start;
}

fn isWindowsSeparator(char: u8) bool {
    return char == '/' or char == '\\';
}

/// path 依存の取得。path は編集可能な参照であり、ディレクトリ内の
/// `nako.toml` を読んで manifest を返す。ネットワーク・git は使わないため
/// `--offline` でも動作する。Unicode path は byte 列としてそのまま扱う。
/// 絶対 path は `base_dir` と結合せずそのまま使う（spec §3.4.3）。
///
/// `base_dir` は manifest を置いたプロジェクトルート（依存宣言の基準 dir）。
pub fn acquirePath(
    session: *Session,
    dep: manifest_mod.PathDependency,
    base_dir: []const u8,
) Error!Acquired {
    const gpa = session.allocator();
    const dir_path = if (isAbsoluteDepPath(dep.path))
        try gpa.dupe(u8, dep.path)
    else
        try std.fs.path.join(gpa, &.{ base_dir, dep.path });
    const manifest_path = try std.fs.path.join(gpa, &.{ dir_path, "nako.toml" });
    const parsed = try readDependencyManifest(session, manifest_path, dep.name, "path");
    return .{
        // source の文字列は全て session arena が所有する（`dep` や lock の
        // allocator より長生きしなければならない契約）。
        .source = .{ .kind = .path, .path = try gpa.dupe(u8, dep.path), .mutable = dep.mutable },
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
        else => return mapManifestReadError(session, err, manifest_path, dep_name, dep_kind),
    };
    return parseDependencyManifest(session, bytes, manifest_path);
}

/// pinned workspace handle 相対の manifest 読み取り（git provider 用）。
/// `dir` は checkout（またはその subdir）の handle、`sub_path` はそこからの
/// `nako.toml` までの相対 path。診断表示には `display_path` を使う。
/// path 依存の digest 検証済み snapshot/tree からの manifest 読取でも
/// 共有するため公開する。
pub fn readDependencyManifestDir(session: *Session, dir: std.Io.Dir, sub_path: []const u8, display_path: []const u8, dep_name: []const u8, dep_kind: []const u8) Error!manifest_mod.Manifest {
    const gpa = session.allocator();
    const limit: std.Io.Limit = if (session.policy.max_bytes == 0) .unlimited else .limited(session.policy.max_bytes);
    const bytes = dir.readFileAlloc(session.io, sub_path, gpa, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return mapManifestReadError(session, err, display_path, dep_name, dep_kind),
    };
    return parseDependencyManifest(session, bytes, display_path);
}

fn mapManifestReadError(session: *Session, err: anyerror, manifest_path: []const u8, dep_name: []const u8, dep_kind: []const u8) Error {
    return switch (err) {
        error.FileNotFound => session.fail(.not_found, .manifest, manifest_path, "{s} dependency \"{s}\" has no nako.toml at \"{s}\"", .{ dep_kind, dep_name, manifest_path }),
        error.StreamTooLong => session.fail(.too_large, .manifest, manifest_path, "manifest at \"{s}\" exceeds the {d} byte limit", .{ manifest_path, session.policy.max_bytes }),
        else => session.fail(.network, .manifest, manifest_path, "cannot read \"{s}\": {s}", .{ manifest_path, @errorName(err) }),
    };
}

fn parseDependencyManifest(session: *Session, bytes: []const u8, manifest_path: []const u8) Error!manifest_mod.Manifest {
    var scratch = diag.List.init(session.gpa);
    defer scratch.deinit();
    return manifest_mod.parse(session.allocator(), bytes, session.diagSink(&scratch)) catch |err| switch (err) {
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
/// `workspace` はこの依存専用の作業 dir の pinned handle。`<workspace>/.git`
/// が既に存在する場合は clone を省略して再利用する（offline 時も object
/// があれば参照できる）。全ての Git subprocess はこの handle を cwd として
/// 起動する。`git -C <絶対path>` は cache root の rename/置換で path が別
/// tree を指し得るため使わず、`clean -ffdx` 等の破壊的操作は置換不能な
/// handle 相対の名前空間へ固定する。
///
/// `locked` に既存 lock の source を渡すと、宣言の `commit` が lock の
/// commit 接頭辞と一致する限り lock 側の完全 SHA を使う。リモート参照が
/// 動いても（tag の付け替え等）lock の commit を再解決しない。
pub fn acquireGit(
    session: *Session,
    dep: manifest_mod.GitDependency,
    workspace: std.Io.Dir,
    locked: ?lock_model.Source,
) Error!Acquired {
    const gpa = session.allocator();
    const io = session.io;

    // `dep.commit` は Git argv（fetch refspec・rev-parse 等）へそのまま
    // 渡る。`-` 始まりの値は option 注入（`--upload-pack=` 等）になる
    // ため、manifest/lock 側の検証とは別にここでも形式を必須化する。
    if (!manifest_validate.isCommitId(dep.commit)) {
        return session.fail(.invalid_source, .repository, dep.url, "invalid git commit-ish \"{s}\" for \"{s}\"", .{ dep.commit, dep.name });
    }

    var pinned: ?[]const u8 = null;
    if (locked) |source| {
        if (source.kind != .git or !optEql(source.url, dep.url) or !optEql(source.path, dep.path)) {
            return session.fail(.source_collision, .repository, dep.url, "git dependency \"{s}\" conflicts with the locked source", .{dep.name});
        }
        if (source.commit) |commit| {
            if (commit.len == 40 and manifest_validate.isCommitId(commit) and std.mem.startsWith(u8, commit, dep.commit)) {
                pinned = commit;
            }
        }
    }

    // `.git` が実 dir として開ける場合のみ既存 checkout とみなす。
    // symlink・gitfile・通常 file は再利用せず、clone で拒否される形に倒す。
    const has_checkout = blk: {
        var dot_git = workspace.openDir(io, ".git", .{ .follow_symlinks = false }) catch break :blk false;
        defer dot_git.close(io);
        const stat = dot_git.stat(io) catch break :blk false;
        break :blk stat.kind == .directory;
    };

    if (!has_checkout) {
        if (session.policy.offline) {
            return session.fail(.offline, .repository, dep.url, "offline mode: git repository \"{s}\" is not available locally", .{dep.url});
        }
        try checkGitUrlPolicy(session, dep.url);
        try gitRun(session, &.{ "git", "clone", "--quiet", "--no-checkout", dep.url, "." }, dep.url, .{ .cwd = workspace });
    } else {
        // 既存 checkout の origin が宣言 URL と一致するか検証し、別 repo の
        // checkout を再利用して別 URL の内容を読み違えないようにする。
        // `remote get-url`/`remote add` は config の読み書きのみで filter・
        // hook を起動しない（`.git/config` 自体は信頼しないが、URL の照合
        // は cache identity の確認に過ぎず、tree 内容は pin 済み object の
        // 直接展開で確定する）。
        try verifyCheckoutOrigin(session, workspace, dep);
    }

    // 共有 checkout の `.git/config`・refs・`info/attributes`・hooks は
    // 信頼しない。以降の全 Git コマンドは private gitdir（refs・HEAD・
    // FETCH_HEAD はこちらへ書く）＋ `GIT_OBJECT_DIRECTORY`（object db のみ
    // `.git/objects` から読む）で実行し、repository-local の filter・
    // hook・remote 設定が一切介入しない。object は content-addressed で
    // pin 済みのため、objects の差替えは pinned commit の内容を変えない。
    const git_env = try initPrivateGitdir(session, workspace, dep.url);
    defer environment.deleteTreeChecked(workspace, io, git_env.name) catch {};

    // 既存 checkout に commit-ish が無ければ、オンラインではリモートを
    // fetch してから再解決する（clone 後に追加された commit を拾う）。
    const full_commit = pinned orelse blk: {
        if (dep.commit.len < 40) {
            // 短縮 commit はローカル object だけでは確定しない。共有
            // checkout の objects/ へ同 prefix の別 commit を注入されると
            // 任意 tree を正規の完全 SHA として lock され得るため、origin
            // から取得して remote-tracking ref への到達性を確認してから
            // 確定する（既存 lock の完全 SHA 一致＝pinned は上で処理済み）。
            if (session.policy.offline) {
                return session.fail(.offline, .repository, dep.url, "offline mode: abbreviated commit \"{s}\" of \"{s}\" cannot be verified without fetching", .{ dep.commit, dep.url });
            }
            try checkGitUrlPolicy(session, dep.url);
            try fetchOriginRefsForVerify(session, workspace, git_env, dep.url);
            const commit = (try resolveCommit(session, workspace, git_env, dep.commit)) orelse
                return session.fail(.not_found, .repository, dep.url, "commit \"{s}\" of \"{s}\" was not found", .{ dep.commit, dep.url });
            if (!try remoteContainsCommit(session, gpa, workspace, git_env, commit)) {
                return session.fail(.not_found, .repository, dep.url, "abbreviated commit \"{s}\" of \"{s}\" is not reachable from origin", .{ dep.commit, dep.url });
            }
            break :blk commit;
        }
        if (try resolveCommit(session, workspace, git_env, dep.commit)) |commit| break :blk commit;
        if (session.policy.offline) {
            return session.fail(.offline, .repository, dep.url, "offline mode: commit-ish \"{s}\" of \"{s}\" is not available locally", .{ dep.commit, dep.url });
        }
        try checkGitUrlPolicy(session, dep.url);
        try gitRun(session, &.{ "git", "fetch", "--quiet", dep.url }, dep.url, .{ .cwd = workspace, .hooks_guard = true, .git_env = git_env });
        if (try resolveCommit(session, workspace, git_env, dep.commit)) |commit| break :blk commit;
        return session.fail(.not_found, .repository, dep.url, "commit \"{s}\" of \"{s}\" was not found", .{ dep.commit, dep.url });
    };

    // object が clone 済みか確認する。
    {
        const verify_arg = try std.fmt.allocPrint(gpa, "{s}^{{commit}}", .{full_commit});
        const result = try gitRunAllowFailure(session, gpa, &.{ "git", "cat-file", "-e", verify_arg }, .{ .cwd = workspace, .hooks_guard = true, .git_env = git_env });
        if (!result.succeeded) {
            if (session.policy.offline) {
                return session.fail(.offline, .repository, dep.url, "offline mode: commit {s} of \"{s}\" is not available locally", .{ full_commit, dep.url });
            }
            try checkGitUrlPolicy(session, dep.url);
            // 動的 revision は `--` の後へ渡し、将来の呼出し変更でも
            // refspec が option として解釈されないようにする。
            try gitRun(session, &.{ "git", "fetch", "--quiet", dep.url, "--", full_commit }, dep.url, .{ .cwd = workspace, .hooks_guard = true, .git_env = git_env });
            const retry = try gitRunAllowFailure(session, gpa, &.{ "git", "cat-file", "-e", verify_arg }, .{ .cwd = workspace, .hooks_guard = true, .git_env = git_env });
            if (!retry.succeeded) {
                return session.fail(.not_found, .repository, dep.url, "commit {s} of \"{s}\" was not found", .{ full_commit, dep.url });
            }
        }
    }
    // `git checkout`/`git clean` は repository-local の smudge filter・
    // attributes・hooks を呼び得るため使わない。pinned commit の tree を
    // `ls-tree`/`cat-file`（object read のみ・filter を一切起動しない）
    // で直接展開する。展開前に `.git` と private gitdir 以外の管理対象外
    // entry を消去し、前回の tree 残骸・差し込まれた file を残さない。
    try wipeWorkspaceTree(session, workspace, dep.url, git_env.name);
    try extractCommitTree(session, gpa, workspace, git_env, full_commit, dep.url);

    // `dep.path` は checkout 内の subdirectory。`..`・絶対 path などで
    // checkout 境界の外へ出る指定は拒否する（npkg の規範 path 規則と同じ）。
    if (dep.path) |sub| {
        if (!npkg_files.isCanonicalPath(sub)) {
            return session.fail(.invalid_source, .repository, sub, "git dependency path \"{s}\" is not a canonical repository-relative path", .{sub});
        }
    }
    const manifest_dir = if (dep.path) |sub| try std.fs.path.join(gpa, &.{ sub, "nako.toml" }) else "nako.toml";
    const manifest_display = try std.fmt.allocPrint(gpa, "git:{s}/{s}", .{ dep.url, manifest_dir });
    const parsed = try readDependencyManifestDir(session, workspace, manifest_dir, manifest_display, dep.name, "git");
    // source の文字列は全て session arena が所有する。`dep`・lock 由来の
    // pinned commit もここで複製する。
    return .{
        .source = .{
            .kind = .git,
            .url = try gpa.dupe(u8, dep.url),
            .commit = try gpa.dupe(u8, full_commit),
            .path = if (dep.path) |sub| try gpa.dupe(u8, sub) else null,
        },
        .manifest = parsed,
    };
}

/// Git の network fetch も HTTP provider と同じ平文通信 policy に従う。
/// local/file・SSH など HTTP 以外の Git URL は対象外。
fn checkGitUrlPolicy(session: *Session, url: []const u8) Error!void {
    if (session.policy.allow_plaintext_http) return;
    if (!std.ascii.startsWithIgnoreCase(url, "http://")) return;
    const uri = std.Uri.parse(url) catch return session.fail(.invalid_source, .repository, url, "invalid git http url: {s}", .{url});
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return;
    const host_component = uri.host orelse return session.fail(.invalid_source, .repository, url, "git http url has no host: {s}", .{url});
    const host = switch (host_component) {
        .raw, .percent_encoded => |text| text,
    };
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.ascii.endsWithIgnoreCase(host, ".localhost")) return;
    if (std.Io.net.Ip4Address.parse(host, 0)) |ip4| {
        if (ip4.bytes[0] == 127) return;
    } else |_| {}
    const ipv6_host = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    if (std.Io.net.Ip6Address.parse(ipv6_host, 0)) |ip6| {
        if (std.mem.eql(u8, &ip6.bytes, &std.Io.net.Ip6Address.loopback(0).bytes)) return;
    } else |_| {}
    return session.fail(.invalid_source, .repository, url, "plaintext http git url \"{s}\" is only allowed for loopback hosts (set allow_plaintext_http to opt in)", .{url});
}

/// commit-ish（7–40 桁 hex）を完全な commit SHA へ解決する。
/// `--disambiguate` で object を列挙するため、prefix と同名の移動した
/// tag/branch に衝突して誤った参照を選ばない。
/// ローカル object に見つからない場合は null を返す（失敗は記録しない。
/// 呼出し側が fetch 後の再試行や失敗分類を行う）。prefix が複数 commit
/// へ曖昧な場合は `invalid_source` として記録して失敗する。
fn resolveCommit(session: *Session, workspace: std.Io.Dir, git_env: GitEnv, commitish: []const u8) Error!?[]const u8 {
    const gpa = session.allocator();
    const arg = try std.fmt.allocPrint(gpa, "--disambiguate={s}", .{commitish});
    const result = try gitRunAllowFailure(session, gpa, &.{ "git", "rev-parse", arg }, .{ .cwd = workspace, .hooks_guard = true, .git_env = git_env });
    if (!result.succeeded) return null;
    var commit: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const candidate = std.mem.trim(u8, line, " \t\r");
        if (candidate.len != 40 or !manifest_validate.isCommitId(candidate)) continue;
        const type_result = try gitRunAllowFailure(session, gpa, &.{ "git", "cat-file", "-t", candidate }, .{ .cwd = workspace, .hooks_guard = true, .git_env = git_env });
        if (!type_result.succeeded) continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, type_result.stdout, " \t\r\n"), "commit")) continue;
        if (commit != null) {
            return session.fail(.invalid_source, .repository, commitish, "commit prefix \"{s}\" is ambiguous", .{commitish});
        }
        commit = try gpa.dupe(u8, candidate);
    }
    return commit;
}

/// 短縮 commit 検証用に remote-tracking ref 名前空間を remote 真値へ
/// 更新する。`+` 強制 refspec と `--prune` で、事前に細工された ref を
/// 除去し現在の remote の値に揃える。tag は private な
/// `refs/lnako-verify-tags/` へ取得する。URL は remote 設定（共有
/// checkout の `.git/config` は private gitdir で読まないため参照
/// されない）ではなく宣言 URL を引数で渡す。refs は全て private
/// gitdir へ書かれる。
fn fetchOriginRefsForVerify(session: *Session, workspace: std.Io.Dir, git_env: GitEnv, url: []const u8) Error!void {
    try gitRun(session, &.{
        "git",                                 "fetch",                                 "--quiet", "--prune", url,
        "+refs/heads/*:refs/remotes/origin/*", "+refs/tags/*:refs/lnako-verify-tags/*",
    }, url, .{ .cwd = workspace, .hooks_guard = true, .git_env = git_env });
}

/// `commit` が remote-tracking ref のいずれかから到達可能か。
/// `fetchOriginRefsForVerify` 直後の private gitdir 内 ref だけを見る
/// ため、cache 内へ細工した object・ref があっても remote 由来の履歴に
/// 含まれない commit はここで落とせる。
fn remoteContainsCommit(session: *Session, gpa: Allocator, workspace: std.Io.Dir, git_env: GitEnv, commit: []const u8) Error!bool {
    const result = try gitRunAllowFailure(session, gpa, &.{
        "git",                  "for-each-ref",            "--contains", commit,
        "refs/remotes/origin/", "refs/lnako-verify-tags/",
    }, .{ .cwd = workspace, .hooks_guard = true, .git_env = git_env });
    if (!result.succeeded) return false;
    return std.mem.trim(u8, result.stdout, " \t\r\n").len > 0;
}

/// 既存 checkout の origin URL が宣言 URL と一致するか検証する。
/// `remote get-url`/`remote add` は `.git/config` の読み書きのみで、
/// filter driver・hook・attributes を起動しない。URL 照合は cache
/// identity の確認であり、tree 内容の正当性は pin 済み commit の
/// object 直接展開が保証する。
fn verifyCheckoutOrigin(session: *Session, workspace: std.Io.Dir, dep: manifest_mod.GitDependency) Error!void {
    const gpa = session.allocator();
    const result = try gitRunAllowFailure(session, gpa, &.{ "git", "remote", "get-url", "origin" }, .{ .cwd = workspace, .hooks_guard = true });
    if (!result.succeeded) {
        // origin remote が無い checkout には宣言 URL を設定しておく。
        try gitRun(session, &.{ "git", "remote", "add", "origin", dep.url }, dep.url, .{ .cwd = workspace, .hooks_guard = true });
        return;
    }
    const existing = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!try gitUrlEql(gpa, existing, dep.url)) {
        return session.fail(.source_collision, .repository, dep.url, "checkout for \"{s}\" belongs to a different repository (origin is \"{s}\")", .{ dep.url, existing });
    }
}

fn gitUrlEql(gpa: Allocator, a: []const u8, b: []const u8) Allocator.Error!bool {
    const windows_paths = builtin.os.tag == .windows;
    return switch (try classifyGitUrl(gpa, a, windows_paths)) {
        .local => |pa| switch (try classifyGitUrl(gpa, b, windows_paths)) {
            .local => |pb| std.mem.eql(u8, pa, pb),
            .remote => false,
        },
        .remote => |ra| switch (try classifyGitUrl(gpa, b, windows_paths)) {
            .local => false,
            .remote => |rb| std.mem.eql(u8, ra, rb),
        },
    };
}

const GitUrlKind = union(enum) { local: []const u8, remote: []const u8 };

fn classifyGitUrl(gpa: Allocator, url: []const u8, windows_paths: bool) Allocator.Error!GitUrlKind {
    if (std.mem.startsWith(u8, url, "file://")) {
        const rest = url["file://".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const authority = rest[0..slash];
        // `file://\\host\share`（UNC 形式）や `file://C:/x`・`file://D:\x`
        // のような Windows ローカル表現は authority ではなく path とみなす。
        const windows_local = windows_paths and
            (std.mem.startsWith(u8, rest, "\\\\") or
                (authority.len >= 2 and std.ascii.isAlphabetic(authority[0]) and authority[1] == ':' and
                    (authority.len == 2 or authority[2] == '\\')));
        if (authority.len == 0 or std.ascii.eqlIgnoreCase(authority, "localhost") or windows_local) {
            // file: URL の path は URI 規則（percent encoding）を復号し、
            // OS の path 表現へ正規化してから bare path と比較する。
            const raw_path = if (windows_local) rest else rest[slash..];
            const decoded = if (std.mem.indexOfScalar(u8, raw_path, '%') != null)
                std.Uri.percentDecodeBackwards(try gpa.alloc(u8, raw_path.len), raw_path)
            else
                raw_path;
            return .{ .local = try normalizeLocalGitPath(gpa, decoded, windows_paths) };
        }
        // authority を持つ file: URL はローカル path ではない（`file://h/s`
        // が bare path `h/s` や `s` と同一視されると別 repo を誤認する）。
        return .{ .remote = normalizeRemoteGitUrl(url) };
    }
    // `\\host\share`・`\\?\D:\x`（UNC / extended-length path）はローカル。
    // scp 判定より先に見る（`\\?\D:` の `:` を scp の `:` と誤認しない）。
    if (std.mem.startsWith(u8, url, "\\\\")) {
        return .{ .local = try normalizeLocalGitPath(gpa, url, windows_paths) };
    }
    if (std.mem.indexOf(u8, url, "://") != null or isScpLikeGitUrl(url)) {
        return .{ .remote = normalizeRemoteGitUrl(url) };
    }
    return .{ .local = try normalizeLocalGitPath(gpa, url, windows_paths) };
}

/// ローカル path の正規化。末尾 `/` を除く。Windows では `\`→`/`、
/// `/C:/x`→`C:/x`、drive letter の大文字化を行い、file: URL と bare
/// path の表現差を吸収する。POSIX では `\` は正当なファイル名文字の
/// ため置換しない。`windows_paths` は呼出し OS の判定結果を受け取り、
/// テストから Windows 分岐を検証できるようにする。
fn normalizeLocalGitPath(gpa: Allocator, path: []const u8, windows_paths: bool) Allocator.Error![]const u8 {
    // POSIX では `\` は正当なファイル名文字のため末尾 `/` だけを除く。
    if (!windows_paths) return std.mem.trimEnd(u8, path, "/");
    // 末尾 `\` も区切り文字として扱うため、変換してから末尾 `/` を除く。
    const buf = try gpa.dupe(u8, path);
    std.mem.replaceScalar(u8, buf, '\\', '/');
    var end = buf.len;
    while (end > 0 and buf[end - 1] == '/') end -= 1;
    var text: []u8 = buf[0..end];
    // extended-length `\\?\`・device `\\.\` 前置は除去する。
    // `\\?\UNC\` は通常 UNC `\\` 形へ畳み込む（`//?/UNC/s/s` → `//s/s`）。
    if (std.ascii.startsWithIgnoreCase(text, "//?/UNC/") or std.ascii.startsWithIgnoreCase(text, "//./UNC/")) {
        std.mem.copyForwards(u8, text[2..], text[8..]);
        text = text[0 .. text.len - 6];
    } else if (std.mem.startsWith(u8, text, "//?/") or std.mem.startsWith(u8, text, "//./")) {
        text = text[4..];
    }
    // file: URL の Windows drive 表現 `/C:/x` → `C:/x`。
    if (text.len >= 3 and text[0] == '/' and std.ascii.isAlphabetic(text[1]) and text[2] == ':') {
        text = text[1..];
    }
    // drive letter は大小文字を区別しない。
    if (text.len >= 2 and std.ascii.isAlphabetic(text[0]) and text[1] == ':') {
        text[0] = std.ascii.toUpper(text[0]);
    }
    return text;
}

/// scp 形式 `user@host:path` の判定。最初の `/` より前に `:` がある
/// 形式をリモートとみなす（Windows drive letter `C:` はローカル path）。
fn isScpLikeGitUrl(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    if (colon == 0) return false;
    if (colon == 1 and std.ascii.isAlphabetic(url[0])) return false;
    if (std.mem.indexOfScalar(u8, url, '/')) |slash| {
        if (slash < colon) return false;
    }
    return true;
}

/// リモート URL の表記揺れ吸収。末尾 `/` とホスティング慣例の `.git`
/// 接尾辞を除く。ローカル path には適用しない。
fn normalizeRemoteGitUrl(url: []const u8) []const u8 {
    var text = std.mem.trimEnd(u8, url, "/");
    if (std.mem.endsWith(u8, text, ".git")) text = text[0 .. text.len - ".git".len];
    return text;
}

const GitResult = struct {
    succeeded: bool,
    stdout: []const u8,
    stderr: []const u8,
};

/// 共有 checkout の object database だけを参照するための隔離 gitdir。
/// `.git/config`・refs・`info/attributes`・hooks は一切参照せず、refs・
/// HEAD・`FETCH_HEAD` 等の metadata は全て private gitdir（実行ごとの
/// ランダム名）に置く。commit は content-addressed で pin 済みのため、
/// object store の改竄・config 書換は tree 内容に影響しない。
const GitEnv = struct {
    /// private gitdir の絶対 path（`GIT_DIR`）。
    git_dir: []const u8,
    /// `<workspace>/.git/objects` の絶対 path（`GIT_OBJECT_DIRECTORY`）。
    object_dir: []const u8,
    /// workspace 内の gitdir 名（掃除・wipe 除外用）。
    name: []const u8,
};

/// private gitdir を workspace 内へ作る。HEAD・refs/ は `is_git_directory`
/// が要求する最小構成だけ置き、config は一切書かない（fetch は URL・
/// refspec を全て引数で渡すため不要）。ランダム名により事前配置は不能。
fn initPrivateGitdir(session: *Session, workspace: std.Io.Dir, url: []const u8) Error!GitEnv {
    const gpa = session.allocator();
    const io = session.io;
    var rand: [8]u8 = undefined;
    io.random(&rand);
    const name = try std.fmt.allocPrint(gpa, ".lnako-git-{x}", .{rand});
    var git_dir = environment.openManagedChildDir(workspace, io, name, true) catch |err| switch (err) {
        else => return session.fail(.unavailable, .repository, url, "cannot create private gitdir in checkout workspace: {s}", .{@errorName(err)}),
    };
    defer git_dir.close(io);
    git_dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/lnako\n" }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return session.fail(.unavailable, .repository, url, "cannot initialize private gitdir: {s}", .{@errorName(err)}),
    };
    git_dir.createDirPath(io, "refs") catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return session.fail(.unavailable, .repository, url, "cannot initialize private gitdir: {s}", .{@errorName(err)}),
    };
    const git_dir_abs = workspace.realPathFileAlloc(io, name, gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return session.fail(.unavailable, .repository, url, "cannot resolve private gitdir path: {s}", .{@errorName(err)}),
    };
    const object_dir = workspace.realPathFileAlloc(io, ".git/objects", gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return session.fail(.unavailable, .repository, url, "cached checkout has no object directory: {s}", .{@errorName(err)}),
    };
    return .{ .git_dir = git_dir_abs, .object_dir = object_dir, .name = name };
}
/// provider 内の filesystem error を `fetch.Error` へ写像する。
fn mapProviderFs(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.ProviderUnavailable,
    };
}

/// `gitRunAllowFailure` の実行場所と保護指定。`cwd` は subprocess の
/// 作業 dir を pinned handle で指定し、起動後の path 解決に path
/// 文字列を使わない（POSIX では `fchdir` で固定。Windows では handle
/// が開かれている間は対象 dir の rename/置換が拒否される）。
const GitRunOptions = struct {
    /// subprocess の cwd。null なら親プロセスの cwd を継承する。
    cwd: ?std.Io.Dir = null,
    /// checkout 配下のコマンドで hooks・fsmonitor を無効化する。
    /// `core.hooksPath` をプラットフォームの null デバイスへ固定する
    /// （clone 自体は新規 repo を作るだけで共有 checkout を信頼する
    /// 必要がないため対象外）。
    hooks_guard: bool = false,
    /// private gitdir 環境。設定すると `GIT_DIR`/`GIT_OBJECT_DIRECTORY`
    /// で共有 checkout の repository config・refs を一切参照しない。
    git_env: ?GitEnv = null,
};

/// git 子プロセス用の環境を構築する。`git_env` 指定時は private gitdir
/// へ誘導し `.git/config` は参照されなくなる。fetch 系が外部コマンドを
/// 呼び得る key（credential helper・pack hook・submodule 再帰）は環境
/// config でも無効化しておく（private gitdir に config file を作ら
/// なくても、想定外の経路で紛れ込む key を遮るための防衛）。
fn gitEnvMap(gpa: Allocator, git_env: ?GitEnv) Error!?std.process.Environ.Map {
    var env_map = try fetch.sanitizedGitEnvMap(gpa);
    errdefer if (env_map) |*m| m.deinit();
    if (env_map) |*m| {
        try m.put("GIT_CONFIG_NOSYSTEM", "1");
        try m.put("GIT_CONFIG_GLOBAL", if (builtin.os.tag == .windows) "NUL" else "/dev/null");
        // cached repo に混入した refs/replace/* は pin 済み commit の実体を
        // 別 object へ見せ替え得るため、参照・展開を含む全コマンドで
        // replace object 解決を無効化する。
        try m.put("GIT_NO_REPLACE_OBJECTS", "1");
        // fetch/clone も対象に、credential helper・pack hook・submodule
        // 再帰・対話 prompt を全コマンドで遮る。環境 config は file
        // config より優先され、credential.helper の空値は helper 一覧
        // 全体を reset する。
        try m.put("GIT_SSH_COMMAND", "ssh");
        try m.put("GIT_TERMINAL_PROMPT", "0");
        try m.put("GIT_CONFIG_COUNT", "4");
        try m.put("GIT_CONFIG_KEY_0", "credential.helper");
        try m.put("GIT_CONFIG_VALUE_0", "");
        try m.put("GIT_CONFIG_KEY_1", "uploadpack.packObjectsHook");
        try m.put("GIT_CONFIG_VALUE_1", "");
        try m.put("GIT_CONFIG_KEY_2", "fetch.recurseSubmodules");
        try m.put("GIT_CONFIG_VALUE_2", "false");
        try m.put("GIT_CONFIG_KEY_3", "submodule.recurse");
        try m.put("GIT_CONFIG_VALUE_3", "false");
        if (git_env) |env| {
            try m.put("GIT_DIR", env.git_dir);
            try m.put("GIT_OBJECT_DIRECTORY", env.object_dir);
        }
    }
    return env_map;
}

fn gitRunAllowFailure(session: *Session, gpa: Allocator, argv: []const []const u8, options: GitRunOptions) Error!GitResult {
    var env_map = try gitEnvMap(gpa, options.git_env);
    defer if (env_map) |*m| m.deinit();

    // Cached checkout の .git/config は信頼しない。各コマンドに command
    // config で hooks と fsmonitor を無効化する。hooksPath に workspace 内
    // dir の相対名を使うと、dir 作成後・checkout 前に同名 dir を hook 入り
    // へ置換される余地があるため、プラットフォームの null デバイスへ固定
    // する（hooksPath が dir でなければ hook は一切解決されず、置換不能
    // な namespace になる）。
    var protected_argv: ?[][]const u8 = null;
    if (options.hooks_guard) {
        const safe_argv = try gpa.alloc([]const u8, argv.len + 4);
        safe_argv[0] = argv[0];
        safe_argv[1] = "-c";
        safe_argv[2] = if (builtin.os.tag == .windows) "core.hooksPath=NUL" else "core.hooksPath=/dev/null";
        safe_argv[3] = "-c";
        safe_argv[4] = "core.fsmonitor=false";
        @memcpy(safe_argv[5..], argv[1..]);
        protected_argv = safe_argv;
    }
    const result = std.process.run(gpa, session.io, .{
        .argv = if (protected_argv) |safe| safe else argv,
        .cwd = if (options.cwd) |dir| .{ .dir = dir } else .inherit,
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
fn gitRun(session: *Session, argv: []const []const u8, target: ?[]const u8, options: GitRunOptions) Error!void {
    const gpa = session.allocator();
    const result = try gitRunAllowFailure(session, gpa, argv, options);
    if (!result.succeeded) {
        const detail = std.mem.trim(u8, result.stderr, " \t\r\n");
        return session.fail(.network, .repository, target orelse argv[argv.len - 1], "git command failed: {s}", .{detail});
    }
}

/// workspace 直下の `.git` と `keep_name`（private gitdir）以外の全 entry
/// を消去する。tree 展開前に呼び、前回 tree・差し込まれた file を残さない。
/// `clean -ffdx` の代替だが、subprocess への引数渡しを介さず pinned
/// handle 相対だけで完結する。
fn wipeWorkspaceTree(session: *Session, workspace: std.Io.Dir, url: []const u8, keep_name: []const u8) Error!void {
    const io = session.io;
    var top = workspace.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        else => return session.fail(.unavailable, .repository, url, "cannot enumerate checkout workspace: {s}", .{@errorName(err)}),
    };
    defer top.close(io);
    var it = top.iterate();
    while (it.next(io) catch |err| switch (err) {
        else => return session.fail(.unavailable, .repository, url, "cannot enumerate checkout workspace: {s}", .{@errorName(err)}),
    }) |entry| {
        if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, keep_name)) continue;
        environment.deleteTreeChecked(workspace, io, entry.name) catch |err| switch (err) {
            else => return session.fail(.unavailable, .repository, url, "cannot remove entry \"{s}\" in checkout workspace: {s}", .{ entry.name, @errorName(err) }),
        };
    }
}

const GitTreeEntry = struct {
    mode: u32,
    /// tree entry の object SHA（40 桁 hex）。
    sha: []const u8,
    /// repo 内 path（`/` 区切り）。
    path: []const u8,

    const Kind = enum { blob, link, gitlink };
    fn kind(self: GitTreeEntry) Kind {
        return switch (self.mode) {
            0o120000 => .link,
            0o160000 => .gitlink,
            else => .blob,
        };
    }
};

/// `ls-tree` の path が workspace 内の安全な相対 path か。
/// `..`・絶対 path・制御文字を拒否し、Windows では区切りと見做される
/// `\` も拒否する（tree に `\` 名は存在し得るが、展開側が境界外へ出る
/// 解釈を防ぐ）。
fn validGitTreePath(path: []const u8) bool {
    if (path.len == 0) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
        if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, component, '\\') != null) return false;
        if (std.mem.indexOfAny(u8, component, ":\x00") != null) return false;
    }
    return true;
}

/// `git ls-tree -r -z` の出力を entry 列へ parse する。
fn parseLsTree(gpa: Allocator, bytes: []const u8, session: *Session, url: []const u8, commit: []const u8) Error!std.ArrayListUnmanaged(GitTreeEntry) {
    var entries: std.ArrayListUnmanaged(GitTreeEntry) = .empty;
    var it = std.mem.splitScalar(u8, bytes, 0);
    while (it.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse
            return session.fail(.unavailable, .repository, url, "malformed ls-tree record in commit {s}", .{commit});
        const path = try gpa.dupe(u8, record[tab + 1 ..]);
        if (!validGitTreePath(path)) {
            return session.fail(.invalid_source, .repository, url, "commit {s} contains a non-canonical path \"{s}\"", .{ commit, path });
        }
        var meta = std.mem.tokenizeScalar(u8, record[0..tab], ' ');
        const mode_text = meta.next() orelse
            return session.fail(.unavailable, .repository, url, "malformed ls-tree record in commit {s}", .{commit});
        const mode = std.fmt.parseInt(u32, mode_text, 8) catch
            return session.fail(.unavailable, .repository, url, "malformed ls-tree mode in commit {s}", .{commit});
        _ = meta.next() orelse
            return session.fail(.unavailable, .repository, url, "malformed ls-tree record in commit {s}", .{commit});
        const sha = meta.next() orelse
            return session.fail(.unavailable, .repository, url, "malformed ls-tree record in commit {s}", .{commit});
        if (!manifest_validate.isCommitId(sha)) {
            return session.fail(.unavailable, .repository, url, "malformed ls-tree object id in commit {s}", .{commit});
        }
        try entries.append(gpa, .{ .mode = mode, .sha = try gpa.dupe(u8, sha), .path = path });
    }
    return entries;
}

/// tree 内 path の親 dir 成分を順に no-follow で開き、無ければ作成する。
/// `createDirPath` は中間 symlink を追従して境界外へ出る余地があるため
/// 使わない（zip 展開と同じ防御）。
fn openGitTreeDir(parent: std.Io.Dir, io: std.Io, name: []const u8) Error!std.Io.Dir {
    for (0..8) |_| {
        const stat = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                parent.createDir(io, name, .default_dir) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => continue,
                    else => return mapProviderFs(create_err),
                };
                continue;
            },
            else => return mapProviderFs(err),
        };
        if (stat.kind != .directory) return error.InvalidSource;
        return parent.openDir(io, name, .{ .follow_symlinks = false }) catch |err| return mapProviderFs(err);
    }
    return error.InvalidSource;
}

/// `path` の中間成分を開いて末端の親 dir を返す。`path` 自身は作らない。
/// 返り値の所有権は呼出し側へ移る（close は呼出し側）。エラー時だけ
/// 中間 handle を閉じるため、閉じるのは `return` 以外の経路に限る。
fn openGitEntryParent(io: std.Io, workspace: std.Io.Dir, path: []const u8) Error!std.Io.Dir {
    var current = workspace;
    var owns_current = false;
    errdefer if (owns_current) current.close(io);
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, index, '/')) |slash| {
        const component = path[index..slash];
        const next = try openGitTreeDir(current, io, component);
        if (owns_current) current.close(io);
        current = next;
        owns_current = true;
        index = slash + 1;
    }
    if (owns_current) return current;
    return workspace.openDir(io, ".", .{}) catch |err| return mapProviderFs(err);
}

/// pinned commit の tree を `git ls-tree` + `git cat-file --batch` で直接
/// 展開する。`git checkout`/`clean`/`archive` は repository-local の
/// config（smudge filter・attributes・`tar.*.command`）を解釈し得るため
/// 使わず、object read のみの plumbing で tree を生成する。`--batch` の
/// stdin は private gitdir 内へ書いた sha 一覧 file から読ませ、出力は
/// ストリームで file へ写す（blob byte をメモリへ一括展開しない）。
fn extractCommitTree(session: *Session, gpa: Allocator, workspace: std.Io.Dir, git_env: GitEnv, commit: []const u8, url: []const u8) Error!void {
    const io = session.io;
    const listing = try gitRunAllowFailure(session, gpa, &.{
        "git", "ls-tree", "-r", "-z", commit,
    }, .{ .cwd = workspace, .hooks_guard = true, .git_env = git_env });
    if (!listing.succeeded) {
        return session.fail(.not_found, .repository, url, "cannot list the tree of commit {s}", .{commit});
    }
    const entries = try parseLsTree(gpa, listing.stdout, session, url, commit);
    if (entries.items.len == 0) return;

    // `cat-file --batch` の入力 sha 一覧を private gitdir 内へ作る。
    var git_dir = workspace.openDir(io, git_env.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        else => return session.fail(.unavailable, .repository, url, "cannot open private gitdir: {s}", .{@errorName(err)}),
    };
    defer git_dir.close(io);
    {
        var list_file = git_dir.createFile(io, "sha-list", .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return session.fail(.unavailable, .repository, url, "cannot prepare object list for commit {s}: {s}", .{ commit, @errorName(err) }),
        };
        defer list_file.close(io);
        var write_buffer: [4096]u8 = undefined;
        var file_writer = list_file.writer(io, &write_buffer);
        for (entries.items) |entry| {
            if (entry.kind() == .gitlink) continue;
            file_writer.interface.print("{s}\n", .{entry.sha}) catch |err| switch (err) {
                error.WriteFailed => return session.fail(.unavailable, .repository, url, "cannot write object list for commit {s}", .{commit}),
            };
        }
        file_writer.interface.flush() catch |err| switch (err) {
            error.WriteFailed => return session.fail(.unavailable, .repository, url, "cannot write object list for commit {s}", .{commit}),
        };
    }

    var env_map = try gitEnvMap(gpa, git_env);
    defer if (env_map) |*m| m.deinit();
    var list_input = git_dir.openFile(io, "sha-list", .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return session.fail(.unavailable, .repository, url, "cannot read object list for commit {s}: {s}", .{ commit, @errorName(err) }),
    };
    defer list_input.close(io);
    // `--batch` の応答は private gitdir 内の file へ書かせる。pipe の
    // streaming reader 経由にすると応答の境界管理が pipe buffer に依存
    // するため、regular file へ退避してから positional reader で解析する。
    var out_file = git_dir.createFile(io, "batch-out", .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return session.fail(.unavailable, .repository, url, "cannot prepare object output for commit {s}: {s}", .{ commit, @errorName(err) }),
    };
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "cat-file", "--batch" },
        .cwd = .{ .dir = workspace },
        .environ_map = if (env_map) |*m| m else null,
        .stdin = .{ .file = list_input },
        .stdout = .{ .file = out_file },
        .stderr = .ignore,
        .create_no_window = true,
    }) catch |err| {
        out_file.close(io);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound => session.fail(.unavailable, .repository, "git", "git executable is required for git dependencies but was not found", .{}),
            error.Canceled => error.Canceled,
            else => mapProviderFs(err),
        };
    };
    out_file.close(io);
    defer child.kill(io);
    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return session.fail(.unavailable, .repository, url, "cannot wait for git cat-file during commit {s}: {s}", .{ commit, @errorName(err) }),
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            return session.fail(.unavailable, .repository, url, "git cat-file failed while extracting commit {s}", .{commit});
        },
        else => return session.fail(.unavailable, .repository, url, "git cat-file did not exit cleanly for commit {s}", .{commit}),
    }

    var batch_file = git_dir.openFile(io, "batch-out", .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return session.fail(.unavailable, .repository, url, "cannot read object output for commit {s}: {s}", .{ commit, @errorName(err) }),
    };
    defer batch_file.close(io);
    var read_buffer: [8192]u8 = undefined;
    var batch_reader = batch_file.reader(io, &read_buffer);
    const reader = &batch_reader.interface;
    for (entries.items) |entry| {
        if (entry.kind() == .gitlink) continue;
        const header_line = reader.takeDelimiterInclusive('\n') catch
            return session.fail(.unavailable, .repository, url, "unexpected end of git cat-file output for commit {s}", .{commit});
        const header = std.mem.trimEnd(u8, header_line, "\n");
        var meta = std.mem.tokenizeScalar(u8, header, ' ');
        const echoed_sha = meta.next() orelse "";
        const object_type = meta.next() orelse "";
        const size_text = meta.next() orelse "";
        if (!std.mem.eql(u8, echoed_sha, entry.sha) or !std.mem.eql(u8, object_type, "blob")) {
            return session.fail(.unavailable, .repository, url, "missing object {s} in checkout for commit {s}", .{ entry.sha, commit });
        }
        const size = std.fmt.parseInt(u64, size_text, 10) catch
            return session.fail(.unavailable, .repository, url, "malformed git cat-file header in commit {s}", .{commit});
        var parent = try openGitEntryParent(io, workspace, entry.path);
        defer parent.close(io);
        const leaf = entry.path[(if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |i| i + 1 else 0)..];
        if (entry.kind() == .link) {
            // symlink blob の内容は link target 文字列。
            const target = reader.readAlloc(gpa, @intCast(size)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return session.fail(.unavailable, .repository, url, "cannot read symlink blob {s} in commit {s}", .{ entry.path, commit }),
            };
            defer gpa.free(target);
            try consumeBatchNewline(reader, session, url, commit);
            if (builtin.os.tag == .windows) {
                // core.symlinks=false の checkout と同じく target 文字列を
                // 内容とする通常 file を置く。
                var file = parent.createFile(io, leaf, .{ .exclusive = true }) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return session.fail(.unavailable, .repository, url, "cannot create \"{s}\" in checkout: {s}", .{ entry.path, @errorName(err) }),
                };
                defer file.close(io);
                file.writeStreamingAll(io, target) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return session.fail(.unavailable, .repository, url, "cannot write \"{s}\" in checkout: {s}", .{ entry.path, @errorName(err) }),
                };
            } else {
                parent.symLink(io, target, leaf, .{ .is_directory = false }) catch |err| return mapProviderFs(err);
            }
        } else {
            var file = parent.createFile(io, leaf, .{ .exclusive = true }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return session.fail(.unavailable, .repository, url, "cannot create \"{s}\" in checkout: {s}", .{ entry.path, @errorName(err) }),
            };
            defer file.close(io);
            try streamBlobToFile(reader, file, io, size, session, url, commit, entry.path);
            try consumeBatchNewline(reader, session, url, commit);
            if (entry.mode == 0o100755 and std.Io.File.Permissions.has_executable_bit) {
                file.setPermissions(io, .executable_file) catch {};
            }
        }
    }
    // gitlink（submodule 参照）は未初期化 checkout と同じく空 dir を作る。
    for (entries.items) |entry| {
        if (entry.kind() != .gitlink) continue;
        var parent = try openGitEntryParent(io, workspace, entry.path);
        defer parent.close(io);
        const leaf = entry.path[(if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |i| i + 1 else 0)..];
        parent.createDir(io, leaf, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return mapProviderFs(err),
        };
    }
}

/// `cat-file --batch` の各応答末尾の改行 1 byte を読み捨てる。
fn consumeBatchNewline(reader: *std.Io.Reader, session: *Session, url: []const u8, commit: []const u8) Error!void {
    var newline: [1]u8 = undefined;
    reader.readSliceAll(&newline) catch
        return session.fail(.unavailable, .repository, url, "truncated git cat-file output for commit {s}", .{commit});
}

/// blob の byte 列を 8KB ずつ file へ写す。巨大 blob をメモリへ展開しない。
fn streamBlobToFile(reader: *std.Io.Reader, file: std.Io.File, io: std.Io, size: u64, session: *Session, url: []const u8, commit: []const u8, path: []const u8) Error!void {
    var buffer: [8192]u8 = undefined;
    var file_buffer: [8192]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    var remaining = size;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, buffer.len));
        const n = reader.readSliceShort(buffer[0..want]) catch
            return session.fail(.unavailable, .repository, url, "cannot read blob \"{s}\" in commit {s}", .{ path, commit });
        if (n == 0) {
            return session.fail(.unavailable, .repository, url, "truncated blob \"{s}\" in commit {s}", .{ path, commit });
        }
        file_writer.interface.writeAll(buffer[0..n]) catch
            return session.fail(.unavailable, .repository, url, "cannot write \"{s}\" in checkout", .{path});
        remaining -= n;
    }
    file_writer.interface.flush() catch
        return session.fail(.unavailable, .repository, url, "cannot write \"{s}\" in checkout", .{path});
}

// ---------------------------------------------------------------------------
// HTTP provider
// ---------------------------------------------------------------------------

pub fn httpArtifactType(bytes: []const u8) []const u8 {
    return if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04")) ".npkg" else "raw";
}

/// HTTP URL 依存の取得。`dep.hash` で内容を照合し、`.npkg`（ZIP）であれば
/// `npkg_verify` で検証して manifest を取り出す。別 source への暗黙切替や
/// hash 未検証の受理は行わない。
///
/// `.npkg` の対象環境適合は provider が決められないため archive 構造・
/// 必須 metadata・FILES.toml のみをここで検査する。runtime・engines・
/// artifact 選択の適合判定は利用側（`sync` の `npkgTarget` 検証）が担う。
pub fn acquireHttp(session: *Session, dep: manifest_mod.HttpDependency) Error!Acquired {
    const bytes = try fetch.fetchBytes(session, dep.url, .artifact);
    try fetch.verifyHash(session, bytes, dep.hash, dep.url, .artifact);

    var acquired = Acquired{
        // source の文字列は全て session arena が所有する。
        .source = .{
            .kind = .http,
            .url = try session.allocator().dupe(u8, dep.url),
            .hash = try session.allocator().dupe(u8, dep.hash),
        },
        .artifact_bytes = bytes,
        .artifact_sha256 = try fetch.sha256Hex(session.allocator(), bytes),
        .artifact_type = "raw",
    };

    if (std.mem.eql(u8, httpArtifactType(bytes), ".npkg")) {
        var scratch = diag.List.init(session.gpa);
        defer scratch.deinit();
        // `Verified` の arena は session arena を backing にするため、deinit
        // せず session の寿命まで `verified.manifest` を有効に保つ。
        // target 適合は要求 profile 未定のここでは判定しない（既定 target
        // での誤拒否を防ぐ）。sync 側が実 target で再検証する。
        const verified = npkg_verify.verifyArchive(session.allocator(), bytes, session.diagSink(&scratch)) catch |err| switch (err) {
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
            if (!sourceHashEql(declared.hash, locked.hash)) {
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

pub fn sourceHashEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    const left = a.?;
    const right = b.?;
    if (fetch.normalizeSha256(left)) |left_digest| {
        if (fetch.normalizeSha256(right)) |right_digest| return std.mem.eql(u8, &left_digest, &right_digest);
    }
    if (fetch.normalizeSha512(left)) |left_digest| {
        if (fetch.normalizeSha512(right)) |right_digest| return std.mem.eql(u8, &left_digest, &right_digest);
    }
    return std.mem.eql(u8, left, right);
}

fn canonicalHashPin(gpa: Allocator, hash: []const u8) ![]const u8 {
    if (fetch.normalizeSha256(hash)) |digest| return std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    if (fetch.normalizeSha512(hash)) |digest| return std.fmt.allocPrint(gpa, "sha512:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    return gpa.dupe(u8, hash);
}

/// source identity の正準表現（衝突判定用キー）。
pub fn identityText(gpa: Allocator, source: lock_model.Source) ![]u8 {
    return switch (source.kind) {
        .git => std.fmt.allocPrint(gpa, "git:{s}@{s}:{s}", .{ source.url orelse "", source.commit orelse "", source.path orelse "" }),
        .http => blk: {
            const hash = try canonicalHashPin(gpa, source.hash orelse "");
            defer gpa.free(hash);
            break :blk try std.fmt.allocPrint(gpa, "http:{s}#{s}", .{ source.url orelse "", hash });
        },
        .path => std.fmt.allocPrint(gpa, "path:{s}", .{source.path orelse ""}),
        .registry, .static => std.fmt.allocPrint(gpa, "{s}:{s}", .{ @tagName(source.kind), source.url orelse "" }),
    };
}

test "HTTP source identity は同一 digest のhexとSRI表記を正規化する" {
    const gpa = std.testing.allocator;
    const zeros = [_]u8{0} ** 32;
    var encoded: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &zeros);
    const sri = try std.fmt.allocPrint(gpa, "sha256-{s}", .{encoded[0..]});
    defer gpa.free(sri);

    const hex_source = lock_model.Source{
        .kind = .http,
        .url = "https://example.test/archive",
        .hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    };
    const sri_source = lock_model.Source{
        .kind = .http,
        .url = "https://example.test/archive",
        .hash = sri,
    };
    const hex_id = try identityText(gpa, hex_source);
    defer gpa.free(hex_id);
    const sri_id = try identityText(gpa, sri_source);
    defer gpa.free(sri_id);
    try std.testing.expectEqualStrings(hex_id, sri_id);
    try std.testing.expect(sourceHashEql(hex_source.hash, sri_source.hash));
}

test {
    _ = @import("provider_test.zig");
}
