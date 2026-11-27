//! パッケージ仕様 v1 §6.3（アーティファクト選択）。
//!
//! 選択済みの版について、クライアントはランタイムごとの優先順位で
//! `artifacts` を走査し、最初に適合するものを採用する。
//!
//! - `lnako`: `native-prebuilt` → 明示許可済みの `native-source` → `universal`
//! - `cnako` / `wnako`: 対象 `runtimes` を含む `esm` → `universal`
//!
//! `native-source` はルートが Package ID とアーティファクトの SHA-256 の
//! 組に対して明示許可した場合だけ採用する。未許可の `native-source` は
//! 読み飛ばして `universal` を探し、他の適合候補がなければ
//! `SourcePermissionRequired` を返す。ビルドの実行はこのモジュールの
//! 責務ではない。
//!
//! 診断は `evaluate` の失敗値と `formatFailure` が返す。`lnako` の非対応
//! 診断には利用可能な `runtimes` と `target_triple` を含める（§6.3 MUST）。

const std = @import("std");
const types = @import("v1_types.zig");

const Allocator = std.mem.Allocator;

/// ランタイムが対応する ABI の閉区間。`min <= max` でなければならない。
pub const AbiRange = struct {
    min: u32 = 1,
    max: u32 = 1,
};

/// 選択対象の実行環境。
///
/// `target_triple` は `native-prebuilt` の照合にだけ使う。`cnako` / `wnako`
/// では未使用なので `null` でよい。`glibc` は GNU Linux の `native-prebuilt` を
/// 評価するときだけ使う。`abi` は `native-prebuilt` と `native-source` の
/// 双方に適用する。
pub const Target = struct {
    runtime: types.Runtime,
    target_triple: ?[]const u8 = null,
    abi: AbiRange = .{},
    glibc: ?[]const u8 = null,

    pub fn forLnako(target_triple: ?[]const u8, abi: AbiRange, glibc: ?[]const u8) Target {
        return .{
            .runtime = .lnako,
            .target_triple = target_triple,
            .abi = abi,
            .glibc = glibc,
        };
    }

    pub fn forRuntime(runtime: types.Runtime) Target {
        return .{ .runtime = runtime };
    }
};

/// `native-source` のローカルビルド許可。Package ID と SHA-256 の組で固定する。
/// 同じ ID でもハッシュが変われば別の許可が必要になる（§6.3 MUST）。
pub const SourcePermission = struct {
    id: []const u8,
    sha256: []const u8,
};

pub const FailureKind = enum {
    /// どの候補も対象ランタイム・triple・ABI・glibc に適合しない。
    no_compatible_artifact,
    /// ABI は適合する `native-source` があるが、ID と SHA-256 の明示許可がない。
    source_permission_required,
    /// `Target` 自体が不正（ABI 範囲の逆転など）。
    invalid_target,
};

/// 選択に失敗した理由。`artifacts` と `target` は呼び出し側の所有物を借用する。
pub const Failure = struct {
    kind: FailureKind,
    id: []const u8,
    target: Target,
    artifacts: []const types.Artifact,
};

pub const Evaluation = union(enum) {
    selected: usize,
    failed: Failure,
};

pub const SelectError = error{
    NoCompatibleArtifact,
    SourcePermissionRequired,
    InvalidTarget,
};

/// §6.3 の優先順位でアーティファクトを選択し、`artifacts` の添字を返す。
///
/// 失敗時は `NoCompatibleArtifact`、`SourcePermissionRequired`、
/// `InvalidTarget` のいずれかを返す。詳細な診断が必要なら `evaluate` と
/// `formatFailure` を使う。
pub fn select(
    id: []const u8,
    artifacts: []const types.Artifact,
    target: Target,
    permissions: []const SourcePermission,
) SelectError!usize {
    return switch (evaluate(id, artifacts, target, permissions)) {
        .selected => |index| index,
        .failed => |failure| switch (failure.kind) {
            .no_compatible_artifact => error.NoCompatibleArtifact,
            .source_permission_required => error.SourcePermissionRequired,
            .invalid_target => error.InvalidTarget,
        },
    };
}

/// `select` と同じ判定を、失敗理由を保持したまま返す。
pub fn evaluate(
    id: []const u8,
    artifacts: []const types.Artifact,
    target: Target,
    permissions: []const SourcePermission,
) Evaluation {
    if (target.abi.min > target.abi.max) {
        return .{ .failed = .{
            .kind = .invalid_target,
            .id = id,
            .target = target,
            .artifacts = artifacts,
        } };
    }

    return switch (target.runtime) {
        .lnako => evaluateLnako(id, artifacts, target, permissions),
        .cnako, .wnako => evaluateScriptRuntime(id, artifacts, target),
    };
}

