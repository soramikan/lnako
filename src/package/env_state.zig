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
const environment_mod = @import("environment.zig");
const lock_mod = @import("lock.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const marker_mod = @import("marker.zig");
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
/// として確保し、lock file はその dir ハンドル相対で no-follow に開く。
/// `.nako/edit.lock` が symlink の場合はリンク本体のみ除去して作り直し、
/// 外部 file への truncate・lock を防ぐ。
pub fn acquireEditLock(gpa: Allocator, io: std.Io, project_root: []const u8) Error!EditLock {
    const nako_path = try std.fs.path.join(gpa, &.{ project_root, ".nako" });
    defer gpa.free(nako_path);
    environment_mod.ensureManagedDir(io, nako_path) catch |err| return project.mapFs(err);
    var nako_dir = environment_mod.openManagedDir(io, nako_path, false) catch |err|
        return project.mapFs(err);
    defer nako_dir.close(io);
    return .{ .file = try openEditLockFile(nako_dir, io), .io = io };
}

/// `.nako` dir ハンドル相対で `edit.lock` を排他 lock 付きで開く。
/// 実装は `environment.openManagedLockFile`（`sync.lock` と共有）。
/// leaf symlink はリンク本体のみ除去して作り直すため、外部 file への
/// truncate・lock を防げる。
fn openEditLockFile(nako_dir: std.Io.Dir, io: std.Io) Error!std.Io.File {
    return environment_mod.openManagedLockFile(nako_dir, io, "edit.lock", false) catch |err|
        project.mapFs(err);
}

// ---------------------------------------------------------------------------
// 環境状態の検査（副作用なし）
// ---------------------------------------------------------------------------

const environment_root_fields = [_][]const u8{
    "schemaVersion",
    "lockSha256",
    "profile",
    "runtime",
    "mutablePaths",
    "packages",
};

fn hasOnlyEnvironmentRootFields(object: std.json.ObjectMap) bool {
    var iterator = object.iterator();
    while (iterator.next()) |field| {
        var known = false;
        for (environment_root_fields) |name| {
            if (std.mem.eql(u8, field.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return false;
    }
    return true;
}

fn hasValidMutablePaths(object: std.json.ObjectMap) bool {
    const value = object.get("mutablePaths") orelse return true;
    if (value != .array) return false;
    for (value.array.items) |item| {
        if (item != .object or item.object.count() != 2) return false;
        const path = item.object.get("path") orelse return false;
        const sha256 = item.object.get("sha256") orelse return false;
        if (path != .string or path.string.len == 0 or sha256 != .string) return false;
        if (sha256.string.len != 7 + 64 or !std.mem.startsWith(u8, sha256.string, "sha256:")) return false;
        for (sha256.string[7..]) |digit| {
            if (!std.ascii.isDigit(digit) and !(digit >= 'a' and digit <= 'f')) return false;
        }
    }
    return true;
}

pub const EnvironmentInfo = struct {
    schema_version: i64 = 0,
    lock_sha256: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    /// `.nako/current` の世代名（あれば）。
    generation: ?[]const u8 = null,
    packages: usize = 0,
    /// sync 時点の mutable path 依存の内容 digest（lock `input.mutablePaths`
    /// の写し）。宣言 dir の metadata-only 変更で環境が陳腐化したかの
    /// 判定に使う。旧環境では空。
    mutable_paths: []const lock_model.MutablePath = &.{},
};

/// `.nako/environment.json` を読む。無ければ null。読み取りのみで
/// `.nako` を作成しない（check/--no-sync の副作用なし契約）。
pub fn readEnvironmentInfo(gpa: Allocator, io: std.Io, project_root: []const u8) Error!?EnvironmentInfo {
    const path = try std.fs.path.join(gpa, &.{ project_root, ".nako", "environment.json" });
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(environment_mod.max_environment_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return null,
        error.StreamTooLong => return EnvironmentInfo{},
        else => return project.mapFs(err),
    };
    defer gpa.free(bytes);
    var info = EnvironmentInfo{};
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return info;
    defer parsed.deinit();
    if (parsed.value != .object) return info;
    const obj = parsed.value.object;
    if (!hasOnlyEnvironmentRootFields(obj) or !hasValidMutablePaths(obj)) return info;
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
    if (obj.get("mutablePaths")) |v| {
        if (v != .array) return null;
        var list: std.ArrayList(lock_model.MutablePath) = .empty;
        for (v.array.items) |item| {
            if (item != .object or item.object.count() != 2) return null;
            const path_v = item.object.get("path") orelse return null;
            const sha_v = item.object.get("sha256") orelse return null;
            if (path_v != .string or sha_v != .string) return null;
            try list.append(gpa, .{
                .path = try gpa.dupe(u8, path_v.string),
                .sha256 = try gpa.dupe(u8, sha_v.string),
            });
        }
        info.mutable_paths = list.items;
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

/// 環境が記録した mutable path digest が現行宣言 dir と一致するか。
/// `mutable = true` path 依存は exports・commands を環境へ snapshot する
/// ため、lock バイト列が同一でも dir の metadata-only 変更（exports や
/// commands のみ変更）で環境は陳腐化する。lock が mutable path 依存を
/// 宣言するのに環境が `mutablePaths` を記録していない旧環境は、その
/// 変更を検出できないため不一致とする。
pub fn environmentMutablePathsUsable(gpa: Allocator, io: std.Io, project_root: []const u8, info: EnvironmentInfo, lock: *const lock_model.Lock) Error!bool {
    // lock が記録する全 mutable path について環境側にも記録が必要。
    // `mutablePaths` 自体が無い旧環境、または一部 entry が欠けた環境は
    // 対応する dir の変更を検出できないため不一致とする。
    for (lock.input.mutable_paths) |mutable| {
        var recorded = false;
        for (info.mutable_paths) |item| {
            if (std.mem.eql(u8, item.path, mutable.path)) recorded = true;
        }
        if (!recorded) return false;
    }
    // environment.json は書き換え可能なローカル状態なので、lock に存在しない
    // path を追加して任意の project 外 tree をdigest対象にさせない。
    for (info.mutable_paths) |item| {
        var declared = false;
        for (lock.input.mutable_paths) |mutable| {
            if (std.mem.eql(u8, item.path, mutable.path)) declared = true;
        }
        if (!declared) return false;
    }
    return (try sync_mod.mutablePathsMismatch(gpa, io, project_root, info.mutable_paths)) == null;
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
    // `.nako`・`env`・`<gen>` の各成分を no-follow で辿る。中間 dir が
    // symlink/reparse point へ差し替えられていると、管理外の dir を
    // 現行世代として受理してしまう。
    return managedPathIsDirectory(io, project_root, rel);
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

    const profiles = try project.profilesOf(gpa, project_, opts.requested_runtime);
    const profile = try project.selectProfile(profiles, opts.profile, diagnostics);
    const record = project.recordOf(profiles, profile) orelse return error.UnknownProfile;
    var expanded = try project.expandRootFeatures(gpa, &project_.manifest, opts.features, !opts.no_default_features, diagnostics);
    defer expanded.deinit();
    const input = lock_model.Input{
        .manifest_sha256 = project_.manifest_sha256,
        .profile = profile,
        .features = try project.expandedFeatureNames(gpa, &expanded),
        .target = .{ .os = record.os, .cpu = record.cpu, .abi = record.abi, .compat_js = (record.compat_js orelse false) or opts.compat_js, .optimize = opts.optimize orelse record.optimize orelse "O0" },
        .runtime = project.resolveRuntime(record),
        .nako_version = try project.resolveVersionText(gpa, opts.nako_version),
        .cnako_version = try project.resolveVersionText(gpa, opts.cnako_version),
        .lnako_version = try project.resolveVersionText(gpa, opts.lnako_version),
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
        // `mutable = true` path 依存の内容 digest 変更も stale とする
        // （manifest が同じでも宣言 dir の中身で lock が陳腐化する）。
        if (info.freshness == .fresh and
            (try sync_mod.mutablePathMismatch(gpa, io, project_.root, &existing.?)) != null)
        {
            info.freshness = .stale_manifest;
        }
        info.lock_state = if (info.freshness == .fresh) .fresh else .stale;
    }

    info.environment = try readEnvironmentInfo(gpa, io, project_.root);
    var digest: [32]u8 = undefined;
    const has_lock = try project.lockDigest(gpa, io, project_.root, &digest);
    // ensureEnvironment と同じ整合条件で判定する（lock digest・schema・
    // 選択 profile・runtime・参照世代 dir の実在）。runtime は要求
    // runtime（未指定は lnako）との一致を要求する。
    const expected_runtime = opts.requested_runtime orelse "lnako";
    info.environment_current = has_lock and info.environment != null and
        environmentMatchesLock(info.environment.?, &digest) and
        info.environment.?.schema_version == 1 and
        // schema v1 の profile/runtime は必須項目。欠落・型違いで読め
        // なかった環境は選択 profile/runtime を証明できず不一致とする。
        (info.environment.?.profile != null and std.mem.eql(u8, info.environment.?.profile.?, profile)) and
        (info.environment.?.runtime != null and std.mem.eql(u8, info.environment.?.runtime.?, expected_runtime)) and
        // 参照世代 dir が消えた環境は不一致とする。
        (info.environment.?.generation != null and generationExists(io, project_.root, info.environment.?.generation.?)) and
        // packages 記録・実体の欠落も不一致とする。
        (existing == null or try environmentPackagesUsable(gpa, io, project_.root, &existing.?, profile)) and
        // 環境記録の mutablePaths digest が現行 dir と一致する
        // （metadata-only 変更でも exports/commands snapshot が陳腐化
        // するため）。
        (existing == null or try environmentMutablePathsUsable(gpa, io, project_.root, info.environment.?, &existing.?));
    return info;
}

/// `environment.json` の `packages` 記録が lock graph と一致し、記録された
/// package path が実在するか。ヘッダ（lockSha256・profile 等）だけ一致して
/// いて packages map が欠落・破損している環境を「最新」と誤認しないための
/// 内容検査。key 集合は graph と完全一致を要求し（余分な記録を残した環境は
/// graph に無い package の exports/commands を consumer が読み得る）、
/// 各 record の name/version/id/path/exports/commands を environment
/// schema の形状に照合する。`.nako` 展開物の記録が project 外を指すものは
/// 不一致として扱う。path 依存は宣言 path（`../shared`・絶対 path も正式な
/// 宣言形）をそのまま記録するため、格納値が lock の `source.path` と一致
/// することと dir の実在だけを要求する。
pub fn environmentPackagesUsable(gpa: Allocator, io: std.Io, project_root: []const u8, lock: *const lock_model.Lock, profile: []const u8) Error!bool {
    // `.nako` 自体が symlink/reparse point の場合 environment.json が
    // 管理外から供給されるため先に拒否する（record 検査の前）。
    if (!managedPathIsDirectory(io, project_root, ".nako")) return false;
    const path = try std.fs.path.join(gpa, &.{ project_root, ".nako", "environment.json" });
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(environment_mod.max_environment_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer gpa.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    if (!hasOnlyEnvironmentRootFields(parsed.value.object) or !hasValidMutablePaths(parsed.value.object)) return false;
    const packages_value = parsed.value.object.get("packages") orelse return false;
    if (packages_value != .object) return false;
    // `environment.json` には generation は記録されない。同期が公開する
    // `.nako/current` を唯一の現行世代情報として使い、symlink の current
    // や実体のない世代は受理しない。
    const current_path = std.fs.path.join(gpa, &.{ project_root, ".nako", "current" }) catch return error.OutOfMemory;
    defer gpa.free(current_path);
    const current_stat = std.Io.Dir.cwd().statFile(io, current_path, .{ .follow_symlinks = false }) catch return false;
    if (current_stat.kind != .file) return false;
    const current_bytes = std.Io.Dir.cwd().readFileAlloc(io, current_path, gpa, .limited(4096)) catch return false;
    defer gpa.free(current_bytes);
    const generation = std.mem.trim(u8, current_bytes, " \t\r\n");
    if (!generationExists(io, project_root, generation)) return false;
    const managed_deps = std.fs.path.join(gpa, &.{ ".nako", "env", generation, "deps" }) catch return error.OutOfMemory;
    defer gpa.free(managed_deps);
    const records = packages_value.object;

    const root_abs = std.fs.path.resolve(gpa, &.{project_root}) catch return error.FileSystem;
    defer gpa.free(root_abs);
    const entries = lock.packagesForProfile(profile) orelse lock.packages;
    if (records.count() != entries.len) return false;
    for (entries) |entry| {
        // packages map は record.key（Public ID、source では一意キー）を
        // キーにするため id → name の順で引く。
        const record = records.get(entry.id) orelse records.get(entry.name) orelse return false;
        if (!envRecordMatchesEntry(record, &entry)) return false;
        const recorded_path = record.object.get("path").?.string;
        if (entry.source != null and entry.source.?.kind == .path) {
            // path 依存の記録値は lock の `source.path` と一致することが
            // 正当性の根拠。project 外（`../`・絶対 path）は宣言者の
            // 正当な選択であり、一致しない任意 path だけを拒否する。
            const declared = entry.source.?.path orelse return false;
            if (!std.mem.eql(u8, recorded_path, declared)) return false;
            const abs = std.fs.path.resolve(gpa, &.{ root_abs, recorded_path }) catch return error.FileSystem;
            defer gpa.free(abs);
            // 宣言 path 自身が symlink の正当構成もあるためここでは
            // 追従して実在だけを見る（信任境界は lock の宣言値）。
            const stat = std.Io.Dir.cwd().statFile(io, abs, .{}) catch return false;
            if (stat.kind != .directory) return false;
            continue;
        }
        // environment.json の path separator は host 形式で書かれる環境と
        // `/` 形式の fixture/移植データの双方を受け、検査前にhost形式へ揃える。
        const host_path = try gpa.dupe(u8, recorded_path);
        defer gpa.free(host_path);
        for (host_path) |*char| {
            if (char.* == '/' or char.* == '\\') char.* = std.fs.path.sep;
        }
        // registry/git/http 等の非-path package は必ずこの generation の
        // 管理下に materialize される。project 内の任意 dir（例: src）を
        // environment.json が指しても package payload として信頼しない。
        if (!std.mem.startsWith(u8, host_path, managed_deps) or host_path.len <= managed_deps.len or
            host_path[managed_deps.len] != std.fs.path.sep) return false;
        const package_dir = host_path[managed_deps.len + 1 ..];
        if (package_dir.len == 0 or std.mem.indexOfScalar(u8, package_dir, std.fs.path.sep) != null) return false;
        const abs = std.fs.path.resolve(gpa, &.{ root_abs, host_path }) catch return error.FileSystem;
        defer gpa.free(abs);
        // env/staging 展開物の記録が project 外を指す場合は環境破損.
        if (!std.mem.startsWith(u8, abs, root_abs) or abs.len == root_abs.len or
            (abs[root_abs.len] != '/' and abs[root_abs.len] != std.fs.path.sep)) return false;
        // 末端だけでなく `.nako`/`env`/`<gen>` 等の中間成分も no-follow
        // で辿る。中間 dir が symlink/reparse point へ差し替えられて
        // いると、lexical な prefix 一致だけでは project 外を指す
        // 展開物を環境として受理してしまう。
        if (!managedPathIsDirectory(io, root_abs, abs[root_abs.len + 1 ..])) return false;
    }
    return true;
}

/// `environment.json` の1 record が lock entry と整合し、environment
/// schema の形状を満たすか。`name`/`version`/`path` は必須 string で
/// name・version は entry と一致、`id` は public id entry で必須・
/// それ以外では記録されても entry.id と一致が条件。`exports`/`commands`
/// は schema の item 形状を要求し、未知のキーを持つ record は拒否する。
fn envRecordMatchesEntry(record: std.json.Value, entry: *const lock_model.PackageEntry) bool {
    if (record != .object) return false;
    var it = record.object.iterator();
    while (it.next()) |field| {
        const known = std.mem.eql(u8, field.key_ptr.*, "name") or
            std.mem.eql(u8, field.key_ptr.*, "version") or
            std.mem.eql(u8, field.key_ptr.*, "id") or
            std.mem.eql(u8, field.key_ptr.*, "path") or
            std.mem.eql(u8, field.key_ptr.*, "exports") or
            std.mem.eql(u8, field.key_ptr.*, "commands");
        if (!known) return false;
    }
    const name_value = record.object.get("name") orelse return false;
    if (name_value != .string or !std.mem.eql(u8, name_value.string, entry.name)) return false;
    const version_value = record.object.get("version") orelse return false;
    if (version_value != .string or !std.mem.eql(u8, version_value.string, entry.version)) return false;
    const path_value = record.object.get("path") orelse return false;
    if (path_value != .string) return false;
    if (record.object.get("id")) |id_value| {
        if (id_value != .string or !std.mem.eql(u8, id_value.string, entry.id)) return false;
    } else if (sync_mod.isPackageId(entry.id)) return false;
    if (record.object.get("exports")) |exports| {
        if (exports != .array) return false;
        for (exports.array.items) |item| {
            if (!envExportRecordValid(item)) return false;
        }
    }
    if (record.object.get("commands")) |commands| {
        if (commands != .array) return false;
        for (commands.array.items) |item| {
            if (!envCommandRecordValid(item)) return false;
        }
    }
    return true;
}

fn envFeatureNameValid(name: []const u8) bool {
    if (name.len < 2 or name[0] < 'a' or name[0] > 'z') return false;
    for (name[1..]) |ch| {
        if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
    }
    return true;
}

fn envOsVersionValid(version: []const u8) bool {
    return manifest_mod.compareDottedVersion(version, version) != null;
}

fn envArtifactDeclValid(value: std.json.Value) bool {
    if (value != .object) return false;
    const path = value.object.get("path") orelse return false;
    if (path != .string or path.string.len == 0) return false;
    var it = value.object.iterator();
    while (it.next()) |field| {
        if (std.mem.eql(u8, field.key_ptr.*, "path")) {
            if (field.value_ptr.* != .string or field.value_ptr.string.len == 0) return false;
        } else if (std.mem.eql(u8, field.key_ptr.*, "when")) {
            if (field.value_ptr.* != .string) return false;
            var parsed = marker_mod.parse(std.heap.page_allocator, field.value_ptr.string) catch return false;
            switch (parsed) {
                .ok => |*marker| marker.deinit(),
                .err => return false,
            }
        } else if (std.mem.eql(u8, field.key_ptr.*, "min-os")) {
            if (field.value_ptr.* != .string or !envOsVersionValid(field.value_ptr.string)) return false;
        } else if (std.mem.eql(u8, field.key_ptr.*, "libc")) {
            if (field.value_ptr.* != .string) return false;
            const libc = field.value_ptr.string;
            if (!std.mem.eql(u8, libc, "gnu") and !std.mem.eql(u8, libc, "msvc") and
                !std.mem.eql(u8, libc, "musl") and !std.mem.eql(u8, libc, "none")) return false;
        } else if (std.mem.eql(u8, field.key_ptr.*, "features")) {
            if (field.value_ptr.* != .array) return false;
            for (field.value_ptr.array.items) |feature| {
                if (feature != .string or !envFeatureNameValid(feature.string)) return false;
            }
        } else return false;
    }
    return true;
}

fn envArtifactRefValid(value: std.json.Value) bool {
    if (value == .string) return value.string.len > 0;
    if (value == .object) return envArtifactDeclValid(value);
    if (value != .array or value.array.items.len == 0) return false;
    for (value.array.items) |item| {
        if (item == .string) {
            if (item.string.len == 0) return false;
        } else if (!envArtifactDeclValid(item)) return false;
    }
    return true;
}

/// `exportEntry` follows the package schema, including native/esm `artifactRef`.
fn envExportRecordValid(item: std.json.Value) bool {
    if (item != .object) return false;
    var it = item.object.iterator();
    while (it.next()) |field| {
        const key = field.key_ptr.*;
        if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "path") or std.mem.eql(u8, key, "alias")) {
            if (field.value_ptr.* != .string) return false;
        } else if (std.mem.eql(u8, key, "native") or std.mem.eql(u8, key, "esm")) {
            if (!envArtifactRefValid(field.value_ptr.*)) return false;
        } else return false;
    }
    const name = item.object.get("name") orelse return false;
    return name == .string;
}

/// env record の `commands` item。name は必須 string、args/josi は
/// string 配列、fn/return は string、variable/async は bool。
fn envCommandRecordValid(item: std.json.Value) bool {
    if (item != .object) return false;
    var it = item.object.iterator();
    while (it.next()) |field| {
        const key = field.key_ptr.*;
        const value = field.value_ptr.*;
        if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "fn") or std.mem.eql(u8, key, "return")) {
            if (value != .string) return false;
        } else if (std.mem.eql(u8, key, "args") or std.mem.eql(u8, key, "josi")) {
            if (value != .array) return false;
            for (value.array.items) |arg| {
                if (arg != .string) return false;
            }
        } else if (std.mem.eql(u8, key, "variable") or std.mem.eql(u8, key, "async")) {
            if (value != .bool) return false;
        } else return false;
    }
    return item.object.get("name") != null;
}

/// project root 相対 path の各成分を no-follow で辿り、末端が dir か。
/// 中間成分の symlink/reparse point も検出する（Windows では open が
/// reparse point 本体を開くため open 後の stat で判定する）。
/// 読み取り専用で、リンクを除去したり dir を作成したりしない。
fn managedPathIsDirectory(io: std.Io, root_abs: []const u8, rel: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, root_abs, .{}) catch return false;
    var it = std.mem.tokenizeAny(u8, rel, "/\\");
    while (it.next()) |component| {
        const next = dir.openDir(io, component, .{ .follow_symlinks = false }) catch {
            dir.close(io);
            return false;
        };
        dir.close(io);
        dir = next;
        const stat = dir.stat(io) catch {
            dir.close(io);
            return false;
        };
        if (stat.kind != .directory) {
            dir.close(io);
            return false;
        }
    }
    dir.close(io);
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
    const expected_runtime = opts.requested_runtime orelse "lnako";
    const env_ok = has_lock and env != null and
        environmentMatchesLock(env.?, &digest) and
        env.?.schema_version == 1 and
        // schema v1 の profile/runtime は必須項目。欠落・型違いなら選択
        // profile/runtime を証明できないため不一致として sync し直す。
        (env.?.profile != null and std.mem.eql(u8, env.?.profile.?, lock_outcome.profile)) and
        (env.?.runtime != null and std.mem.eql(u8, env.?.runtime.?, expected_runtime)) and
        // 参照世代 dir が消えた環境は不一致として sync し直す。
        (env.?.generation != null and generationExists(io, project_.root, env.?.generation.?)) and
        // packages 記録の欠落・実体の欠如も不一致（内容検証）。
        try environmentPackagesUsable(gpa, io, project_.root, &lock_outcome.lock, lock_outcome.profile) and
        // metadata-only な mutable path 変更（exports/commands のみ変更、
        // lock バイト列は同一）は環境の snapshot が陳腐化するため、環境
        // 記録の digest と現行 dir を照合する。
        try environmentMutablePathsUsable(gpa, io, project_.root, env.?, &lock_outcome.lock);
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
// ---------------------------------------------------------------------------
// nako.lock の読み取り・鮮度検査
// ---------------------------------------------------------------------------

fn readLockBytes(gpa: Allocator, io: std.Io, project_root: []const u8) Error!?[]const u8 {
    const path = try std.fs.path.join(gpa, &.{ project_root, project.lock_name });
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return null,
        else => return project.mapFs(err),
    };
}

/// 既存 lock を parse+validate する。無ければ null。破損は診断付きで
/// `InvalidLock`。
pub fn loadExistingLock(gpa: Allocator, io: std.Io, project_root: []const u8, diagnostics: *diag.List) Error!?lock_model.Lock {
    const bytes = (try readLockBytes(gpa, io, project_root)) orelse return null;
    // parse は全値を lock 所有 arena へ複製するため生バイトは即解放できる。
    defer gpa.free(bytes);
    const errors_before = diagnostics.errorCount();
    var parsed = lock_mod.parse(gpa, bytes, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidLock,
    };
    errdefer parsed.deinit();
    lock_mod.validate(&parsed, diagnostics) catch return error.OutOfMemory;
    // errorCount は累積のため、この検査が追加した分だけを見る。
    if (diagnostics.errorCount() > errors_before) return error.InvalidLock;
    return parsed;
}

/// `nako.toml` の依存宣言のうち mutable path 依存があれば true（--locked
/// 時の E016 説明用）。
fn hasMutablePathDep(manifest: *const manifest_mod.Manifest) bool {
    for ([_]*const manifest_mod.DependencyGroup{ &manifest.dependencies, &manifest.dev_dependencies }) |group| {
        var it = group.path.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.mutable) return true;
        }
    }
    return false;
}

