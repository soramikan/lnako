//! package 宣言命令 metadata の OS 条件（`when` / `min-os` / `libc`）評価。
//!
//! 対象 package の manifest（`nako.toml`、materialize 済みなら
//! `NAKO-PKG/METADATA.toml`）にある export artifact 宣言だけを読み、
//! 現在の target で利用可能かを三値で返す。plugin の初期化・dlopen・
//! JS 実行は一切行わない（Issue #52 の OS 条件照合表示）。
//!
//! - 共通 `.nako3` export（`path`）は OS に依存しない。
//! - artifact 宣言の `when` は marker 式を target で評価する。`features`
//!   だけは宣言命令の OS 利用可否に影響しないため未確定として扱い、
//!   OS/CPU/ABI などで偽が確定した式だけを不適合にする。
//! - `min-os` / `libc` は target 側の値が分からない場合「不適合」ではなく
//!   「不明」にする（適合を証明できないことを不適合と混同しない）。

const std = @import("std");
const builtin = @import("builtin");
const diag = @import("diagnostics.zig");
const lock_mod = @import("lock.zig");
const manifest_mod = @import("manifest.zig");
const marker_mod = @import("marker.zig");

const Allocator = std.mem.Allocator;

/// 現在の target での利用可否。`unknown` は対象側の情報不足で
/// 適合・不適合のどちらも証明できない状態。
pub const Availability = enum {
    available,
    unavailable,
    unknown,
};

pub fn availabilityText(availability: Availability) []const u8 {
    return switch (availability) {
        .available => "available",
        .unavailable => "unavailable",
        .unknown => "unknown",
    };
}

/// 1 package 分の OS 条件表示。`condition` は全 OS なら "全 OS"、
/// 条件付き実装があれば `" | "` 連結（例: `全 OS | os == 'windows'`）。
pub const PackageCondition = struct {
    package_key: []const u8,
    condition: []const u8,
    availability: Availability,
};

pub const Target = manifest_mod.ArtifactTarget;

fn defaultTarget() Target {
    return .{ .runtime = "lnako" };
}

