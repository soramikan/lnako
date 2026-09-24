const std = @import("std");
const builtin = @import("builtin");
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

/// path 依存の宣言 path が絶対 path か。spec §3.4.3 は相対・絶対の双方を
/// 許容する。実行環境の `std.fs.path.isAbsolute` だけでは判定できない
/// Windows 形式（`C:/x`・`C:\x`・`\\srv\sh`）も全環境で絶対扱いする
/// （lock は生成環境の path をそのまま保持するため）。
pub fn isAbsoluteDepPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        (path[2] == '/' or path[2] == '\\')) return true;
    return std.fs.path.isAbsolute(path);
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
    } else {
        // 既存 checkout の origin が宣言 URL と一致するか検証する。別 repo の
        // checkout を再利用して別 URL の内容を読み違えないようにする。
        try verifyCheckoutOrigin(session, checkout_dir, dep);
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

/// 既存 checkout の origin が宣言 URL を指しているか検証する。
/// origin が無い checkout（手動 seed 等）には宣言 URL の origin を設定する。
/// origin が別 URL を指す場合、別 repo の内容を別 source として返さないよう
/// `source_collision` で拒否する。
fn verifyCheckoutOrigin(session: *Session, checkout_dir: []const u8, dep: manifest_mod.GitDependency) Error!void {
    const gpa = session.allocator();
    const result = try gitRunAllowFailure(session, gpa, &.{ "git", "-C", checkout_dir, "remote", "get-url", "origin" });
    if (!result.succeeded) {
        // origin remote が無い checkout には宣言 URL を設定して後段の
        // fetch が動くようにする。
        try gitRun(session, &.{ "git", "-C", checkout_dir, "remote", "add", "origin", dep.url }, dep.url);
        return;
    }
    const existing = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!try gitUrlEql(gpa, existing, dep.url)) {
        return session.fail(.source_collision, .repository, dep.url, "checkout \"{s}\" belongs to a different repository (origin is \"{s}\")", .{ checkout_dir, existing });
    }
}

/// git remote URL の構造化比較。ローカル形式（bare path または authority
/// が空・`localhost` の `file:` URL）はパスをそのまま比較し、末尾 `.git`
/// はファイル名の一部として残す（`/deps/a` と `/deps/a.git` は別 repo に
/// なり得る）。リモート形式（`scheme://`、scp 形式 `user@host:path`、
/// authority を持つ `file:` URL）は末尾 `/` と慣例的な `.git` 接尾辞の
/// 表記揺れだけを吸収する。ローカルとリモートは一致しない。
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

    // `.npkg`（ZIP 格納形式）は先頭が local file header 署名 `PK\x03\x04`。
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04")) {
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

test "normalizeLocalGitPath は Windows 区切りと drive letter を正規化する" {
    // 返り値は確保バッファの subslice になり得るため arena で受ける。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // 末尾 `\` は変換後の末尾 `/` として除去する（`C:\repo\` ≡ `C:/repo`）。
    try std.testing.expectEqualStrings("C:/repo", try normalizeLocalGitPath(gpa, "C:\\repo\\", true));
    // file: URL の drive 表現 `/C:/x` は `C:/x` へ。
    try std.testing.expectEqualStrings("C:/x", try normalizeLocalGitPath(gpa, "/C:/x", true));
    // drive letter は大文字へ揃える。
    try std.testing.expectEqualStrings("C:/x", try normalizeLocalGitPath(gpa, "c:\\x", true));
    // extended-length `\\?\D:\x` と device `\\.\D:\x` は `D:/x` へ。
    try std.testing.expectEqualStrings("D:/x", try normalizeLocalGitPath(gpa, "\\\\?\\D:\\x", true));
    try std.testing.expectEqualStrings("D:/x", try normalizeLocalGitPath(gpa, "\\\\.\\D:\\x", true));
    // extended-length UNC `\\?\UNC\s\s` は通常 UNC `\\s\s` と同一視する。
    try std.testing.expectEqualStrings("//s/s", try normalizeLocalGitPath(gpa, "\\\\?\\UNC\\s\\s", true));
    try std.testing.expectEqualStrings("//s/s", try normalizeLocalGitPath(gpa, "\\\\.\\UNC\\s\\s", true));
    try std.testing.expectEqualStrings("//s/s", try normalizeLocalGitPath(gpa, "\\\\s\\s", true));
    // POSIX では `\` はファイル名文字のため変換しない（末尾 `/` のみ除去）。
    try std.testing.expectEqualStrings("a\\b", try normalizeLocalGitPath(gpa, "a\\b/", false));
}

test "classifyGitUrl は Windows の file:// drive 形式と UNC をローカル分類する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // `file://C:/x`・`file://D:\x` は authority ではなく drive path とみなす。
    switch (try classifyGitUrl(gpa, "file://C:/x", true)) {
        .local => |p| try std.testing.expectEqualStrings("C:/x", p),
        .remote => return error.TestUnexpectedResult,
    }
    switch (try classifyGitUrl(gpa, "file://D:\\x", true)) {
        .local => |p| try std.testing.expectEqualStrings("D:/x", p),
        .remote => return error.TestUnexpectedResult,
    }
    // `file://\\host\share` は UNC path とみなす。
    switch (try classifyGitUrl(gpa, "file://\\\\s\\s", true)) {
        .local => |p| try std.testing.expectEqualStrings("//s/s", p),
        .remote => return error.TestUnexpectedResult,
    }
    // `file://host/share` は引き続きリモート（bare path と誤認しない）。
    switch (try classifyGitUrl(gpa, "file://h/s", true)) {
        .local => return error.TestUnexpectedResult,
        .remote => {},
    }
    // POSIX では `file://C:/x` の `C:` は authority として残る。
    switch (try classifyGitUrl(gpa, "file://C:/x", false)) {
        .local => return error.TestUnexpectedResult,
        .remote => {},
    }
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
