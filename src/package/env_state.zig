//! プロジェクトの実行前状態管理（`.nako` 環境の読み取り検査・編集 lock・
//! 環境準備 orchestration）。
//!
//! `project.zig` から分離した読み取り専用の検査系（`inspectForCheck`・
//! `readEnvironmentInfo`・`environmentPackagesUsable`）と、manifest/lock
//! 編集を直列化する `EditLock`、lock 最新化＋環境同期を束ねる
//! `ensureEnvironment` を収める。`project.zig` はこれらを再エクスポート
//! するため、呼出し側は従来どおり `project.X` で参照できる。

const std = @import("std");
const diag = @import("diagnostics.zig");
const lock_mod = @import("lock.zig");
const lock_model = @import("lock_model.zig");
const project = @import("project.zig");
const sync_mod = @import("sync.zig");

const Allocator = std.mem.Allocator;

pub const Error = project.Error;

// ---------------------------------------------------------------------------
// manifest/lock 編集の排他 lock
// ---------------------------------------------------------------------------

/// manifest 編集と lock 書込をプロジェクト単位で直列化する OS file lock。
/// `nako.toml` は原子的置換で inode が入れ替わり、`nako.lock` も tmp+rename
/// で置き換わるため、どちらのファイルにも lock は取れない。rename されない
/// 専用パス `<root>/.nako/edit.lock` を使う。
/// lock の writer（add/remove/lock/update/sync/自動準備）は manifest
/// 読込の前に取得し、lock 公開まで保持すること。
pub const EditLock = struct {
    file: std.Io.File,
    io: std.Io,

    pub fn unlock(self: *EditLock) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
    }
};

/// `project_root` の編集 lock を blocking で取得する。`.nako` は管理 dir
/// として作られる（symlink 等は `NotDir` 系エラーで失敗し追従しない）。
pub fn acquireEditLock(gpa: Allocator, io: std.Io, project_root: []const u8) Error!EditLock {
    const lock_path = try std.fs.path.join(gpa, &.{ project_root, ".nako", "edit.lock" });
    defer gpa.free(lock_path);
    if (std.fs.path.dirname(lock_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| return project.mapFs(err);
    }
    const file = std.Io.Dir.cwd().createFile(io, lock_path, .{
        .read = true,
        .lock = .exclusive,
        .lock_nonblocking = false,
    }) catch |err| return project.mapFs(err);
    return .{ .file = file, .io = io };
}

// ---------------------------------------------------------------------------
// 環境状態の検査（副作用なし）
// ---------------------------------------------------------------------------

pub const EnvironmentInfo = struct {
    schema_version: i64 = 0,
    lock_sha256: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    /// `.nako/current` の世代名（あれば）。
    generation: ?[]const u8 = null,
    packages: usize = 0,
};

/// `.nako/environment.json` を読む。無ければ null。読み取りのみで
/// `.nako` を作成しない（check/--no-sync の副作用なし契約）。
pub fn readEnvironmentInfo(gpa: Allocator, io: std.Io, project_root: []const u8) Error!?EnvironmentInfo {
    const path = try std.fs.path.join(gpa, &.{ project_root, ".nako", "environment.json" });
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return null,
        else => return project.mapFs(err),
    };
    defer gpa.free(bytes);
    var info = EnvironmentInfo{};
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.InvalidLock;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidLock;
    const obj = parsed.value.object;
    if (obj.get("schemaVersion")) |v| {
        if (v == .integer) info.schema_version = v.integer;
    }
    if (obj.get("lockSha256")) |v| {
        if (v == .string) info.lock_sha256 = try gpa.dupe(u8, v.string);
    }
    if (obj.get("profile")) |v| {
        if (v == .string) info.profile = try gpa.dupe(u8, v.string);
    }
    if (obj.get("runtime")) |v| {
        if (v == .string) info.runtime = try gpa.dupe(u8, v.string);
    }
    if (obj.get("packages")) |v| {
        if (v == .object) info.packages = v.object.count();
    }
    const current_path = try std.fs.path.join(gpa, &.{ project_root, ".nako", "current" });
    defer gpa.free(current_path);
    if (std.Io.Dir.cwd().readFileAlloc(io, current_path, gpa, .limited(4096)) catch null) |current| {
        defer gpa.free(current);
        const name = std.mem.trim(u8, current, " \t\r\n");
        if (name.len > 0) info.generation = try gpa.dupe(u8, name);
    }
    return info;
}

