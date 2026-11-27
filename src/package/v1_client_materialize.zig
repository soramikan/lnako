//! v1 `.npkg` の検証済み展開と materialize。
//!
//! P03 の `v1_archive.verify`（§3.2〜§3.5 の検証）を通ったアーカイブだけを
//! staging dir へ展開し、loader が必要とする exports / global 命令名を返す。
//!
//! 呼び出し順の契約:
//! 1. クライアントは manifest・lock の解決と、index/実バイト列/lock の
//!    SHA-256 照合を *すべて* 完了する。
//! 2. その後で初めて `Materializer.materialize` を呼ぶ。ここでアーカイブを
//!    開く（`v1_archive.verify`）。
//! 3. 選択に使った index の `Artifact` と、アーカイブ内の `METADATA.toml`
//!    （正本）を展開前に照合する。package id・version・kind、正規化済み
//!    runtimes 集合、native の `target_triple`/`abi_version`/`glibc_min` が
//!    一致しなければ何も書かない（同一 ID の複数版を別物として保持する）。
//!
//! `v1_archive.Verified` が公開するスライスはこの関数の実行中だけ借用する。
//! 戻り値 `Result` の文字列はすべて `arena` が所有する複製であり、`Verified`
//! の `deinit` 後も有効である。

const std = @import("std");
const types = @import("v1_types.zig");
const archive_mod = @import("v1_archive.zig");
const env = @import("v1_client_env.zig");

const Allocator = std.mem.Allocator;

pub const Expected = struct {
    id: []const u8,
    version: []const u8,
    kind: types.Kind,
    runtime: types.Runtime,
};

pub const Result = struct {
    exports: []const env.Export,
    exports_global_commands: bool,
    global_commands: []const []const u8,
};

/// 検証済みアーカイブを `dest` へ展開し、loader 用メタデータを返す。
/// 返す文字列はすべて `arena` が所有する。
pub const MaterializeFn = *const fn (
    context: ?*anyopaque,
    io: std.Io,
    gpa: Allocator,
    artifact: *const types.Artifact,
    expected: Expected,
    bytes: []const u8,
    dest: std.Io.Dir,
    arena: Allocator,
) anyerror!Result;

pub const Materializer = struct {
    context: ?*anyopaque = null,
    function: MaterializeFn = defaultMaterialize,

    pub fn materialize(
        self: Materializer,
        io: std.Io,
        gpa: Allocator,
        artifact: *const types.Artifact,
        expected: Expected,
        bytes: []const u8,
        dest: std.Io.Dir,
        arena: Allocator,
    ) !Result {
        return self.function(self.context, io, gpa, artifact, expected, bytes, dest, arena);
    }
};

pub const Error = error{
    ArtifactIdentityMismatch,
    ArtifactKindMismatch,
    ArtifactRuntimeMismatch,
    /// index の target とアーカイブの native 情報が一致しない。
    ArtifactTargetMismatch,
    /// index の digest 形式など、選択済みアーティファクトのメタデータが不正。
    ArtifactMetadataMismatch,
    InvalidEntryPath,
    MissingExportEntry,
    OutOfMemory,
};

/// アーカイブを検証し、選択に使った index の `Artifact` との交叉検査まで
/// 行う。展開はしない。既存世代の再利用時もこの関数を通すことで、同じ
/// SHA-256 のまま index の runtime・native 属性が変わった場合に、実 ZIP を
/// 開かずに世代を再利用することを防ぐ。
pub fn verifyArtifact(
    gpa: Allocator,
    artifact: *const types.Artifact,
    expected: Expected,
    bytes: []const u8,
) !archive_mod.Verified {
    var verified = try archive_mod.verify(gpa, bytes);
    errdefer verified.deinit();
    try validateSelection(artifact, expected, &verified);
    return verified;
}