/// `nako.lock` の `input.target` を評価用 target へ写す。lock が無い・
/// 読めない・壊れている場合は null（利用可否は unknown として扱う）。
/// 返す文字列は `arena` が所有する（lock の arena は呼出し内で解放する）。
pub fn targetFromLock(
    gpa: Allocator,
    io: std.Io,
    project_root: []const u8,
    arena: Allocator,
) error{OutOfMemory}!?Target {
    const lock_path = std.fs.path.join(gpa, &.{ project_root, "nako.lock" }) catch return error.OutOfMemory;
    defer gpa.free(lock_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, lock_path, gpa, .limited(manifest_mod.max_manifest_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(bytes);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var diagnostics = diag.List.init(gpa);
    defer diagnostics.deinit();
    var lock = lock_mod.parse(scratch.allocator(), bytes, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (diagnostics.errorCount() > 0) return null;
    defer lock.deinit();
    const resolved = try targetOfLock(arena, &lock);
    return resolved;
}

fn targetOfLock(arena: Allocator, lock: *const lock_mod.Lock) error{OutOfMemory}!Target {
    const target = lock.input.target;
    return .{
        .runtime = try arena.dupe(u8, lock.input.runtime orelse "lnako"),
        .os = try arena.dupe(u8, target.os),
        .cpu = try arena.dupe(u8, target.cpu),
        .abi = try arena.dupe(u8, target.abi),
        .os_version = if (target.os_version) |version| try arena.dupe(u8, version) else null,
        .compat_js = target.compat_js,
        .optimize = try arena.dupe(u8, target.optimize),
    };
}

/// 1 package の manifest から OS 条件と現在の target での利用可否を求める。
/// 戻り値の文字列は `arena`（= 呼出し側の Report arena）が所有する。
/// manifest が見つからない・読めない・解析できない場合は条件 "不明"、
/// 利用可否 `unknown`（利用不可と断言しない）。
pub fn evaluatePackage(
    arena: Allocator,
    gpa: Allocator,
    io: std.Io,
    project_root: []const u8,
    package_rel_path: []const u8,
    package_key: []const u8,
    target: ?Target,
) error{OutOfMemory}!PackageCondition {
    const key = try arena.dupe(u8, package_key);
    const manifest = readPackageManifest(gpa, io, project_root, package_rel_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ManifestUnreadable => return .{
            .package_key = key,
            .condition = try arena.dupe(u8, "不明"),
            .availability = .unknown,
        },
    };
    var owned = manifest;
    defer owned.deinit();
    return evaluateManifest(arena, gpa, &owned, key, target);
}

const ManifestReadError = error{ OutOfMemory, ManifestUnreadable };

fn readPackageManifest(
    gpa: Allocator,
    io: std.Io,
    project_root: []const u8,
    package_rel_path: []const u8,
) ManifestReadError!manifest_mod.Manifest {
    var package_dir = openPackageDir(gpa, io, project_root, package_rel_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ManifestUnreadable,
    };
    defer package_dir.close(io);

    const candidates = [_]struct { path: []const u8, npkg: bool }{
        .{ .path = "nako.toml", .npkg = false },
        .{ .path = "NAKO-PKG" ++ std.fs.path.sep_str ++ "METADATA.toml", .npkg = true },
    };
    for (candidates) |candidate| {
        const bytes = package_dir.readFileAlloc(io, candidate.path, gpa, .limited(manifest_mod.max_manifest_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer gpa.free(bytes);
        var diagnostics = diag.List.init(gpa);
        defer diagnostics.deinit();
        // manifest parse は検証エラー時に error.InvalidManifest を返し、
        // diagnostics には既存分がある場合もあるため戻り値だけで判定する。
        // 正本の `nako.toml` が存在して壊れている場合は、配布メタデータへ
        // 黙ってフォールバックせず未検査（ManifestUnreadable）に倒す。
        const parsed = (if (candidate.npkg)
            manifest_mod.parseNpkgMetadata(gpa, bytes, &diagnostics)
        else
            manifest_mod.parse(gpa, bytes, &diagnostics)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => if (candidate.npkg) continue else return error.ManifestUnreadable,
        };
        return parsed;
    }
    return error.ManifestUnreadable;
}

fn openPackageDir(
    gpa: Allocator,
    io: std.Io,
    project_root: []const u8,
    package_rel_path: []const u8,
) !std.Io.Dir {
    const path = resolvePackagePath(gpa, project_root, package_rel_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsafePath => return error.UnsafePath,
    };
    defer gpa.free(path);
    // 途中 path の symlink 追従は許可する（`/tmp`→`/private/tmp` のような
    // 正当な構成や、trust 検査済みの宣言 path を扱うため）。ここは読取り
    // だけを行い、package tree 自体の信頼境界は env_state/sync 側が担う。
    return std.Io.Dir.openDirAbsolute(io, path, .{});
}

/// environment.json の package `path` は host 形式と `/` 形式の双方が
/// 現れ得るため、比較・open 前に host の区切り文字へ揃える。
fn resolvePackagePath(gpa: Allocator, project_root: []const u8, package_rel_path: []const u8) (Allocator.Error || error{UnsafePath})![]u8 {
    if (std.mem.indexOfScalar(u8, package_rel_path, 0) != null) return error.UnsafePath;
    const buffer = try gpa.alloc(u8, package_rel_path.len);
    defer gpa.free(buffer);
    for (package_rel_path, 0..) |byte, index| {
        // Windows の fixture/手書き環境は `/` と `\\` が混在し得る。
        // POSIX では `\\` が正当なファイル名文字なので変換しない。
        buffer[index] = if (byte == '/' or (builtin.os.tag == .windows and byte == '\\')) std.fs.path.sep else byte;
    }
    return std.fs.path.resolve(gpa, &.{ project_root, buffer });
}

/// 解析済み manifest の export artifact 宣言を target で評価する。
fn evaluateManifest(
    arena: Allocator,
    gpa: Allocator,
    manifest: *const manifest_mod.Manifest,
    package_key: []const u8,
    target: ?Target,
) error{OutOfMemory}!PackageCondition {
    const effective_target = target orelse defaultTarget();
    var has_source = false;
    var saw_unconditional = false;
    var has_esm = false;
    var decl_count: usize = 0;
    var any_pass = false;
    var any_unknown = false;

    // 条件文字列は宣言順・重複なしで保持する。
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(gpa);

    for (manifest.exports) |export_decl| {
        if (export_decl.path != null) has_source = true;
        if (export_decl.esm.len > 0) has_esm = true;
        // ESM artifact は compat-js 前提のため OS 条件表示の対象外。
        for (export_decl.native) |decl| {
            decl_count += 1;
            const evaluated = try evaluateArtifact(arena, gpa, decl, effective_target);
            switch (evaluated.result) {
                .pass => any_pass = true,
                .unknown => any_unknown = true,
                .fail => {},
            }
            if (evaluated.text) |text| {
                if (!containsText(texts.items, text)) try texts.append(gpa, text);
            } else {
                saw_unconditional = true;
            }
        }
    }

    var condition: []const u8 = "不明";
    if (texts.items.len > 0 or has_source or saw_unconditional) {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(gpa);
        if (has_source or saw_unconditional) {
            try joined.appendSlice(gpa, "全 OS");
        }
        for (texts.items) |text| {
            if (joined.items.len > 0) try joined.appendSlice(gpa, " | ");
            try joined.appendSlice(gpa, text);
        }
        if (joined.items.len > 0) condition = try arena.dupe(u8, joined.items);
    }

    const availability: Availability = blk: {
        // source・無条件 native は target 不明でも全 OS で利用できる。
        if (has_source or saw_unconditional) break :blk .available;
        // target 不明時は marker の結果を信用しない（runtime 単独条件などが
        // 空 target で偽陽性の available にならないように unknown 固定）。
        if (target == null) break :blk .unknown;
        if (any_pass) break :blk .available;
        // ESM が併存する package は --compat-js で利用でき得るため、
        // native の不一致だけで「利用不可」と断定しない。
        if (decl_count == 0 or any_unknown or has_esm) break :blk .unknown;
        break :blk .unavailable;
    };

    return .{
        .package_key = package_key,
        .condition = condition,
        .availability = availability,
    };
}

/// 宣言1件の評価結果。`unknown` は対象側の情報不足。
const DeclOutcome = enum { pass, fail, unknown };

const ArtifactEvaluation = struct {
    result: DeclOutcome,
    /// 条件付き宣言の表示テキスト。無条件宣言は null。
    text: ?[]const u8,
};

fn evaluateArtifact(
    arena: Allocator,
    gpa: Allocator,
    decl: manifest_mod.ArtifactDecl,
    target: Target,
) error{OutOfMemory}!ArtifactEvaluation {
    // 結果テキストは Report arena が所有する（呼出し側の一覧が借用する）。
    // ArenaAllocator の free は末尾確保を巻き戻し得るため、`deinit` せず
    // arena 全体の解放に委ねる。
    var parts: std.ArrayList([]const u8) = .empty;
    var result: DeclOutcome = .pass;

    if (decl.when) |text| {
        try parts.append(arena, text);
        const outcome = evaluateWhen(gpa, text, target) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        result = mergeResult(result, outcome);
    }
    if (decl.min_os) |min_os| {
        try parts.append(arena, try std.fmt.allocPrint(arena, "min-os {s}", .{min_os}));
        const outcome: DeclOutcome = if (target.os_version) |version|
            if (manifest_mod.compareDottedVersion(version, min_os)) |order|
                if (order >= 0) .pass else .fail
            else
                .unknown
        else
            .unknown;
        result = mergeResult(result, outcome);
    }
    if (decl.features.len > 0) {
        // feature 選択に依存する artifact は OS 可否として確定できない。
        var feature_text: std.ArrayList(u8) = .empty;
        try feature_text.appendSlice(arena, "features [");
        for (decl.features, 0..) |feature, index| {
            if (index > 0) try feature_text.appendSlice(arena, ", ");
            try feature_text.appendSlice(arena, feature);
        }
        try feature_text.appendSlice(arena, "]");
        try parts.append(arena, feature_text.items);
        result = mergeResult(result, .unknown);
    }
    if (decl.libc) |libc| {
        try parts.append(arena, try std.fmt.allocPrint(arena, "libc {s}", .{libc}));
        const target_libc = if (target.libc) |value| value else target.abi;
        const outcome: DeclOutcome = if (target_libc.len == 0)
            .unknown
        else if (std.mem.eql(u8, target_libc, libc))
            .pass
        else
            .fail;
        result = mergeResult(result, outcome);
    }

    if (parts.items.len == 0) return .{ .result = result, .text = null };
    var joined: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |part, index| {
        if (index > 0) try joined.appendSlice(arena, ", ");
        try joined.appendSlice(arena, part);
    }
    return .{ .result = result, .text = joined.items };
}

fn evaluateWhen(gpa: Allocator, text: []const u8, target: Target) error{OutOfMemory}!DeclOutcome {
    var parsed = marker_mod.parse(gpa, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    switch (parsed) {
        .err => return .unknown,
        .ok => |*marker| {
            defer marker.deinit();
            const outcome = marker.evaluatePartial(.{
                .runtime = target.runtime,
                .os = target.os,
                .cpu = target.cpu,
                .abi = target.abi,
                .compat_js = target.compat_js,
                .optimize = target.optimize,
                .version = target.version,
                // features は OS 利用可否に影響しないため未確定として評価する。
            }, .initOne(.features)) catch return .unknown;
            return switch (outcome) {
                .pass => .pass,
                .fail => .fail,
                .unknown => .unknown,
            };
        },
    }
}

fn mergeResult(current: DeclOutcome, next: DeclOutcome) DeclOutcome {
    if (current == .fail or next == .fail) return .fail;
    if (current == .unknown or next == .unknown) return .unknown;
    return .pass;
}

fn containsText(items: []const []const u8, text: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, text)) return true;
    return false;
}

const testing = std.testing;
const test_sandbox = @import("test_sandbox.zig");

fn writePackage(dir: std.Io.Dir, io: std.Io, manifest_source: []const u8) !void {
    try dir.createDirPath(io, "pkg");
    try dir.writeFile(io, .{ .sub_path = "pkg/nako.toml", .data = manifest_source });
}

fn evaluateFixture(arena: Allocator, dir: std.Io.Dir, io: std.Io, target: ?Target) !PackageCondition {
    const root = try dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    return evaluatePackage(arena, testing.allocator, io, root, "pkg", "pkg:test", target);
}

test "OS条件: 無条件のsource exportは全OSで利用可能" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\path = "src/test.nako3"
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" });
    try testing.expectEqual(Availability.available, result.availability);
    try testing.expectEqualStrings("全 OS", result.condition);
}

test "OS条件: 現在のOSと一致しないnative宣言は利用不可" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = { path = "lib/win.dll", when = "os == 'windows'" }
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" });
    try testing.expectEqual(Availability.unavailable, result.availability);
    try testing.expectEqualStrings("os == 'windows'", result.condition);
}

test "OS条件: 現在のOSと一致するnative宣言は利用可能" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = { path = "lib/mac.dylib", when = "os == 'macos' and cpu == 'aarch64'" }
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" });
    try testing.expectEqual(Availability.available, result.availability);
    try testing.expectEqualStrings("os == 'macos' and cpu == 'aarch64'", result.condition);
}

test "OS条件: source無しで複数OS向けnative宣言は条件を並べる" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = [
        \\  { path = "lib/win.dll", when = "os == 'windows'" },
        \\  { path = "lib/linux.so", when = "os == 'linux'" },
        \\]
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" });
    try testing.expectEqual(Availability.unavailable, result.availability);
    try testing.expectEqualStrings("os == 'windows' | os == 'linux'", result.condition);
}