/// lock の freshness 判定に使う入力（manifest hash・profile・features・
/// target）を組み立てる。features の各名前は manifest の定義を指すため
/// `project` が生きている間だけ有効。
fn lockInputFor(a: Allocator, project_: *const project.Project, opts: *const project.PrepareOptions, diagnostics: *diag.List) Error!lock_model.Input {
    const profiles = try project.profilesOf(a, project_, opts.requested_runtime);
    const profile = try project.selectProfile(profiles, opts.profile, diagnostics);
    const record = project.recordOf(profiles, profile) orelse return error.UnknownProfile;
    var expanded = try project.expandRootFeatures(a, &project_.manifest, opts.features, !opts.no_default_features, diagnostics);
    defer expanded.deinit();
    return .{
        .manifest_sha256 = project_.manifest_sha256,
        .profile = profile,
        .features = try project.expandedFeatureNames(a, &expanded),
        .target = .{ .os = record.os, .cpu = record.cpu, .abi = record.abi, .compat_js = (record.compat_js orelse false) or opts.compat_js, .optimize = opts.optimize orelse record.optimize orelse "O0" },
        .runtime = project.resolveRuntime(record),
        .nako_version = try project.resolveVersionText(a, opts.nako_version),
        .cnako_version = try project.resolveVersionText(a, opts.cnako_version),
        .lnako_version = try project.resolveVersionText(a, opts.lnako_version),
    };
}

