//! `lnako package publish` の公開前検証（dry-run）と static registry への
//! 公開 transport。
//!
//! 役割:
//!   - `nako.toml` と `nako.lock` の整合、`.npkg` の再生成と検証、
//!     公開先 registry・認証・owner の設定検証をまとめて行う。
//!   - 既定は dry-run。`--no-dry-run` のときだけ、PS01 layout の
//!     `<owner>/<name>/<version>.json` と artifact `.npkg` を PUT する。
//!   - 再実行の冪等性: 公開済み version record の artifact hash が手元の
//!     `.npkg` と一致すれば成功扱いでスキップし、同一版で hash が異なる
//!     場合は上書きせず競合として拒否する。artifact PUT 後・record PUT
//!     前に失敗した場合も、再実行で同じ artifact を再送して収束する。
//!
//! 外部送信先は呼出し側が明示した `--registry` / `LNAKO_REGISTRY` だけ。
//! 既定の実 registry は持たない。認証は `LNAKO_REGISTRY_TOKEN` を
//! `Authorization: Bearer` として送る。token 値はログ・record・manifest へ
//! 保存しない。

const std = @import("std");
const diag = @import("diagnostics.zig");
const fetch = @import("fetch.zig");
const manifest_mod = @import("manifest.zig");
const npkg_build = @import("npkg_build.zig");
const npkg_verify = @import("npkg_verify.zig");
const env_state = @import("env_state.zig");
const project_load = @import("project_load.zig");
const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;

/// 公開処理の呼出し契約。`root`・`registry_url` などは呼出し側（CLI）が
/// 環境変数・フラグから解決して渡す。テストは同じ値を直接渡せる。
pub const Options = struct {
    /// `nako.toml` を持つ package root。
    root: []const u8 = ".",
    /// 既定は dry-run。false のときだけ PUT する。
    dry_run: bool = true,
    registry_url: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    token: ?[]const u8 = null,
    /// loopback 以外の平文 http registry を明示許可する。
    allow_plaintext_http: bool = false,
};

pub const Error = error{
    /// registry URL が未設定。
    RegistryRequired,
    /// 公開先 owner を解決できない（index 未収録かつ --owner 無し）。
    OwnerRequired,
    /// 認証情報が未設定。
    AuthRequired,
    /// 認証情報にヘッダへ載せられない文字が含まれる。
    InvalidAuth,
    /// registry URL・owner の形式が不正。
    InvalidRegistry,
    ProjectNotFound,
    InvalidManifest,
    LockMissing,
    InvalidLock,
    /// lock の manifest hash が現在の nako.toml と一致しない。
    LockMismatch,
    /// manifest・`.npkg` の公開前検証に失敗した（diagnostics に詳細）。
    InvalidPackage,
    /// 同一版が異なる artifact hash で既に公開されている。
    VersionConflict,
    /// 同一版が yanked 済み。再公開には registry 側の手続きが必要。
    VersionYanked,
    /// registry への問い合わせ・送信に失敗した（diagnostics に詳細）。
    RegistryUnavailable,
    FileSystem,
    OutOfMemory,
    Canceled,
};

/// 再実行時の状態。
pub const Status = enum {
    /// registry に version record が無い。
    unpublished,
    /// 同一版・同一 artifact hash が公開済み（今回は送信せずスキップ）。
    published,
    /// 今回の実行で artifact と version record を送信した。
    uploaded,
    /// PUT に失敗した。登録状態は保持され、再実行で再試行できる。
    failed,
};

/// 1 回の publish 実行結果。全メモリは内蔵 arena が所有する。
/// move-only: 値コピーした両方で `deinit` すると arena を二重解放するため、
/// 呼出し側は 1 つの所有値だけを `defer report.deinit();` で解放すること。
pub const Report = struct {
    /// ヒープ確保した arena へのポインタ。Report 生成後も同じ arena へ
    /// 確保し続けるため、値コピーによる buffer_list の取りこぼしを避ける。
    arena: *std.heap.ArenaAllocator,
    name: []const u8,
    version_text: []const u8,
    owner: []const u8,
    registry_url: []const u8,
    license: []const u8,
    /// 検証に使った runtime（manifest 宣言、空なら lnako）。
    runtimes: []const []const u8,
    lock_profile: []const u8,
    lock_packages: usize,
    artifact_name: []const u8,
    /// 64 桁 hex（SHA-256）。
    artifact_sha256: []const u8,
    artifact_size: usize,
    files: usize,
    commands: usize,
    version_url: []const u8,
    artifact_url: []const u8,
    status: Status = .unpublished,
    /// `status == .failed` のときの再試行可能な理由。
    failure: ?[]const u8 = null,
    dry_run: bool = true,

    pub fn deinit(self: *Report) void {
        const arena = self.arena;
        const gpa = arena.child_allocator;
        arena.deinit();
        gpa.destroy(arena);
        self.* = undefined;
    }
};