test "OS条件: 条件付きnativeと共通sourceは全OS+条件を表示し利用可能" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\path = "src/test.nako3"
        \\native = { path = "lib/win.dll", when = "os == 'windows'" }
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" });
    try testing.expectEqual(Availability.available, result.availability);
    try testing.expectEqualStrings("全 OS | os == 'windows'", result.condition);
}

test "OS条件: min-os/libcはtarget値が不明なら不適合にしない" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = { path = "lib/libpod.dylib", min-os = "14.0", libc = "gnu" }
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const unknown = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" });
    try testing.expectEqual(Availability.unknown, unknown.availability);
    try testing.expectEqualStrings("min-os 14.0, libc gnu", unknown.condition);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const satisfied = try evaluateFixture(arena2.allocator(), temporary.dir, io, .{
        .runtime = "lnako",
        .os = "macos",
        .cpu = "aarch64",
        .abi = "gnu",
        .os_version = "15.1",
        .libc = "gnu",
    });
    try testing.expectEqual(Availability.available, satisfied.availability);

    var arena3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena3.deinit();
    const unsatisfied = try evaluateFixture(arena3.allocator(), temporary.dir, io, .{
        .runtime = "lnako",
        .os = "macos",
        .cpu = "aarch64",
        .abi = "gnu",
        .os_version = "13.0",
        .libc = "gnu",
    });
    try testing.expectEqual(Availability.unavailable, unsatisfied.availability);
}

