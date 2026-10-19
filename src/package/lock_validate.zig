//! nako.lock の意味検証。`parse`（`lock.zig`）が受理した lock の package
//! 集合・artifact・profile・rootDependencies を schema 契約と target
//! profile に照合して診断する。

const std = @import("std");
const semver = @import("semver.zig");
const diag = @import("diagnostics.zig");
const manifest_mod = @import("manifest.zig");
const model = @import("lock_model.zig");

const Allocator = std.mem.Allocator;

const Target = model.Target;
const ProfileRecord = model.ProfileRecord;
const Artifact = model.Artifact;
const PackageEntry = model.PackageEntry;
const Lock = model.Lock;
const lock_schema_version = model.lock_schema_version;
const legacy_lock_schema_version = model.legacy_lock_schema_version;
const resolver_version = model.resolver_version;
const testing = std.testing;
const containsString = model.containsString;
const packageMapsEql = model.packageMapsEql;
const sharedArtifactMismatch = model.sharedArtifactMismatch;
const known_artifact_types = model.known_artifact_types;
const known_implementations = model.known_implementations;
const known_profile_runtimes = model.known_profile_runtimes;
const known_profile_os = model.known_profile_os;
const known_profile_cpu = model.known_profile_cpu;
const known_profile_abi = model.known_profile_abi;
const known_optimize = model.known_optimize;

// ---------------------------------------------------------------------------
// 意味検証
// ---------------------------------------------------------------------------

/// `pkg:<32桁小文字16進>` 形式かを判定する。JSON Schema の packageId pattern と
/// 同じ受理集合を Zig 側でも要求する。
fn isValidPublicId(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "pkg:") or text.len != "pkg:".len + 32) return false;
    for (text["pkg:".len..]) |ch| {
        const digit = ch >= '0' and ch <= '9';
        const lower_hex = ch >= 'a' and ch <= 'f';
        if (!digit and !lower_hex) return false;
    }
    return true;
}

fn validatePackageSet(packages: []const PackageEntry, exists: *const std.StringHashMapUnmanaged(void), profile: ?ProfileRecord, target_compat_js: bool, path: []const u8, diagnostics: *diag.List) !void {
    const esm_allowed = target_compat_js or (if (profile) |record| record.allowsEsm() else false);
    for (packages) |package| {
        const package_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.{s}", .{ path, package.id });
        defer diagnostics.allocator.free(package_path);
        const artifacts_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.artifacts", .{package_path});
        defer diagnostics.allocator.free(artifacts_path);
        if (!isValidPublicId(package.id)) {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, package_path, .{}, "invalid package id \"{s}\" (expected pkg:<32hex>)", .{package.id});
        }
        _ = semver.Version.parse(package.version) catch {
            try diagnostics.addFmt(diag.E024_INVALID_SEMVER, .err, package_path, .{}, "invalid package version \"{s}\" (not semver)", .{package.version});
        };
        if (package.artifacts.len == 0) {
            try diagnostics.addFmt(diag.E008_MISSING_ARTIFACT, .err, artifacts_path, .{}, "package {s} has no artifacts", .{package.id});
        }
        for (package.artifacts) |artifact| {
            if (!artifact.isKnownKind()) {
                const artifact_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.artifacts.{s}", .{ package_path, artifact.key });
                defer diagnostics.allocator.free(artifact_path);
                try diagnostics.addFmt(diag.E007_UNKNOWN_ARTIFACT_KIND, .err, artifact_path, .{}, "unknown artifact kind \"{s}\" at {s}.artifacts.{s}", .{ artifact.kind, package_path, artifact.key });
            }
            if (artifact.type) |artifact_type| {
                if (!containsString(&known_artifact_types, artifact_type)) {
                    const artifact_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.artifacts.{s}", .{ package_path, artifact.key });
                    defer diagnostics.allocator.free(artifact_path);
                    try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, artifact_path, .{}, "unknown artifact type \"{s}\"", .{artifact_type});
                }
            }
        }
        // source dependency の source artifact は取得済み tree 全体を指す
        // container。native/ESM export はその tree 内 manifest から sync が
        // 選び直すため、個別 download artifact の一致を要求しない。
        const source_container = if (package.source) |source|
            (source.kind == .path or source.kind == .git or source.kind == .http) and package.hasKind("source")
        else
            false;
        // 選択された実装種別に対応する artifact が存在しなければ同期できない。
        if (package.implementation) |implementation| {
            if (!containsString(&known_implementations, implementation)) {
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, package_path, .{}, "unknown implementation \"{s}\"", .{implementation});
            } else if (std.mem.eql(u8, implementation, "ESM") and !esm_allowed) {
                try diagnostics.addFmt(diag.E006_JS_IN_NORMAL_MODE, .err, artifacts_path, .{}, "ESM implementation selected without compat-js profile", .{});
            } else if (!std.mem.eql(u8, implementation, "none") and !package.hasKind(implementation) and !source_container) {
                try diagnostics.addFmt(diag.E008_MISSING_ARTIFACT, .err, artifacts_path, .{}, "selected implementation \"{s}\" has no matching artifact", .{implementation});
            }
        }
        for (package.dependencies) |dependency| {
            const dependencies_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.dependencies", .{package_path});
            defer diagnostics.allocator.free(dependencies_path);
            if (!isValidPublicId(dependency)) {
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, dependencies_path, .{}, "invalid dependency id \"{s}\" (expected pkg:<32hex>)", .{dependency});
            }
            if (!exists.contains(dependency)) {
                try diagnostics.addFmt(diag.E013_MISSING_PACKAGE, .err, dependencies_path, .{}, "dependency {s} not found in lock packages", .{dependency});
            }
        }
    }
}