/// 公開前検証と（`dry_run == false` のときのみ）registry への PUT を行う。
/// 設定・manifest・lock・`.npkg` の問題は diagnostics に記録して error を
/// 返す。送信失敗は `Report.status == .failed` として返す（状態を保持し、
/// 再実行で再試行できる）。
pub fn run(backing_allocator: Allocator, io: std.Io, options: Options, diagnostics: *diag.List) Error!Report {
    const arena = backing_allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer {
        arena.deinit();
        backing_allocator.destroy(arena);
    }
    const a = arena.allocator();

    const registry_url = try a.dupe(u8, try validateRegistry(options));
    const token = options.token orelse return error.AuthRequired;
    try validateToken(token);
    const policy = fetch.Policy{ .allow_plaintext_http = options.allow_plaintext_http };

    var project = project_load.load(backing_allocator, io, options.root, diagnostics) catch |err| switch (err) {
        error.ProjectNotFound => return error.ProjectNotFound,
        error.InvalidManifest => return error.InvalidManifest,
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.FileSystem,
    };
    defer project.deinit();
    const package = &project.manifest.package;

    // `--owner` の形式はネットワーク前に検証する。未指定の場合の index 解決は
    // ローカル検証（lock・`.npkg`）の後へ回し、設定ミスの診断順を揃える。
    const explicit_owner: ?[]const u8 = if (options.owner) |value| try dupeValidOwner(a, value) else null;

    // lock は manifest の digest と一致していなければならない。consumer が
    // lock から再現できない状態を公開しない。
    var lock_state = try loadLockState(backing_allocator, io, project.root_dir, diagnostics);
    defer lock_state.deinit();
    if (!sameSha256Hex(lock_state.manifest_sha256, project.manifest_sha256)) return error.LockMismatch;

    try validateDistributableDependencies(a, &project.manifest, diagnostics);

    var runtimes: std.ArrayList([]const u8) = .empty;
    if (package.runtimes.len == 0) {
        try runtimes.append(a, "lnako");
    } else {
        for (package.runtimes) |runtime| try runtimes.append(a, try a.dupe(u8, runtime));
    }

    // `.npkg` は公開直前に必ず再生成し、同じ bytes を検証・送信する。
    // npkg_build は root path を再解決する（root_dir 版を持たない）ため、
    // build 後に pinned handle で manifest digest を再確認する。
    var built = npkg_build.build(backing_allocator, io, project.root, diagnostics, .{}) catch |err| switch (err) {
        error.InvalidPackage => return error.InvalidPackage,
        // manifest は project_load で読込済みのため、build 中の FileNotFound は
        // payload の消失（TOCTOU）等。nako.toml 不在と誤表示しない。
        error.FileNotFound => return error.FileSystem,
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.FileSystem,
    };
    defer built.deinit();
    const artifact_sha256 = try fetch.sha256Hex(a, built.archive);

    var files: usize = built.files.len;
    var commands: usize = 0;
    // ESM export（`esm` artifact のみの package）は `compat-js = true` の
    // profile を持つ project でのみ公開できる。公開契約は lock の選択
    // profile の宣言（PUBLISHING.md §5 の ESM artifact 条件）であり、CLI の
    // `--compat-js` 単独では許可しない。profile 無し・無宣言は従来どおり
    // 通常モード検証（E006）。`cnako` runtime は ESM を直接扱えるため
    // compat_js の影響を受けない。
    const profile_compat_js = if (project.manifest.profiles.get(lock_state.profile)) |profile| profile.compat_js else false;
    for (runtimes.items, 0..) |runtime, runtime_index| {
        var verified = npkg_verify.verify(backing_allocator, built.archive, .{ .runtime = runtime, .compat_js = profile_compat_js }, diagnostics) catch |err| switch (err) {
            error.InvalidPackage => return error.InvalidPackage,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileSystem,
        };
        defer verified.deinit();
        // 同じ archive を runtime ごとに検証する。summary は代表値として
        // 先頭 runtime の結果を表示する。
        if (runtime_index == 0) {
            files = verified.files.len;
            commands = verified.commands.len;
        }
    }

    // build は manifest を再読込するため、読込後・公開前に nako.toml が
    // 差し替えられていないことを digest で確認する（TOCTOU の幅を狭める）。
    const current_manifest = project.root_dir.readFileAlloc(io, "nako.toml", backing_allocator, .limited(manifest_mod.max_manifest_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml", .{}, "公開前の nako.toml 再確認に失敗しました", .{});
            return error.FileSystem;
        },
    };
    defer backing_allocator.free(current_manifest);
    const current_sha = try fetch.sha256Hex(a, current_manifest);
    if (!sameSha256Hex(current_sha, project.manifest_sha256)) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml", .{}, "nako.toml が公開前検証の読込後に変更されました。再実行してください（lock も更新が必要です）", .{});
        return error.InvalidPackage;
    }

    // owner は --owner を優先し、無ければ index.json から解決する。初回公開
    // （index 未収録）では明示指定が必要。
    const owner = explicit_owner orelse try resolveOwner(backing_allocator, io, a, policy, token, registry_url, package.name, package.id, diagnostics);

    const version_text = try std.fmt.allocPrint(a, "{f}", .{package.version});
    const artifact_name = try npkg_build.defaultOutputName(a, &project.manifest);
    const version_url = try std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}.json", .{ registry_url, owner, package.name, version_text });
    const artifact_url = try std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}/{s}", .{ registry_url, owner, package.name, version_text, artifact_name });

    const manifest_sha256 = try a.dupe(u8, project.manifest_sha256);
    var report = Report{
        .arena = arena,
        .name = try a.dupe(u8, package.name),
        .version_text = version_text,
        .owner = owner,
        .registry_url = registry_url,
        .license = try a.dupe(u8, package.license),
        .runtimes = try a.dupe([]const u8, runtimes.items),
        .lock_profile = try a.dupe(u8, lock_state.profile),
        .lock_packages = lock_state.packages,
        .artifact_name = artifact_name,
        .artifact_sha256 = artifact_sha256,
        .artifact_size = built.archive.len,
        .files = files,
        .commands = commands,
        .version_url = version_url,
        .artifact_url = artifact_url,
        .dry_run = options.dry_run,
    };

    const remote = try probeRemoteStatus(backing_allocator, io, policy, token, version_url, version_text, artifact_sha256, diagnostics);
    switch (remote) {
        .published => {
            report.status = .published;
            return report;
        },
        .conflict => return error.VersionConflict,
        .yanked => return error.VersionYanked,
        .unpublished => {},
    }
    if (options.dry_run) {
        report.status = .unpublished;
        return report;
    }

    if (try uploadPublication(
        a,
        backing_allocator,
        io,
        policy,
        token,
        &project.manifest,
        version_text,
        manifest_sha256,
        version_url,
        artifact_url,
        built.archive,
        artifact_sha256,
        diagnostics,
    )) |failure| {
        report.status = .failed;
        report.failure = failure;
        return report;
    }
    report.status = .uploaded;
    return report;
}