test "OS条件: target不明なら利用可否はunknownで条件は表示する" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = { path = "lib/win.dll", when = "os == 'windows'" }
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, null);
    try testing.expectEqual(Availability.unknown, result.availability);
    try testing.expectEqualStrings("os == 'windows'", result.condition);
}

test "OS条件: ESMのみのpackageはruntime前提のため不明として扱う" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\esm = { path = "lib/index.mjs", when = "os == 'macos'" }
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" });
    try testing.expectEqual(Availability.unknown, result.availability);
    try testing.expectEqualStrings("不明", result.condition);
}

test "OS条件: features指定だけのartifactは不明として表示する" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = { path = "lib/mac.dylib", features = ["with-gpu"] }
        \\[features]
        \\with-gpu = []
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" });
    try testing.expectEqual(Availability.unknown, result.availability);
    try testing.expectEqualStrings("features [with-gpu]", result.condition);
}

test "OS条件: target不明でも共通sourceは全OSで利用可能" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\path = "src/test.nako3"
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, null);
    try testing.expectEqual(Availability.available, result.availability);
    try testing.expectEqualStrings("全 OS", result.condition);
}

test "OS条件: libcはtargetにabiもlibcも無ければ不明" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = { path = "lib/libpod.so", libc = "musl" }
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "linux" });
    try testing.expectEqual(Availability.unknown, result.availability);
    try testing.expectEqualStrings("libc musl", result.condition);
}