/// 検証済みアーカイブから loader 用メタデータを複製する。展開は行わない。
/// すべての文字列は `arena` が所有する。
pub fn describe(
    verified: *const archive_mod.Verified,
    gpa: Allocator,
    arena: Allocator,
) !Result {
    var exports: std.ArrayList(env.Export) = .empty;
    var has_global = false;
    for (verified.exports()) |export_entry| {
        const entry_path = verified.metadata_model.selectedEntry(export_entry.subpath) orelse
            return error.MissingExportEntry;
        if (!types.validPath(entry_path)) return error.InvalidEntryPath;
        if (verified.entryBytes(entry_path) == null) return error.MissingExportEntry;
        if (export_entry.binding == .global) has_global = true;
        try exports.append(arena, .{
            .subpath = try arena.dupe(u8, export_entry.subpath),
            .entry = try arena.dupe(u8, entry_path),
            .binding = export_entry.binding,
        });
    }
    if (has_global != verified.commands_model.exports_global_commands) {
        return error.ArtifactMetadataMismatch;
    }

    // `Verified.globalCommandNames` が返す名前は `Verified` の arena を借用
    // する。`Verified` の寿命と切り離すため、各名前を複製する。
    const borrowed_names = try verified.globalCommandNames(gpa);
    defer gpa.free(borrowed_names);
    const global_commands = try arena.alloc([]const u8, borrowed_names.len);
    for (borrowed_names, 0..) |name, name_index| {
        global_commands[name_index] = try arena.dupe(u8, name);
    }

    return .{
        .exports = try exports.toOwnedSlice(arena),
        .exports_global_commands = has_global,
        .global_commands = global_commands,
    };
}

/// 既定実装。P03 の検証器をそのまま使う。
pub fn defaultMaterialize(
    _: ?*anyopaque,
    io: std.Io,
    gpa: Allocator,
    artifact: *const types.Artifact,
    expected: Expected,
    bytes: []const u8,
    dest: std.Io.Dir,
    arena: Allocator,
) anyerror!Result {
    var verified = try verifyArtifact(gpa, artifact, expected, bytes);
    defer verified.deinit();

    // loader 用メタデータも展開前に組み立て、借用元の寿命を閉じる前に複製する。
    const result = try describe(&verified, gpa, arena);

    // 展開対象の全 entry を先に検査し、途中まで書いてから拒否しない。
    var index: usize = 0;
    while (index < verified.entryCount()) : (index += 1) {
        const path = verified.entryPath(index);
        if (!types.validPath(path)) return error.InvalidEntryPath;
        if (verified.entryBytes(path) == null) return error.InvalidEntryPath;
    }

    // 展開は検証済みの entry だけを、決定的な昇順で行う。
    index = 0;
    while (index < verified.entryCount()) : (index += 1) {
        const path = verified.entryPath(index);
        const data = verified.entryBytes(path) orelse return error.InvalidEntryPath;
        try writeEntry(io, dest, path, data);
    }

    return result;
}

/// index の選択結果とアーカイブ正本（`METADATA.toml`）の交叉検査。
///
/// schema・FILES.json のハッシュは `v1_archive.verify` が、index の digest は
/// 取得時の `v1_download.fetch` が既に検証している。ここでは両者の *対応*
/// だけを検査し、検証器を重複実装しない。
fn validateSelection(
    artifact: *const types.Artifact,
    expected: Expected,
    verified: *const archive_mod.Verified,
) Error!void {
    if (!types.validHash(artifact.sha256)) return error.ArtifactMetadataMismatch;

    if (!std.mem.eql(u8, verified.packageId(), expected.id) or
        !std.mem.eql(u8, verified.packageVersion(), expected.version))
    {
        return error.ArtifactIdentityMismatch;
    }
    if (verified.artifactKind() != expected.kind or artifact.kind != expected.kind) {
        return error.ArtifactKindMismatch;
    }

    // runtimes は index・アーカイブとも集合として比較する。アーカイブ側は
    // 検証時に正規化（昇順・重複なし）済みだが、index 側の順序は保証しない。
    const archive_runtimes = runtimeSet(verified.runtimes()) orelse
        return error.ArtifactRuntimeMismatch;
    const index_runtimes = runtimeSet(artifact.runtimes) orelse
        return error.ArtifactRuntimeMismatch;
    if (archive_runtimes != index_runtimes) return error.ArtifactRuntimeMismatch;
    if (!runtimeSetContains(archive_runtimes, expected.runtime)) {
        return error.ArtifactRuntimeMismatch;
    }

    try validateTarget(artifact, verified);
}