/// 公開内容と現在の状態を人間向けに表示する。CLI とテストが同じ文言を
/// 観測できるよう core 側に置く。
pub fn renderSummary(report: *const Report, writer: *std.Io.Writer) !void {
    try writer.print("package publish: {s}@{s}\n", .{ report.name, report.version_text });
    try writer.print("  registry: {s}\n", .{report.registry_url});
    try writer.print("  owner: {s}\n", .{report.owner});
    try writer.writeAll("  auth: Bearer（LNAKO_REGISTRY_TOKEN）\n");
    try writer.print("  manifest: OK（license: {s}）\n", .{report.license});
    try writer.print("  lock: OK（profile: {s}、{d} packages）\n", .{ report.lock_profile, report.lock_packages });
    try writer.print("  .npkg: OK（{d} ファイル、{d} 命令、sha256:{s}、{d} bytes）\n", .{
        report.files,
        report.commands,
        report.artifact_sha256,
        report.artifact_size,
    });
    try writer.writeAll("  runtimes: ");
    for (report.runtimes, 0..) |runtime, index| {
        if (index > 0) try writer.writeAll(", ");
        try writer.writeAll(runtime);
    }
    try writer.writeByte('\n');
    switch (report.status) {
        .unpublished => {
            try writer.writeAll("  状態: 未公開\n");
            if (report.dry_run) {
                try writer.print("  送信予定: PUT {s}\n", .{report.artifact_url});
                try writer.writeAll("  dry-run のため送信しません（--no-dry-run で公開）\n");
            }
        },
        .published => {
            try writer.writeAll("  状態: 公開済み（同一版・同一 hash のためスキップ）\n");
        },
        .uploaded => {
            try writer.writeAll("  状態: 公開しました（artifact と version record を送信）\n");
        },
        .failed => {
            try writer.print("  状態: 失敗（再実行で再試行できます）: {s}\n", .{report.failure orelse "unknown"});
        },
    }
}