/// `--locked` の契約を検証する。lock 不足・陳腐・schema/resolver 不一致は
/// `LockedNotSatisfied`。可変 path 依存が再解決を要求する場合は E016 を
/// 報告する。lock の意味検証は `loadExistingLock` で済んでいる前提。
pub fn verifyLocked(
    gpa: Allocator,
    io: std.Io,
    project_: *const project.Project,
    opts: *const project.PrepareOptions,
    diagnostics: *diag.List,
) Error!void {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    const input = try lockInputFor(a, project_, opts, diagnostics);

    var existing = try loadExistingLock(a, io, project_.root, diagnostics);
    defer if (existing) |*lock| lock.deinit();
    const freshness = lock_mod.checkFreshness(if (existing) |*l| l else null, input);
    if (freshness != .fresh) {
        // E016 は manifest 変更により mutable path 依存の再解決が必要に
        // なる場合に限定する（lock 欠落・target/features 変更は E029）。
        if (freshness == .stale_manifest and hasMutablePathDep(&project_.manifest)) {
            try diagnostics.addFmt(diag.E016_UNLOCKED_MUTABLE_PATH, .err, "nako.toml", .{}, "a mutable path dependency requires re-resolution but --locked forbids it", .{});
        } else {
            const reason: []const u8 = switch (freshness) {
                .missing => "nako.lock is missing",
                .stale_schema => "nako.lock has an unknown schemaVersion",
                .stale_resolver => "nako.lock was written by a different resolver version",
                .stale_manifest => "nako.toml changed since nako.lock was written",
                .stale_profile => "the selected profile differs from nako.lock",
                .stale_features => "the selected features differ from nako.lock",
                .stale_target => "the resolved target differs from nako.lock",
                .fresh => unreachable,
            };
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, project.lock_name, .{}, "{s} and --locked forbids updating it", .{reason});
        }
        return error.LockedNotSatisfied;
    }
    // `mutable = false` の pin hash も検証する（内容変更は --locked で
    // 再記録できないため失敗とする）。
    if (existing) |*l| {
        if (try sync_mod.pathPinMismatch(a, io, project_.root, l)) |name| {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, project.lock_name, .{}, "content of pinned path dependency \"{s}\" changed and --locked forbids re-locking", .{name});
            return error.LockedNotSatisfied;
        }
        // mutable path 依存の内容 digest も照合する。manifest が同じでも
        // 宣言 dir の中身が変われば再解決が必要で、--locked はそれを
        // 認めない。
        if (try sync_mod.mutablePathMismatch(a, io, project_.root, l)) |path| {
            try diagnostics.addFmt(diag.E016_UNLOCKED_MUTABLE_PATH, .err, "nako.toml", .{}, "content of mutable path dependency \"{s}\" requires re-resolution but --locked forbids it", .{path});
            return error.LockedNotSatisfied;
        }
    }
}