fn buildIdSet(gpa: Allocator, packages: []const PackageEntry) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    for (packages) |package| {
        try set.put(gpa, package.id, {});
    }
    return set;
}

const KnownField = struct {
    name: []const u8,
    value: []const u8,
    known: []const []const u8,
};

fn validateKnownFields(fields: []const KnownField, base: []const u8, label: []const u8, diagnostics: *diag.List) !void {
    for (fields) |field| {
        if (containsString(field.known, field.value)) continue;
        const path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.{s}", .{ base, field.name });
        defer diagnostics.allocator.free(path);
        try diagnostics.addFmt(diag.E014_INVALID_PROFILE, .err, path, .{}, "{s} has invalid {s}: {s}", .{ label, field.name, field.value });
    }
}

/// profile 条件の runtime・os・cpu・abi・optimize を manifest と同じ既知値で検証する。
fn validateProfileRecord(name: []const u8, record: ProfileRecord, diagnostics: *diag.List) !void {
    const base = try std.fmt.allocPrint(diagnostics.allocator, "nako.lock.profiles.{s}", .{name});
    defer diagnostics.allocator.free(base);

    if (record.runtime) |runtime| {
        if (!containsString(&known_profile_runtimes, runtime)) {
            const path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.runtime", .{base});
            defer diagnostics.allocator.free(path);
            try diagnostics.addFmt(diag.E014_INVALID_PROFILE, .err, path, .{}, "profile \"{s}\" has invalid runtime: {s}", .{ name, runtime });
        }
    }
    try validateKnownFields(&.{
        .{ .name = "os", .value = record.os, .known = &known_profile_os },
        .{ .name = "cpu", .value = record.cpu, .known = &known_profile_cpu },
        .{ .name = "abi", .value = record.abi, .known = &known_profile_abi },
    }, base, "profile", diagnostics);
    // optimize は JSON Schema / manifest と同じく E029 で報告する。
    if (record.optimize) |optimize| {
        if (!containsString(&known_optimize, optimize)) {
            const path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.optimize", .{base});
            defer diagnostics.allocator.free(path);
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, path, .{}, "profile \"{s}\" has invalid optimize: {s}", .{ name, optimize });
        }
    }
}