// ---------------------------------------------------------------------------
// 設定検証
// ---------------------------------------------------------------------------

fn validateRegistry(options: Options) Error![]const u8 {
    const raw = options.registry_url orelse return error.RegistryRequired;
    const url = std.mem.trimEnd(u8, raw, "/");
    if (url.len == 0) return error.InvalidRegistry;
    const uri = std.Uri.parse(url) catch return error.InvalidRegistry;
    if (!(std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https"))) return error.InvalidRegistry;
    // request line へ流れる URL に空白・制御文字・非 ASCII を許可しない。
    for (url) |byte| {
        if (byte <= 0x20 or byte >= 0x7f) return error.InvalidRegistry;
    }
    if (uri.host == null) return error.InvalidRegistry;
    const host_text = switch (uri.host.?) {
        .raw, .percent_encoded => |text| text,
    };
    if (host_text.len == 0) return error.InvalidRegistry;
    // base URL に query/fragment/userinfo を許可しない。URL 組み立てが壊れる
    // うえ、userinfo は summary へそのまま表示され得る。
    if (uri.query != null or uri.fragment != null or uri.user != null or uri.password != null) return error.InvalidRegistry;
    if (std.mem.eql(u8, uri.scheme, "http") and !options.allow_plaintext_http and !fetch.isLoopbackHost(uri)) {
        return error.InvalidRegistry;
    }
    return url;
}

fn dupeValidOwner(a: Allocator, value: []const u8) Error![]const u8 {
    if (!isOwner(value)) return error.InvalidRegistry;
    return a.dupe(u8, value);
}

/// Bearer token は空白・制御文字・非 ASCII を含めない（生ヘッダへの注入と
/// header assert panic を防ぐ）。
fn validateToken(token: []const u8) Error!void {
    if (token.len == 0) return error.InvalidAuth;
    for (token) |byte| {
        if (byte <= 0x20 or byte >= 0x7f) return error.InvalidAuth;
    }
}

fn authorizationHeader(session: *fetch.Session, token: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(session.allocator(), "Bearer {s}", .{token}) catch return error.OutOfMemory;
}

/// 公開先 record path の owner 表記（`@owner/name` の owner 部分と同じ）。
fn isOwner(text: []const u8) bool {
    if (text.len == 0 or text.len > 256) return false;
    if (std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "..")) return false;
    for (text) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '-')) return false;
    }
    return true;
}

/// index.json から package 名（または Public ID）一致の owner を解決する。
/// Public ID 一致を優先し、同名が複数 owner に存在する場合は明示指定を要求
/// する。index が無い・未収録なら `OwnerRequired`、取得・解析失敗は
/// `RegistryUnavailable`（diagnostics に詳細）。
fn resolveOwner(
    backing_allocator: Allocator,
    io: std.Io,
    a: Allocator,
    policy: fetch.Policy,
    token: []const u8,
    registry_url: []const u8,
    name: []const u8,
    public_id: ?[]const u8,
    diagnostics: *diag.List,
) Error![]const u8 {
    var session = fetch.Session.init(backing_allocator, io, policy);
    defer session.deinit();
    const authorization = try authorizationHeader(&session, token);
    const headers = [_]std.http.Header{.{ .name = "authorization", .value = authorization }};
    const url = std.fmt.allocPrint(session.allocator(), "{s}/index.json", .{registry_url}) catch return error.OutOfMemory;
    const bytes = fetch.fetchBytesWithHeaders(&session, url, &headers, .index) catch |err| switch (err) {
        error.NotFound => return error.OwnerRequired,
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            session.reportDiagnostics(diagnostics) catch return error.OutOfMemory;
            return error.RegistryUnavailable;
        },
    };
    const index = registry.parseIndex(&session, bytes, url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            session.reportDiagnostics(diagnostics) catch return error.OutOfMemory;
            return error.RegistryUnavailable;
        },
    };
    // Public ID は name より強い identity。id 一致レコードが存在するのに
    // owner を確定できない場合、name 一致へフォールバックせず明示指定を
    // 要求する（弱いキーで別 owner へ送らない）。
    if (public_id) |id| {
        var has_id_record = false;
        for (index.packages.items) |package| {
            if (std.mem.eql(u8, package.id, id)) has_id_record = true;
        }
        // Public ID を宣言している以上、index に id 一致が無い name 一致は
        // 「別 identity」である。弱い name で別 package の owner を採用しない。
        if (!has_id_record) return error.OwnerRequired;
        return (try ownerFor(index.packages.items, a, id, null)) orelse error.OwnerRequired;
    }
    return (try ownerFor(index.packages.items, a, null, name)) orelse error.OwnerRequired;
}