fn validateTarget(artifact: *const types.Artifact, verified: *const archive_mod.Verified) Error!void {
    switch (artifact.kind) {
        .universal, .esm => {
            // §4.3: target は null。アーカイブ側も native を持たない。
            if (artifact.target_triple != null or
                artifact.abi_version != null or
                artifact.glibc_min != null)
            {
                return error.ArtifactTargetMismatch;
            }
            if (verified.native() != null) return error.ArtifactTargetMismatch;
        },
        .@"native-source" => {
            // §4.3: index の target は abi_version だけを持つ。ソース用の
            // target_triple/library_path はアーカイブで不要（§3.3）なので、
            // アーカイブが任意で宣言した triple は比較対象にしない。
            if (artifact.target_triple != null or artifact.glibc_min != null) {
                return error.ArtifactTargetMismatch;
            }
            const index_abi = artifact.abi_version orelse return error.ArtifactTargetMismatch;
            const native = verified.native() orelse return error.ArtifactTargetMismatch;
            const archive_abi = native.abi_version orelse return error.ArtifactTargetMismatch;
            if (index_abi != archive_abi) return error.ArtifactTargetMismatch;
            if (native.glibc_min != null) return error.ArtifactTargetMismatch;
        },
        .@"native-prebuilt" => {
            const index_triple = artifact.target_triple orelse
                return error.ArtifactTargetMismatch;
            if (!types.validTargetTriple(index_triple)) return error.ArtifactTargetMismatch;

            const native = verified.native() orelse return error.ArtifactTargetMismatch;
            const archive_triple = native.target_triple orelse
                return error.ArtifactTargetMismatch;
            if (!std.mem.eql(u8, index_triple, archive_triple)) {
                return error.ArtifactTargetMismatch;
            }

            const index_abi = artifact.abi_version orelse return error.ArtifactTargetMismatch;
            const archive_abi = native.abi_version orelse return error.ArtifactTargetMismatch;
            if (index_abi != archive_abi) return error.ArtifactTargetMismatch;

            if (!optionalStringEqual(artifact.glibc_min, native.glibc_min)) {
                return error.ArtifactTargetMismatch;
            }
            if (artifact.glibc_min) |glibc| {
                if (!types.validGlibcVersion(glibc)) return error.ArtifactTargetMismatch;
            }
        },
    }
}

/// runtime の集合をビット集合へ正規化する。重複があれば null。
fn runtimeSet(runtimes: []const types.Runtime) ?u8 {
    var mask: u8 = 0;
    for (runtimes) |runtime| {
        const bit: u8 = @as(u8, 1) << @intCast(@backingInt(runtime));
        if (mask & bit != 0) return null;
        mask |= bit;
    }
    return mask;
}

fn runtimeSetContains(mask: u8, runtime: types.Runtime) bool {
    const bit: u8 = @as(u8, 1) << @intCast(@backingInt(runtime));
    return mask & bit != 0;
}

fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_text| {
        const right_text = right orelse return false;
        return std.mem.eql(u8, left_text, right_text);
    }
    return right == null;
}

fn writeEntry(io: std.Io, dest: std.Io.Dir, rel_path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try dest.createDirPath(io, parent);
    }
    var file = try dest.createFile(io, rel_path, .{
        .exclusive = true,
        .resolve_beneath = true,
    });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

test {
    _ = @import("v1_client_materialize_test.zig");
}