test "OS条件: native不適合でもESM併存なら利用不可と断定しない" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = { path = "lib/win.dll", when = "os == 'windows'" }
        \\esm = { path = "lib/index.mjs" }
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" });
    try testing.expectEqual(Availability.unknown, result.availability);
    try testing.expectEqualStrings("os == 'windows'", result.condition);
}

test "OS条件: target不明時はruntime条件の偽陽性で利用可能にしない" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try writePackage(temporary.dir, io,
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = { path = "lib/index.node", when = "runtime == 'lnako'" }
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, null);
    try testing.expectEqual(Availability.unknown, result.availability);
    try testing.expectEqualStrings("runtime == 'lnako'", result.condition);
}

test "OS条件: manifestが無いpackageは不明として扱う" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.createDirPath(io, "pkg");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos" });
    try testing.expectEqual(Availability.unknown, result.availability);
    try testing.expectEqualStrings("不明", result.condition);
}

test "OS条件: materialize済みNAKO-PKG/METADATA.tomlから条件を読む" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.createDirPath(io, "pkg/NAKO-PKG");
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/NAKO-PKG/METADATA.toml", .data =
        \\schemaVersion = 1
        \\nativePluginAbi = "lnako_plugin_v1"
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = { path = "lib/mac.dylib", when = "os == 'macos'" }
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" });
    try testing.expectEqual(Availability.available, result.availability);
    try testing.expectEqualStrings("os == 'macos'", result.condition);
}

test "OS条件: 壊れたnako.tomlはMETADATAへフォールバックせず不明" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.createDirPath(io, "pkg/NAKO-PKG");
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/nako.toml", .data = "[package\nname = broken" });
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/NAKO-PKG/METADATA.toml", .data =
        \\schemaVersion = 1
        \\nativePluginAbi = "lnako_plugin_v1"
        \\[package]
        \\name = "test"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = { path = "lib/mac.dylib", when = "os == 'macos'" }
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try evaluateFixture(arena.allocator(), temporary.dir, io, .{ .runtime = "lnako", .os = "macos" });
    try testing.expectEqual(Availability.unknown, result.availability);
    try testing.expectEqualStrings("不明", result.condition);
}

test "OS条件: nako.lockからtargetを読む" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data =
        \\{"schemaVersion":1,"resolverVersion":1,"input":{"manifestSha256":"sha256:0000000000000000000000000000000000000000000000000000000000000000","profile":"default","features":[],"target":{"os":"linux","cpu":"x86_64","abi":"gnu"},"runtime":"lnako"},"packages":{}}
    });
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const target = (try targetFromLock(testing.allocator, io, root, arena.allocator())) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("linux", target.os);
    try testing.expectEqualStrings("x86_64", target.cpu);
    try testing.expectEqualStrings("lnako", target.runtime);
}

test "OS条件: lockが無ければtargetはnull" {
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try targetFromLock(testing.allocator, io, root, arena.allocator())) == null);
}

/// `check --json` の `commands.conditions` を決定的に組み立てる。
pub fn conditionsJson(gpa: Allocator, conditions: []const PackageCondition) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "[");
    for (conditions, 0..) |condition, index| {
        if (index > 0) try out.appendSlice(gpa, ",");
        const package_key = try std.json.Stringify.valueAlloc(gpa, condition.package_key, .{});
        defer gpa.free(package_key);
        const condition_text = try std.json.Stringify.valueAlloc(gpa, condition.condition, .{});
        defer gpa.free(condition_text);
        const item = try std.fmt.allocPrint(
            gpa,
            "{{\"package\":{s},\"condition\":{s},\"availability\":\"{s}\"}}",
            .{ package_key, condition_text, availabilityText(condition.availability) },
        );
        defer gpa.free(item);
        try out.appendSlice(gpa, item);
    }
    try out.appendSlice(gpa, "]");
    return out.toOwnedSlice(gpa);
}