/// `by_id` または `by_name` に一致する package の owner を返す。一致する
/// owner が複数なら `OwnerRequired`、不正な owner は無視する。
fn ownerFor(packages: []const registry.PackageRecord, a: Allocator, by_id: ?[]const u8, by_name: ?[]const u8) Error!?[]const u8 {
    var found: ?[]const u8 = null;
    for (packages) |package| {
        const matches = if (by_id) |id|
            std.mem.eql(u8, package.id, id)
        else if (by_name) |name|
            std.mem.eql(u8, package.name, name)
        else
            false;
        if (!matches) continue;
        // index 側の owner も `--owner` と同じ規則で検証し、不正な値を URL へ
        // 補間しない。
        if (!isOwner(package.owner)) continue;
        if (found) |previous| {
            if (!std.mem.eql(u8, previous, package.owner)) return error.OwnerRequired;
        } else {
            found = package.owner;
        }
    }
    if (found) |owner| return a.dupe(u8, owner) catch return error.OutOfMemory;
    return null;
}

// ---------------------------------------------------------------------------
// lock 整合
// ---------------------------------------------------------------------------

const LockState = struct {
    arena: std.heap.ArenaAllocator,
    manifest_sha256: []const u8,
    profile: []const u8,
    packages: usize,

    fn deinit(self: *LockState) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn loadLockState(
    backing_allocator: Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    diagnostics: *diag.List,
) Error!LockState {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var owned = (env_state.loadExistingLockDir(backing_allocator, io, root_dir, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.InvalidLock => return error.InvalidLock,
        else => return error.FileSystem,
    }) orelse return error.LockMissing;
    defer owned.deinit();
    return .{
        .arena = arena,
        .manifest_sha256 = try a.dupe(u8, owned.input.manifest_sha256),
        .profile = try a.dupe(u8, owned.input.profile),
        .packages = owned.packages.len,
    };
}

fn sameSha256Hex(left: []const u8, right: []const u8) bool {
    const a = fetch.normalizeSha256(left) orelse return false;
    const b = fetch.normalizeSha256(right) orelse return false;
    return std.mem.eql(u8, &a, &b);
}

// ---------------------------------------------------------------------------
// 公開可能性の検証
// ---------------------------------------------------------------------------

/// static registry の version record に表現できない依存形態を拒否する。
/// path 依存は `.npkg` へ同梱され自己完結するため許可し、git/http 依存
/// （外部から取得する実体）は公開物に含められないため拒否する。
fn validateDistributableDependencies(a: Allocator, manifest: *const manifest_mod.Manifest, diagnostics: *diag.List) Error!void {
    if (manifest.dependencies.git.count() > 0) {
        try diagnostics.addFmt(diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY, .err, "dependencies.git", .{}, "git dependency は static registry の version record で表現できません", .{});
        return error.InvalidPackage;
    }
    if (manifest.dependencies.http.count() > 0) {
        try diagnostics.addFmt(diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY, .err, "dependencies.http", .{}, "http dependency は static registry の version record で表現できません", .{});
        return error.InvalidPackage;
    }
    // npm 依存は static registry の version record に表現できず、consumer の
    // provider も npm を解決しない。依存情報が欠落した record を公開しない。
    if (manifest.dependencies.npm.count() > 0) {
        try diagnostics.addFmt(diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY, .err, "dependencies.npm", .{}, "npm dependency は static registry の version record で表現できません", .{});
        return error.InvalidPackage;
    }
    var iterator = manifest.dependencies.pkg.valueIterator();
    while (iterator.next()) |dependency| {
        if (dependency.public_id == null) {
            const path = std.fmt.allocPrint(a, "dependencies.pkg.{s}.public-id", .{dependency.name}) catch return error.OutOfMemory;
            try diagnostics.addFmt(diag.E019_REQUIRED_FIELD_MISSING, .err, path, dependency.position, "公開には依存 \"{s}\" の public-id が必要です", .{dependency.name});
            return error.InvalidPackage;
        }
    }
}

// ---------------------------------------------------------------------------
// 状態照会（再実行の冪等性）
// ---------------------------------------------------------------------------

const RemoteStatus = enum { unpublished, published, conflict, yanked };

/// 公開済み version record を取得し、手元 `.npkg` の hash と比較する。
/// 404 は未公開。record が存在し artifact hash が一致しなければ競合。
/// static registry の read は provider と同じく匿名だが、publish 先が read にも
/// 認証を要求する構成に備えて PUT と同じ Bearer を付与する。
fn probeRemoteStatus(
    backing_allocator: Allocator,
    io: std.Io,
    policy: fetch.Policy,
    token: []const u8,
    version_url: []const u8,
    version_text: []const u8,
    artifact_sha256: []const u8,
    diagnostics: *diag.List,
) Error!RemoteStatus {
    var session = fetch.Session.init(backing_allocator, io, policy);
    defer session.deinit();
    const authorization = try authorizationHeader(&session, token);
    const headers = [_]std.http.Header{.{ .name = "authorization", .value = authorization }};
    const bytes = fetch.fetchBytesWithHeaders(&session, version_url, &headers, .version) catch |err| switch (err) {
        error.NotFound => return .unpublished,
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            session.reportDiagnostics(diagnostics) catch return error.OutOfMemory;
            return error.RegistryUnavailable;
        },
    };
    const record = registry.parseVersionRecordBytes(&session, bytes, version_url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            session.reportDiagnostics(diagnostics) catch return error.OutOfMemory;
            return error.RegistryUnavailable;
        },
    };
    // path が版を固定しているため、record の version 不一致は registry 破損
    // として差替えを拒否する。
    if (!std.mem.eql(u8, record.version, version_text)) return .conflict;
    if (record.yanked) return .yanked;
    // 内容同一性は artifact hash で判定する（manifestHash は advisory で
    // consumer は未使用）。同一版の差替えは conflict として拒否する。
    for (record.artifacts) |artifact| {
        if (artifact.sha256) |sha| {
            if (sameSha256Hex(sha, artifact_sha256)) return .published;
        }
    }
    return .conflict;
}