/// `.nako/env/<generation>` dir が実在するか。`environment.json` だけ残って
/// 参照世代が消えた状態を stale として扱うための検査。世代名に path 成分が
/// 混じった細工した `current` は拒否する。
pub fn generationExists(io: std.Io, project_root: []const u8, generation: []const u8) bool {
    if (generation.len == 0 or generation.len > 256) return false;
    for (generation) |ch| {
        // `.` を含む世代名は存在しない（`..` による dir 外参照を拒否）。
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    var buffer: [512]u8 = undefined;
    const rel = std.fmt.bufPrint(&buffer, ".nako" ++ std.fs.path.sep_str ++ "env" ++ std.fs.path.sep_str ++ "{s}", .{generation}) catch return false;
    var path_buffer: [4096]u8 = undefined;
    const abs = std.fmt.bufPrint(&path_buffer, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ project_root, rel }) catch return false;
    std.Io.Dir.cwd().access(io, abs, .{}) catch return false;
    return true;
}

/// `lnako check` / cnako `--no-sync` のための静的検査結果。
/// ファイルシステムを一切変更しない。
pub const CheckInfo = struct {
    /// `nako.lock` の状態。
    lock_state: enum { missing, invalid, fresh, stale },
    /// 読めた lock の鮮度（invalid/missing では未使用）。
    freshness: lock_mod.Freshness = .missing,
    /// `.nako/environment.json` の内容。無ければ null。
    environment: ?EnvironmentInfo,
    /// 環境が現行 lock と整合するか。
    environment_current: bool,
};

/// manifest・lock・環境を読み取り専用で検査する。`.nako` を含め
/// ファイルシステムへ一切書き込まない。
pub fn inspectForCheck(
    gpa: Allocator,
    io: std.Io,
    project_: *const project.Project,
    opts: *const project.PrepareOptions,
    diagnostics: *diag.List,
) Error!CheckInfo {
    var info = CheckInfo{ .lock_state = .missing, .environment = null, .environment_current = false };

    const profiles = try project.profilesOf(gpa, project_);
    const profile = try project.selectProfile(profiles, opts.profile, diagnostics);
    const record = project.recordOf(profiles, profile) orelse return error.UnknownProfile;
    var expanded = try project.expandRootFeatures(gpa, &project_.manifest, opts.features, !opts.no_default_features, diagnostics);
    defer expanded.deinit();
    const input = lock_model.Input{
        .manifest_sha256 = project_.manifest_sha256,
        .profile = profile,
        .features = try project.expandedFeatureNames(gpa, &expanded),
        .target = .{ .os = record.os, .cpu = record.cpu, .abi = record.abi },
    };

    var existing = project.loadExistingLock(gpa, io, project_.root, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            info.lock_state = .invalid;
            return info;
        },
    };
    defer if (existing) |*l| l.deinit();
    if (existing == null) {
        info.freshness = .missing;
    } else {
        info.freshness = lock_mod.checkFreshness(&existing.?, input);
        // `mutable = false` の pin hash 不一致も stale とする。
        if (info.freshness == .fresh and
            (try sync_mod.pathPinMismatch(gpa, io, project_.root, &existing.?)) != null)
        {
            info.freshness = .stale_manifest;
        }
        info.lock_state = if (info.freshness == .fresh) .fresh else .stale;
    }

    info.environment = try readEnvironmentInfo(gpa, io, project_.root);
    var digest: [32]u8 = undefined;
    const has_lock = try project.lockDigest(gpa, io, project_.root, &digest);
    // ensureEnvironment と同じ整合条件で判定する（lock digest・schema・
    // 選択 profile・runtime・参照世代 dir の実在）。
    info.environment_current = has_lock and info.environment != null and
        environmentMatchesLock(info.environment.?, &digest) and
        info.environment.?.schema_version == 1 and
        (info.environment.?.profile == null or std.mem.eql(u8, info.environment.?.profile.?, profile)) and
        (info.environment.?.runtime == null or std.mem.eql(u8, info.environment.?.runtime.?, "lnako")) and
        // 参照世代 dir が消えた環境は不一致とする。
        (info.environment.?.generation != null and generationExists(io, project_.root, info.environment.?.generation.?)) and
        // packages 記録・実体の欠落も不一致とする。
        (existing == null or try environmentPackagesUsable(gpa, io, project_.root, &existing.?, profile));
    return info;
}