fn evaluateLnako(
    id: []const u8,
    artifacts: []const types.Artifact,
    target: Target,
    permissions: []const SourcePermission,
) Evaluation {
    // ① native-prebuilt。宣言順ではなく種別の優先順位で先に走査する。
    for (artifacts, 0..) |artifact, index| {
        if (isPrebuiltEligible(artifact, target)) return .{ .selected = index };
    }

    // ② native-source。許可のない候補は飛ばし、許可済みの候補だけを採る。
    var unpermitted_source = false;
    for (artifacts, 0..) |artifact, index| {
        if (!isSourceShapeEligible(artifact, target)) continue;
        if (!sourcePermitted(id, artifact.sha256, permissions)) {
            unpermitted_source = true;
            continue;
        }
        return .{ .selected = index };
    }

    // ③ universal。ここまでで適合しなければ共通実装へフォールバックする。
    for (artifacts, 0..) |artifact, index| {
        if (isUniversalEligible(artifact, target)) return .{ .selected = index };
    }

    return .{ .failed = .{
        .kind = if (unpermitted_source) .source_permission_required else .no_compatible_artifact,
        .id = id,
        .target = target,
        .artifacts = artifacts,
    } };
}

fn evaluateScriptRuntime(
    id: []const u8,
    artifacts: []const types.Artifact,
    target: Target,
) Evaluation {
    // ① 対象 runtime を含む esm。
    for (artifacts, 0..) |artifact, index| {
        if (artifact.kind != .esm) continue;
        if (!runtimeIncluded(artifact.runtimes, target.runtime)) continue;
        return .{ .selected = index };
    }

    // ② universal。
    for (artifacts, 0..) |artifact, index| {
        if (isUniversalEligible(artifact, target)) return .{ .selected = index };
    }

    return .{ .failed = .{
        .kind = .no_compatible_artifact,
        .id = id,
        .target = target,
        .artifacts = artifacts,
    } };
}

fn isPrebuiltEligible(artifact: types.Artifact, target: Target) bool {
    if (artifact.kind != .@"native-prebuilt") return false;
    if (!runtimeIncluded(artifact.runtimes, .lnako)) return false;
    const target_triple = target.target_triple orelse return false;

    const artifact_triple = artifact.target_triple orelse return false;
    if (!std.mem.eql(u8, artifact_triple, target_triple)) return false;

    const abi = artifact.abi_version orelse return false;
    if (!abiInRange(abi, target.abi)) return false;

    // GNU Linux だけ glibc 下限を検査する。非 GNU の triple では
    // `glibc_min` を持たないのが仕様であり、ここでは関与しない。
    if (isGnuLinuxTriple(artifact_triple)) {
        const minimum = artifact.glibc_min orelse return false;
        const host = target.glibc orelse return false;
        if (!versionAtLeast(host, minimum)) return false;
    }
    return true;
}

fn isSourceShapeEligible(artifact: types.Artifact, target: Target) bool {
    if (artifact.kind != .@"native-source") return false;
    if (!runtimeIncluded(artifact.runtimes, .lnako)) return false;
    const abi = artifact.abi_version orelse return false;
    return abiInRange(abi, target.abi);
}

fn isUniversalEligible(artifact: types.Artifact, target: Target) bool {
    return artifact.kind == .universal and runtimeIncluded(artifact.runtimes, target.runtime);
}

fn abiInRange(abi: u32, range: AbiRange) bool {
    return abi >= range.min and abi <= range.max;
}

fn runtimeIncluded(runtimes: []const types.Runtime, runtime: types.Runtime) bool {
    for (runtimes) |candidate| {
        if (candidate == runtime) return true;
    }
    return false;
}

/// Package ID とアーティファクト SHA-256 の組が明示許可に一致するか。
///
/// 選択器とローカルビルドの両方がこの関数を使い、同じ規則で許可を
/// 検査する。空の SHA-256 は決して許可しない。
pub fn isSourcePermitted(id: []const u8, sha256: []const u8, permissions: []const SourcePermission) bool {
    // 空ハッシュ同士を一致扱いにしない。ハッシュが不明な候補は許可しない。
    if (sha256.len == 0) return false;
    for (permissions) |permission| {
        if (permission.sha256.len == 0) continue;
        if (!std.mem.eql(u8, permission.id, id)) continue;
        if (std.mem.eql(u8, permission.sha256, sha256)) return true;
    }
    return false;
}