/// `tree`/`why` など問い合わせ系コマンドのための読み取り専用 lock 取得。
/// `nako.lock` を一切書き換えない。lock 不在は `LockNotFound`、陳腐
/// （manifest/feature/target 不一致・pin hash 不一致）は `StaleLock` を
/// 診断付きで返す。`--locked` 指定時は呼出し側で先に `verifyLocked` を
/// 実行すること（両者とも書き込みを伴わない）。
pub fn loadFreshLock(
    gpa: Allocator,
    io: std.Io,
    project_: *const project.Project,
    opts: *const project.PrepareOptions,
    diagnostics: *diag.List,
) Error!project.LockOutcome {
    const arena_impl = try gpa.create(std.heap.ArenaAllocator);
    arena_impl.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena_impl.deinit();
        gpa.destroy(arena_impl);
    }
    const a = arena_impl.allocator();

    const input = try lockInputFor(a, project_, opts, diagnostics);
    var existing = try loadExistingLock(a, io, project_.root, diagnostics);
    if (existing == null) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, project.lock_name, .{}, "nako.lock is missing; run `lnako lock` first", .{});
        return error.LockNotFound;
    }
    const freshness = lock_mod.checkFreshness(&existing.?, input);
    if (freshness != .fresh) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, project.lock_name, .{}, "nako.lock is stale; run `lnako lock` to update it", .{});
        return error.StaleLock;
    }
    if (try sync_mod.pathPinMismatch(a, io, project_.root, &existing.?)) |name| {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, project.lock_name, .{}, "content of pinned path dependency \"{s}\" does not match nako.lock; run `lnako lock`", .{name});
        return error.StaleLock;
    }
    if (try sync_mod.mutablePathMismatch(a, io, project_.root, &existing.?)) |path| {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, project.lock_name, .{}, "content of mutable path dependency \"{s}\" does not match nako.lock; run `lnako lock`", .{path});
        return error.StaleLock;
    }
    const moved = existing.?;
    existing = null; // 所有権は戻り値へ。
    return .{
        .arena = arena_impl,
        .lock = moved,
        .wrote = false,
        .freshness = .fresh,
        .profile = input.profile,
    };
}

/// `nako.lock` ファイル本体の SHA-256（正規化済み 32byte digest）。
pub fn lockDigest(gpa: Allocator, io: std.Io, project_root: []const u8, out: *[32]u8) Error!bool {
    const bytes = (try readLockBytes(gpa, io, project_root)) orelse return false;
    defer gpa.free(bytes);
    std.crypto.hash.sha2.Sha256.hash(bytes, out, .{});
    return true;
}
