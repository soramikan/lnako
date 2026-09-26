//! `nako.toml` 書換え後のロールバック。edit lock は lnako 同士しか
//! 直列化しないため、書込み後に外部エディタが保存した内容を
//! `original` で上書きしない。

const std = @import("std");
const lnako = @import("lnako");
const shared = @import("project.zig");

const diag = lnako.package.diagnostics;

const Allocator = std.mem.Allocator;
const CliError = shared.CliError;
const fail = shared.fail;
const failProject = shared.failProject;

pub const RestoreResult = enum { restored, conflict, failed };

/// `path` の現行内容が `expected`（直前に書いた候補テキスト）と一致する
/// 場合のみ `original` へ復元する。内容が異なる（外部編集・削除・読取
/// 不能を含む）場合は `conflict` を返してそのまま残す。
pub fn restoreManifest(io: std.Io, a: Allocator, path: []const u8, expected: []const u8, original: []const u8) RestoreResult {
    const current = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch {
        return .conflict;
    };
    if (!std.mem.eql(u8, current, expected)) return .conflict;
    writeAtomic(io, path, original) catch return .failed;
    return .restored;
}

/// lock 更新失敗時の共通処理。manifest が外部変更されていなければ
/// `original` へ復元して元の失敗を報告し、変更済みなら内容を残して
/// 競合として報告する。
pub fn failLockedEdit(
    a: Allocator,
    io: std.Io,
    path: []const u8,
    expected: []const u8,
    original: []const u8,
    verb: []const u8,
    err: anyerror,
    diagnostics: *diag.List,
    stderr: *std.Io.Writer,
) CliError {
    switch (restoreManifest(io, a, path, expected, original)) {
        .restored => return failProject(stderr, verb, err, diagnostics, path),
        .conflict => return fail(stderr, "{s}: lock の更新に失敗し、さらに nako.toml がこのコマンドの外で変更されました。manifest は外部変更のまま残しています: 内容を確認してやり直してください\n", .{verb}),
        .failed => return fail(stderr, "{s}: lock の更新に失敗し、manifest の復元にも失敗しました。nako.toml を手動で確認してください\n", .{verb}),
    }
}

pub fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

test "restoreManifest は直前書込みと一致する時だけ元へ戻す" {
    // edit lock は lnako 同士しか直列化しない。writeAtomic 後に外部
    // エディタが manifest を保存していた場合、original で上書きすると
    // ユーザの編集を失うため、現行内容が候補と一致する時だけ復元する。
    const io = std.testing.io;
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const abs = try temporary.dir.realPathFileAlloc(io, ".", a);
    const manifest_path = try std.fs.path.join(a, &.{ abs, "nako.toml" });

    // 内容が候補のまま → 復元される。
    try writeAtomic(io, manifest_path, "edited");
    try std.testing.expectEqual(RestoreResult.restored, restoreManifest(io, a, manifest_path, "edited", "original"));
    try std.testing.expectEqualStrings("original", try temporary.dir.readFileAlloc(io, "nako.toml", a, .unlimited));

    // 外部編集が入った場合はその内容を残して conflict。
    try writeAtomic(io, manifest_path, "edited");
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = "external" });
    try std.testing.expectEqual(RestoreResult.conflict, restoreManifest(io, a, manifest_path, "edited", "original"));
    try std.testing.expectEqualStrings("external", try temporary.dir.readFileAlloc(io, "nako.toml", a, .unlimited));

    // 削除も外部変更として残す（manifest を復活させない）。
    try temporary.dir.deleteFile(io, "nako.toml");
    try std.testing.expectEqual(RestoreResult.conflict, restoreManifest(io, a, manifest_path, "edited", "original"));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(io, "nako.toml", .{}));
}

test "failLockedEdit は外部変更を残して競合として失敗する" {
    const io = std.testing.io;
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const abs = try temporary.dir.realPathFileAlloc(io, ".", a);
    const manifest_path = try std.fs.path.join(a, &.{ abs, "nako.toml" });
    try writeAtomic(io, manifest_path, "edited");
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = "external" });

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var err: std.Io.Writer.Allocating = .init(a);
    const conflicted = failLockedEdit(
        a,
        io,
        manifest_path,
        "edited",
        "original",
        "add",
        error.TestFail,
        &diagnostics,
        &err.writer,
    );
    try std.testing.expectEqual(error.Failed, conflicted);
    // 外部変更の内容が保持される。
    try std.testing.expectEqualStrings("external", try temporary.dir.readFileAlloc(io, "nako.toml", a, .unlimited));
    // 外部変更が無い場合は復元して元の失敗を報告する。
    try writeAtomic(io, manifest_path, "edited");
    const restored = failLockedEdit(
        a,
        io,
        manifest_path,
        "edited",
        "original",
        "add",
        error.TestFail,
        &diagnostics,
        &err.writer,
    );
    try std.testing.expectEqual(error.Failed, restored);
    try std.testing.expectEqualStrings("original", try temporary.dir.readFileAlloc(io, "nako.toml", a, .unlimited));
}