fn sourcePermitted(id: []const u8, sha256: []const u8, permissions: []const SourcePermission) bool {
    return isSourcePermitted(id, sha256, permissions);
}

fn isGnuLinuxTriple(triple: []const u8) bool {
    return std.mem.endsWith(u8, triple, "-linux-gnu");
}

/// ドット区切りの数値バージョンを比較し、`host >= minimum` なら true。
/// 末尾の 0 は省略と同値に扱う（例: `2.31` と `2.31.0`）。
fn versionAtLeast(host: []const u8, minimum: []const u8) bool {
    var host_parts = std.mem.splitScalar(u8, host, '.');
    var minimum_parts = std.mem.splitScalar(u8, minimum, '.');
    while (true) {
        const host_part = host_parts.next();
        const minimum_part = minimum_parts.next();
        if (host_part == null and minimum_part == null) return true;

        const host_value = if (host_part) |part| parseVersionPart(part) orelse return false else 0;
        const minimum_value = if (minimum_part) |part| parseVersionPart(part) orelse return false else 0;
        if (host_value > minimum_value) return true;
        if (host_value < minimum_value) return false;
    }
}

fn parseVersionPart(part: []const u8) ?u32 {
    if (part.len == 0) return null;
    return std.fmt.parseUnsigned(u32, part, 10) catch null;
}

/// 失敗理由を読みやすい診断へ書き出す。`lnako` の非対応時は、比較に使った
/// 実行環境と、入力に現れた `runtimes` / `target_triple` を列挙する。
pub fn writeFailure(failure: Failure, writer: anytype) !void {
    switch (failure.kind) {
        .invalid_target => {
            try writer.print(
                "invalid target for {s}: runtime {s}, ABI range {d}..{d} is reversed",
                .{ failure.id, @tagName(failure.target.runtime), failure.target.abi.min, failure.target.abi.max },
            );
        },
        .source_permission_required => {
            try writer.print(
                "native-source for {s} requires explicit permission on runtime {s} target_triple={s} (abi {d}..{d}); no universal fallback was selected. Allow the Package ID and the exact artifact sha256 before building.",
                .{
                    failure.id,
                    @tagName(failure.target.runtime),
                    printableTriple(failure.target),
                    failure.target.abi.min,
                    failure.target.abi.max,
                },
            );
            for (failure.artifacts) |artifact| {
                if (!isSourceShapeEligible(artifact, failure.target)) continue;
                try writer.print(" [native-source sha256={s}]", .{printableSha(artifact.sha256)});
            }
        },
        .no_compatible_artifact => {
            try writer.print(
                "no compatible artifact for {s} on runtime {s} (target_triple={s}, abi {d}..{d}, glibc={s}); available artifacts:",
                .{
                    failure.id,
                    @tagName(failure.target.runtime),
                    printableTriple(failure.target),
                    failure.target.abi.min,
                    failure.target.abi.max,
                    failure.target.glibc orelse "-",
                },
            );
            for (failure.artifacts, 0..) |artifact, index| {
                try writer.print(
                    " [{d}] kind={s} runtimes=[",
                    .{ index, @tagName(artifact.kind) },
                );
                for (artifact.runtimes, 0..) |runtime, runtime_index| {
                    if (runtime_index > 0) try writer.writeAll(", ");
                    try writer.writeAll(@tagName(runtime));
                }
                try writer.print("] target_triple={s} abi=", .{artifact.target_triple orelse "-"});
                if (artifact.abi_version) |abi| {
                    try writer.print("{d}", .{abi});
                } else {
                    try writer.writeAll("-");
                }
                try writer.print(" glibc_min={s}", .{artifact.glibc_min orelse "-"});
            }
        },
    }
}

/// `writeFailure` の結果を呼び出し側のアロケータで確保して返す。
pub fn formatFailure(allocator: Allocator, failure: Failure) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var sink = ArrayListSink{ .list = &out, .allocator = allocator };
    try writeFailure(failure, &sink);
    return out.toOwnedSlice(allocator);
}

const ArrayListSink = struct {
    list: *std.ArrayList(u8),
    allocator: Allocator,

    pub fn print(self: *ArrayListSink, comptime format: []const u8, args: anytype) !void {
        try self.list.print(self.allocator, format, args);
    }

    pub fn writeAll(self: *ArrayListSink, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

fn printableTriple(target: Target) []const u8 {
    return target.target_triple orelse "-";
}

fn printableSha(sha256: []const u8) []const u8 {
    return if (sha256.len == 0) "-" else sha256;
}

test {
    _ = @import("v1_selection_test.zig");
}