/// `environment.json` の `packages` 記録が lock graph と一致し、記録された
/// package path が実在するか。ヘッダ（lockSha256・profile 等）だけ一致して
/// いて packages map が欠落・破損している環境を「最新」と誤認しないための
/// 内容検査。記録 path が project 外を指すものは不一致として扱う。
pub fn environmentPackagesUsable(gpa: Allocator, io: std.Io, project_root: []const u8, lock: *const lock_model.Lock, profile: []const u8) Error!bool {
    const path = try std.fs.path.join(gpa, &.{ project_root, ".nako", "environment.json" });
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer gpa.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const packages_value = parsed.value.object.get("packages") orelse return false;
    if (packages_value != .object) return false;
    const records = packages_value.object;

    const root_abs = std.fs.path.resolve(gpa, &.{project_root}) catch return error.FileSystem;
    defer gpa.free(root_abs);
    const entries = lock.packagesForProfile(profile) orelse lock.packages;
    for (entries) |entry| {
        // packages map は record.key（Public ID、source では一意キー）を
        // キーにするため id → name の順で引く。
        const record = records.get(entry.id) orelse records.get(entry.name) orelse return false;
        if (record != .object) return false;
        const path_value = record.object.get("path") orelse return false;
        if (path_value != .string) return false;
        const abs = std.fs.path.resolve(gpa, &.{ root_abs, path_value.string }) catch return error.FileSystem;
        defer gpa.free(abs);
        // project 外を指す記録は環境破損として扱う。
        if (!std.mem.startsWith(u8, abs, root_abs) or abs.len == root_abs.len or
            (abs[root_abs.len] != '/' and abs[root_abs.len] != std.fs.path.sep)) return false;
        const stat = std.Io.Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch return false;
        if (stat.kind != .directory) return false;
    }
    return true;
}

/// 環境の `lockSha256` が現行 `nako.lock` と一致するか。
pub fn environmentMatchesLock(info: EnvironmentInfo, lock_digest: *const [32]u8) bool {
    const recorded = info.lock_sha256 orelse return false;
    var expected: [32]u8 = undefined;
    return lock_model.normalizeSha256(recorded, &expected) and
        std.mem.eql(u8, &expected, lock_digest);
}

// ---------------------------------------------------------------------------
// 環境準備（ensureLock → 必要なら sync）
// ---------------------------------------------------------------------------

pub const PrepOutcome = struct {
    /// lock が新規書込・更新されたか。
    lock_wrote: bool = false,
    /// 今回 sync を実行したか。
    synced: bool = false,
    /// `.nako` の絶対 path（環境が存在する場合）。
    environment_root: ?[]const u8 = null,
    /// sync の世代名。
    generation: ?[]const u8 = null,
    profile: []const u8 = "",
    /// 直前の環境が不足・不一致だったか。
    was_stale: bool = false,
};

/// lock を最新化し、`.nako` 環境が現行 lock と一致しない場合のみ
/// `sync.run` を実行する。`--no-sync` 呼び出し側は本関数を呼ばず
/// `readEnvironmentInfo` で既存環境を検査する。
pub fn ensureEnvironment(
    gpa: Allocator,
    io: std.Io,
    project_: *const project.Project,
    opts: *const project.PrepareOptions,
    diagnostics: *diag.List,
) Error!PrepOutcome {
    var outcome = PrepOutcome{};
    var lock_outcome = try project.ensureLock(gpa, io, project_, opts, diagnostics);
    defer lock_outcome.deinit();
    outcome.lock_wrote = lock_outcome.wrote;
    // lock_outcome の arena は defer で破棄されるため、gpa 側へ複製する。
    outcome.profile = try gpa.dupe(u8, lock_outcome.profile);

    var digest: [32]u8 = undefined;
    const has_lock = try project.lockDigest(gpa, io, project_.root, &digest);
    const env = try readEnvironmentInfo(gpa, io, project_.root);
    const env_ok = has_lock and env != null and
        environmentMatchesLock(env.?, &digest) and
        env.?.schema_version == 1 and
        (env.?.profile == null or std.mem.eql(u8, env.?.profile.?, lock_outcome.profile)) and
        (env.?.runtime == null or std.mem.eql(u8, env.?.runtime.?, "lnako")) and
        // 参照世代 dir が消えた環境は不一致として sync し直す。
        (env.?.generation != null and generationExists(io, project_.root, env.?.generation.?)) and
        // packages 記録の欠落・実体の欠如も不一致（内容検証）。
        try environmentPackagesUsable(gpa, io, project_.root, &lock_outcome.lock, lock_outcome.profile);
    if (env_ok) {
        outcome.environment_root = try std.fs.path.join(gpa, &.{ project_.root, ".nako" });
        outcome.generation = env.?.generation;
        return outcome;
    }
    outcome.was_stale = env != null;

    var report = try sync_mod.run(gpa, io, .{
        .project_root = project_.root,
        .profile = lock_outcome.profile,
        .runtime = .lnako,
        .cache_root = opts.cache_root,
        .policy = opts.policy,
    }, diagnostics);
    outcome.synced = true;
    outcome.environment_root = try gpa.dupe(u8, report.environment_root);
    outcome.generation = try gpa.dupe(u8, report.generation);
    report.deinit();
    return outcome;
}