// ---------------------------------------------------------------------------
// 送信
// ---------------------------------------------------------------------------

/// artifact と version record を PUT する。成功なら null、失敗なら
/// 再試行可能な理由（Report arena 所有）を返す。
fn uploadPublication(
    a: Allocator,
    backing_allocator: Allocator,
    io: std.Io,
    policy: fetch.Policy,
    token: []const u8,
    manifest: *const manifest_mod.Manifest,
    version_text: []const u8,
    manifest_sha256: []const u8,
    version_url: []const u8,
    artifact_url: []const u8,
    artifact_bytes: []const u8,
    artifact_sha256: []const u8,
    diagnostics: *diag.List,
) Error!?[]const u8 {
    var session = fetch.Session.init(backing_allocator, io, policy);
    defer session.deinit();
    const authorization = std.fmt.allocPrint(a, "Bearer {s}", .{token}) catch return error.OutOfMemory;

    const artifact_headers = [_]std.http.Header{
        .{ .name = "authorization", .value = authorization },
        .{ .name = "content-type", .value = "application/octet-stream" },
    };
    const artifact_response = fetch.putBytes(&session, artifact_url, &artifact_headers, artifact_bytes, .artifact) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return try uploadFailure(a, &session, diagnostics, "artifact", artifact_url, null, null),
    };
    if (!isSuccessStatus(artifact_response.status)) {
        return try uploadFailure(a, &session, diagnostics, "artifact", artifact_url, artifact_response.status, artifact_response.body);
    }

    // Writer.Allocating はメモリ上の書き込みのみのため、失敗は OOM とみなす。
    const record_body = buildVersionRecord(a, manifest, version_text, manifest_sha256, artifact_url, artifact_sha256) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.OutOfMemory,
    };
    const record_headers = [_]std.http.Header{
        .{ .name = "authorization", .value = authorization },
        .{ .name = "content-type", .value = "application/json" },
    };
    const record_response = fetch.putBytes(&session, version_url, &record_headers, record_body, .version) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return try uploadFailure(a, &session, diagnostics, "version record", version_url, null, null),
    };
    if (!isSuccessStatus(record_response.status)) {
        return try uploadFailure(a, &session, diagnostics, "version record", version_url, record_response.status, record_response.body);
    }
    return null;
}