fn validateTarget(target: Target, path: []const u8, diagnostics: *diag.List) !void {
    try validateKnownFields(&.{
        .{ .name = "os", .value = target.os, .known = &known_profile_os },
        .{ .name = "cpu", .value = target.cpu, .known = &known_profile_cpu },
        .{ .name = "abi", .value = target.abi, .known = &known_profile_abi },
    }, path, "input.target", diagnostics);
    if (target.os_version) |os_version| {
        if (manifest_mod.compareDottedVersion(os_version, os_version) == null) {
            const os_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.osVersion", .{path});
            defer diagnostics.allocator.free(os_path);
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, os_path, .{}, "invalid osVersion \"{s}\" (expected dotted numeric version)", .{os_version});
        }
    }
}

fn validateInputEngineVersion(version: ?[]const u8, field: []const u8, diagnostics: *diag.List) !void {
    const value = version orelse return;
    _ = semver.Version.parse(value) catch {
        const path = try std.fmt.allocPrint(diagnostics.allocator, "nako.lock.input.{s}", .{field});
        defer diagnostics.allocator.free(path);
        try diagnostics.addFmt(diag.E024_INVALID_SEMVER, .err, path, .{}, "invalid engine version \"{s}\" (not semver)", .{value});
    };
}

pub const ValidateOptions = struct {
    /// project 側の更新経路（`loadExistingLock`）では旧 resolver の lock
    /// を再生成対象として読み込むため、resolverVersion 差は
    /// `checkFreshness` の `stale_resolver` へ委ねてここでは拒否しない。
    /// manifest 無しの lock 駆動 `sync` は既定の strict を使う。
    allow_stale_resolver: bool = false,
};

/// lock の意味的な整合性を検証する。既知の診断は SPECIFICATION.md §8 と対応する。
/// 未対応の resolverVersion を含め全項目を strict に検査する。
pub fn validate(lock: *const Lock, diagnostics: *diag.List) !void {
    return validateWith(lock, diagnostics, .{});
}