fn uploadFailure(
    a: Allocator,
    session: *fetch.Session,
    diagnostics: *diag.List,
    what: []const u8,
    url: []const u8,
    status: ?u16,
    body: ?[]const u8,
) Error![]const u8 {
    if (status) |code| {
        var snippet_buffer: [200]u8 = undefined;
        const snippet = bodySnippet(body orelse "", &snippet_buffer);
        const message = std.fmt.allocPrint(a, "{s} の送信に失敗しました（HTTP {d}） {s}", .{ what, code, snippet }) catch return error.OutOfMemory;
        try diagnostics.addFmt(diag.E041_FETCH_NETWORK, .err, url, .{}, "{s}", .{message});
        return message;
    }
    session.reportDiagnostics(diagnostics) catch return error.OutOfMemory;
    const message = if (session.lastFailure()) |failure| failure.message else "network error";
    return std.fmt.allocPrint(a, "{s} の送信に失敗しました: {s}", .{ what, message }) catch return error.OutOfMemory;
}

/// 応答 body は信頼できない入力のため、表示可能 ASCII だけを残して
/// 制御文字・改行を `?` に置換した最大 200 bytes を返す。
fn bodySnippet(body: []const u8, buffer: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const length = @min(trimmed.len, buffer.len);
    for (trimmed[0..length], 0..) |byte, index| {
        buffer[index] = if (byte >= 0x20 and byte <= 0x7e) byte else '?';
    }
    return buffer[0..length];
}

fn isSuccessStatus(status: u16) bool {
    return status >= 200 and status < 300;
}

/// PS01 version record を生成する。`schemaVersion` / `manifestHash` /
/// `artifacts` は registry schema の必須契約に合わせる。
fn buildVersionRecord(
    a: Allocator,
    manifest: *const manifest_mod.Manifest,
    version_text: []const u8,
    manifest_sha256: []const u8,
    artifact_url: []const u8,
    artifact_sha256: []const u8,
) anyerror![]u8 {
    var out = std.Io.Writer.Allocating.init(a);
    errdefer out.deinit();
    const writer = &out.writer;

    const artifact_sha = std.fmt.allocPrint(a, "sha256:{s}", .{artifact_sha256}) catch return error.OutOfMemory;

    var dependency_ids: std.ArrayList([]const u8) = .empty;
    var iterator = manifest.dependencies.pkg.valueIterator();
    while (iterator.next()) |dependency| {
        const public_id = dependency.public_id orelse continue; // run で検証済み
        try dependency_ids.append(a, public_id);
    }
    std.mem.sort([]const u8, dependency_ids.items, {}, stringLessThan);

    var features: std.ArrayList([]const u8) = .empty;
    var feature_iterator = manifest.features.keyIterator();
    while (feature_iterator.next()) |key| try features.append(a, key.*);
    std.mem.sort([]const u8, features.items, {}, stringLessThan);

    try writer.writeAll("{\"schemaVersion\":1,\"version\":");
    try std.json.Stringify.value(version_text, .{}, writer);
    try writer.writeAll(",\"manifestHash\":");
    try std.json.Stringify.value(manifest_sha256, .{}, writer);
    try writer.writeAll(",\"yanked\":false,\"dependencies\":[");
    for (dependency_ids.items, 0..) |id, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(id, .{}, writer);
    }
    try writer.writeAll("],\"features\":[");
    for (features.items, 0..) |name, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(name, .{}, writer);
    }
    try writer.writeAll("],\"artifacts\":{\"source\":{\"kind\":\"source\",\"type\":\".npkg\",\"sha256\":");
    try std.json.Stringify.value(artifact_sha, .{}, writer);
    try writer.writeAll(",\"url\":");
    try std.json.Stringify.value(artifact_url, .{}, writer);
    try writer.writeAll("}}}");
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}