/// `options` で緩和しつつ lock の意味的な整合性を検証する。
pub fn validateWith(lock: *const Lock, diagnostics: *diag.List, options: ValidateOptions) !void {
    if (lock.schema_version != lock_schema_version and lock.schema_version != legacy_lock_schema_version) {
        try diagnostics.addFmt(diag.E002_UNKNOWN_LOCK_SCHEMA, .err, "nako.lock.schemaVersion", .{}, "unknown lock schema version {d}", .{lock.schema_version});
    }
    // 未対応の resolverVersion も受理しない。nako.toml の無い lock 駆動
    // project では manifest 再解決の入口を経由しないため、`sync --locked`
    // が未知版の lock をそのまま環境へ適用しないようここで拒否する。
    // project 側（manifest あり・非 --locked）では `loadExistingLock` が
    // `allow_stale_resolver` で読み込み、鮮度検査の `stale_resolver` が
    // 再解決へ回す。
    if (lock.resolver_version != resolver_version and !options.allow_stale_resolver) {
        try diagnostics.addFmt(diag.E002_UNKNOWN_LOCK_SCHEMA, .err, "nako.lock.resolverVersion", .{}, "unknown lock resolver version {d}", .{lock.resolver_version});
    }

    var profile_names: std.StringHashMapUnmanaged(void) = .empty;
    defer profile_names.deinit(diagnostics.allocator);
    for (lock.profiles) |profile| {
        const gop = try profile_names.getOrPut(diagnostics.allocator, profile.name);
        if (gop.found_existing) {
            const path = try std.fmt.allocPrint(diagnostics.allocator, "nako.lock.profiles.{s}", .{profile.name});
            defer diagnostics.allocator.free(path);
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, path, .{}, "duplicate profile \"{s}\"", .{profile.name});
        }
        try validateProfileRecord(profile.name, profile.record, diagnostics);
    }

    // `input.target` も profile と同じ既知値集合で検証する。
    try validateTarget(lock.input.target, "nako.lock.input.target", diagnostics);
    try validateInputEngineVersion(lock.input.nako_version, "nakoVersion", diagnostics);
    try validateInputEngineVersion(lock.input.cnako_version, "cnakoVersion", diagnostics);
    try validateInputEngineVersion(lock.input.lnako_version, "lnakoVersion", diagnostics);

    var id_set = try buildIdSet(diagnostics.allocator, lock.packages);
    defer id_set.deinit(diagnostics.allocator);

    if (lock.profileRecord(lock.input.profile) == null) {
        try diagnostics.addFmt(diag.E030_UNKNOWN_PROFILE, .err, "nako.lock.input.profile", .{}, "unknown profile \"{s}\"", .{lock.input.profile});
    }
    const selected = lock.profileRecord(lock.input.profile);
    // 選択 profile の環境条件は `input.target` と一致していなければならない。
    if (selected) |record| {
        if (!std.mem.eql(u8, record.os, lock.input.target.os) or
            !std.mem.eql(u8, record.cpu, lock.input.target.cpu) or
            !std.mem.eql(u8, record.abi, lock.input.target.abi))
        {
            try diagnostics.addFmt(diag.E014_INVALID_PROFILE, .err, "nako.lock.input.target", .{}, "input.target does not match profile \"{s}\" os/cpu/abi", .{lock.input.profile});
        }
    }
    try validatePackageSet(lock.packages, &id_set, if (selected) |record| record.* else null, lock.input.target.compat_js, "nako.lock.packages", diagnostics);

    var profile_package_names: std.StringHashMapUnmanaged(void) = .empty;
    defer profile_package_names.deinit(diagnostics.allocator);
    for (lock.profile_packages) |profile| {
        var profile_id_set = try buildIdSet(diagnostics.allocator, profile.packages);
        defer profile_id_set.deinit(diagnostics.allocator);
        const profile_path = try std.fmt.allocPrint(diagnostics.allocator, "nako.lock.profilePackages.{s}", .{profile.profile});
        defer diagnostics.allocator.free(profile_path);
        const gop = try profile_package_names.getOrPut(diagnostics.allocator, profile.profile);
        if (gop.found_existing) {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, profile_path, .{}, "duplicate profilePackages entry \"{s}\"", .{profile.profile});
        }
        const record = lock.profileRecord(profile.profile);
        if (record == null) {
            try diagnostics.addFmt(diag.E030_UNKNOWN_PROFILE, .err, profile_path, .{}, "unknown profile \"{s}\"", .{profile.profile});
        }
        // `packages` は選択された `input.profile` のグラフの正本である。
        // profilePackages に同じ profile がある場合は一致を要求する。
        if (record != null and std.mem.eql(u8, profile.profile, lock.input.profile) and !packageMapsEql(lock.packages, profile.packages)) {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, profile_path, .{}, "profilePackages.{s} does not match packages", .{profile.profile});
        }
        const target_compat_js = std.mem.eql(u8, profile.profile, lock.input.profile) and lock.input.target.compat_js;
        try validatePackageSet(profile.packages, &profile_id_set, if (record) |value| value.* else null, target_compat_js, profile_path, diagnostics);
    }

    var root_profile_names: std.StringHashMapUnmanaged(void) = .empty;
    defer root_profile_names.deinit(diagnostics.allocator);
    for (lock.root_dependencies) |root_profile| {
        const path = try std.fmt.allocPrint(diagnostics.allocator, "nako.lock.rootDependencies.{s}", .{root_profile.profile});
        defer diagnostics.allocator.free(path);
        const gop = try root_profile_names.getOrPut(diagnostics.allocator, root_profile.profile);
        if (gop.found_existing) try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, path, .{}, "duplicate rootDependencies profile \"{s}\"", .{root_profile.profile});
        const packages = lock.packagesForProfile(root_profile.profile) orelse {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, path, .{}, "rootDependencies references profile without package graph \"{s}\"", .{root_profile.profile});
            continue;
        };
        for (root_profile.dependencies, 0..) |dependency_id, index| {
            const id_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}[{d}]", .{ path, index });
            defer diagnostics.allocator.free(id_path);
            if (containsString(root_profile.dependencies[0..index], dependency_id)) {
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, id_path, .{}, "duplicate root dependency id \"{s}\"", .{dependency_id});
                continue;
            }
            var found_package = false;
            for (packages) |package| {
                if (std.mem.eql(u8, package.id, dependency_id)) {
                    found_package = true;
                    break;
                }
            }
            if (!found_package) try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, id_path, .{}, "unknown root dependency id \"{s}\"", .{dependency_id});
        }
    }
    if (lock.schema_version == lock_schema_version) {
        const selected_roots = lock.rootDependenciesForProfile(lock.input.profile);
        if (selected_roots == null) try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock.rootDependencies", .{}, "rootDependencies is missing selected profile \"{s}\"", .{lock.input.profile});
        for (lock.profile_packages) |profile| {
            if (lock.rootDependenciesForProfile(profile.profile) == null) {
                const path = try std.fmt.allocPrint(diagnostics.allocator, "nako.lock.rootDependencies.{s}", .{profile.profile});
                defer diagnostics.allocator.free(path);
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, path, .{}, "rootDependencies is missing profile \"{s}\"", .{profile.profile});
            }
        }
    }

    // 複数 profile 形式では `profiles` と `profilePackages` の名前集合が一致
    // しなければならない（片方向の欠落を許すと既存版取得や差分が空になる）。
    // 欠落は直前の集合一致検査と同じ E029 に統一する。`input.profile` 自体が
    // 未定義の場合は上の profileRecord 検査が E030 を報告する。
    // 単一 profile 形式（profilePackages が空）はこの制約の対象外。
    if (lock.profile_packages.len > 0) {
        for (lock.profiles) |profile| {
            var found = false;
            for (lock.profile_packages) |entry| {
                if (std.mem.eql(u8, entry.profile, profile.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock.profilePackages", .{}, "profilePackages is missing profile \"{s}\"", .{profile.name});
            }
        }
    }

    // lnako/cnako が共用する同一 ID・版の source artifact は同じ hash で
    // 参照しなければならない。
    if (sharedArtifactMismatch(lock)) |mismatch| {
        try diagnostics.addFmt(diag.E009_HASH_MISMATCH, .err, "nako.lock.profilePackages", .{}, "source artifact hash differs across profiles for {s}@{s}", .{ mismatch.id, mismatch.version });
    }
}

// ---------------------------------------------------------------------------
// 複数 profile の共用 artifact 整合性
// ---------------------------------------------------------------------------

test "normal profile permits unselected ESM artifact when native is selected" {
    const artifacts = [_]Artifact{
        .{ .key = "native", .kind = "native" },
        .{ .key = "esm", .kind = "ESM" },
    };
    const packages = [_]PackageEntry{
        .{
            .id = "pkg:11111111111111111111111111111111",
            .name = "dual",
            .version = "1.0.0",
            .implementation = "native",
            .artifacts = &artifacts,
        },
    };
    var exists: std.StringHashMapUnmanaged(void) = .empty;
    defer exists.deinit(testing.allocator);
    var diagnostics = diag.List.init(testing.allocator);
    defer diagnostics.deinit();

    try validatePackageSet(&packages, &exists, .{
        .runtime = "lnako",
        .os = "macos",
        .cpu = "aarch64",
        .abi = "gnu",
    }, false, "packages", &diagnostics);
    try testing.expect(!diagnostics.hasErrors());
}
