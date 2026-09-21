//! `.npkg` アーカイブの静的生成。
//!
//! package root の `nako.toml` を読み、`package.include`（未指定時は既定除外を
//! 除く全ファイル）で payload を収録し、`NAKO-PKG/METADATA.toml`・
//! `NAKO-PKG/FILES.toml`・`NAKO-PKG/commands.json` を生成して決定的 stored ZIP
//! として出力する。公開前検査として、payload path の規範性・exports 宣言
//! ファイルの収録・`dependencies.path` のパッケージ境界を検証する。
//! 初期化コードや任意のパッケージコードは実行しない。
//!
//! 形式・検証要件は `docs/package-system/SPECIFICATION.md` §6。

const std = @import("std");
const zip = @import("../archive/zip.zig");
const diag = @import("diagnostics.zig");
const glob = @import("glob.zig");
const manifest_mod = @import("manifest.zig");
const npkg_commands = @import("npkg_commands.zig");
const npkg_commands_gen = @import("npkg_commands_gen.zig");
const npkg_files = @import("npkg_files.zig");
const npkg_metadata = @import("npkg_metadata.zig");

const Allocator = std.mem.Allocator;

/// 単一 payload の読み込み上限。巨大アセット混入による暴走を防ぐ。
const max_file_size = 256 * 1024 * 1024;

/// `package.include` 未指定時に収録から除く名前（任意の深さの path 成分）。
const default_excludes = [_][]const u8{
    ".git",
    ".zig-cache",
    "zig-out",
    "node_modules",
    ".nako",
    "nako.lock",
    ".DS_Store",
};

/// 生成結果。全メモリは内蔵 arena が所有する。
pub const Built = struct {
    arena: std.heap.ArenaAllocator,
    /// 決定的 stored ZIP のバイト列。
    archive: []u8,
    /// payload 索引（`path` バイト順）。
    files: []npkg_files.FileEntry,

    pub fn deinit(self: *Built) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn report(diagnostics: *diag.List, code: []const u8, path: []const u8, comptime format: []const u8, args: anytype) !void {
    try diagnostics.addFmt(code, .err, path, .{}, format, args);
}

fn isExcluded(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        for (default_excludes) |excluded| {
            if (std.mem.eql(u8, component, excluded)) return true;
        }
    }
    return false;
}

fn hasGlobSyntax(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?[{") != null;
}

/// `include` パターン1件が `path` を拾うか。glob を含まないパターンは
/// ファイル名一致に加えて directory 接頭辞としても扱う。
fn includePatternMatches(pattern: []const u8, path: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, pattern, "/");
    if (trimmed.len == 0) return false;
    if (hasGlobSyntax(trimmed)) return glob.match(trimmed, path);
    if (std.mem.eql(u8, trimmed, path)) return true;
    return std.mem.startsWith(u8, path, trimmed) and path.len > trimmed.len and path[trimmed.len] == '/';
}

fn matchesInclude(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |pattern| {
        if (includePatternMatches(pattern, path)) return true;
    }
    return false;
}

/// ファイルシステムを `SourceProvider` へ適合させる。path は package root
/// 相対の posix path。見つからない場合は null。
const FsProvider = struct {
    io: std.Io,
    dir: std.Io.Dir,

    fn read(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?[]u8 {
        const self: *FsProvider = @ptrCast(@alignCast(context));
        return self.dir.readFileAlloc(self.io, path, allocator, .limited(max_file_size)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    fn provider(self: *FsProvider) npkg_commands_gen.SourceProvider {
        return .{ .context = self, .readFn = read };
    }
};

const Payload = struct {
    path: []const u8,
    data: []u8,
};

fn payloadLessThan(_: void, a: Payload, b: Payload) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// package root 以下を走査して収録対象ファイル一覧を返す（ソート済み）。
/// `include` 指定時はパターン適合のみ、未指定時は既定除外以外の全ファイル。
fn collectPayloads(
    allocator: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    include: ?[]const []const u8,
    diagnostics: *diag.List,
) ![]Payload {
    var payloads: std.ArrayList(Payload) = .empty;
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |walked| {
        if (walked.kind == .directory) continue;
        const path = try allocator.dupe(u8, walked.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        if (walked.kind != .file) {
            try report(diagnostics, diag.E040_NPKG_NONCANONICAL_PATH, path, "payload \"{s}\" is not a regular file", .{path});
            continue;
        }
        if (isExcluded(path)) continue;
        if (include) |patterns| {
            if (!matchesInclude(patterns, path)) continue;
        }
        if (!npkg_files.isCanonicalPath(path) or npkg_files.isMetadataPath(path)) {
            try report(diagnostics, diag.E040_NPKG_NONCANONICAL_PATH, path, "payload path \"{s}\" is not a canonical package path", .{path});
            continue;
        }
        const data = dir.readFileAlloc(io, path, allocator, .limited(max_file_size)) catch |err| switch (err) {
            error.FileNotFound => {
                try report(diagnostics, diag.E036_NPKG_MISSING_ENTRY, path, "payload \"{s}\" disappeared while reading", .{path});
                continue;
            },
            else => return err,
        };
        try payloads.append(allocator, .{ .path = path, .data = data });
    }
    const items = try payloads.toOwnedSlice(allocator);
    std.mem.sort(Payload, items, {}, payloadLessThan);
    return items;
}

/// exports が参照する payload path を検証する。宣言された source/native/esm
/// artifact が収録されていなければ `E036`。
fn checkExportPaths(allocator: Allocator, manifest: *const manifest_mod.Manifest, payloads: []Payload, diagnostics: *diag.List) !void {
    var present: std.StringHashMapUnmanaged(void) = .empty;
    for (payloads) |payload| try present.put(allocator, payload.path, {});
    for (manifest.exports) |export_entry| {
        if (export_entry.path) |path| {
            if (!present.contains(path)) {
                try report(diagnostics, diag.E036_NPKG_MISSING_ENTRY, path, "export \"{s}\" source \"{s}\" is not included in the package", .{ export_entry.name, path });
            }
        }
        for ([_][]const manifest_mod.ArtifactDecl{ export_entry.native, export_entry.esm }) |decls| {
            for (decls) |decl| {
                if (!present.contains(decl.path)) {
                    try report(diagnostics, diag.E036_NPKG_MISSING_ENTRY, decl.path, "export \"{s}\" artifact \"{s}\" is not included in the package", .{ export_entry.name, decl.path });
                }
            }
        }
    }
}

/// `dependencies.path` がパッケージ境界の外を指さないか検証する。
fn checkPathDependencies(allocator: Allocator, manifest: *const manifest_mod.Manifest, diagnostics: *diag.List) !void {
    var iterator = manifest.dependencies.path.valueIterator();
    while (iterator.next()) |dep| {
        // base を空にして package root 直下からの相対解決とする。
        if ((try npkg_commands_gen.resolveImport(allocator, "", dep.path)) == null) {
            try report(diagnostics, diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY, dep.path, "path dependency \"{s}\" escapes the package root", .{dep.path});
        }
    }
}

/// `root`（`nako.toml` を含む directory）から `.npkg` バイト列を生成する。
/// 失敗時は diagnostics へ記録して `error.InvalidPackage` を返す。
pub fn build(backing_allocator: Allocator, io: std.Io, root: []const u8, diagnostics: *diag.List) !Built {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const prior_errors = diagnostics.errorCount();

    const manifest_source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fs.path.join(allocator, &.{ root, "nako.toml" }),
        allocator,
        .limited(max_file_size),
    );
    const manifest = manifest_mod.parse(allocator, manifest_source, diagnostics) catch |err| switch (err) {
        error.InvalidManifest => return error.InvalidPackage,
        else => return err,
    };

    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    const payloads = try collectPayloads(allocator, io, dir, manifest.package.include, diagnostics);
    try checkExportPaths(allocator, &manifest, payloads, diagnostics);
    try checkPathDependencies(allocator, &manifest, diagnostics);
    if (payloads.len == 0) {
        try report(diagnostics, diag.E036_NPKG_MISSING_ENTRY, root, "package contains no distributable payload files", .{});
    }

    // commands.json: 収録されたなでしこソースを入口として静的索引を生成する。
    var entry_paths: std.ArrayList([]const u8) = .empty;
    for (payloads) |payload| {
        const extension = std.fs.path.extension(payload.path);
        if (std.ascii.eqlIgnoreCase(extension, ".nako3") or
            std.ascii.eqlIgnoreCase(extension, ".dncl") or
            std.ascii.eqlIgnoreCase(extension, ".dncl2"))
        {
            try entry_paths.append(allocator, payload.path);
        }
    }
    var fs_provider = FsProvider{ .io = io, .dir = dir };
    var generated = npkg_commands_gen.generate(allocator, fs_provider.provider(), entry_paths.items, diagnostics) catch |err| switch (err) {
        error.InvalidCommands => return error.InvalidPackage,
        else => return err,
    };
    defer generated.deinit();
    var commands_buffer: std.Io.Writer.Allocating = .init(allocator);
    try npkg_commands.emit(allocator, generated.commands, &commands_buffer.writer);
    const commands_json = try commands_buffer.toOwnedSlice();

    const metadata_toml = try npkg_metadata.toBytes(allocator, &manifest);

    var file_entries = try allocator.alloc(npkg_files.FileEntry, payloads.len);
    var entries: std.ArrayList(zip.WriteEntry) = .empty;
    try entries.append(allocator, .{ .name = npkg_files.metadata_entry, .data = metadata_toml });
    try entries.append(allocator, .{ .name = npkg_files.commands_entry, .data = commands_json });
    for (payloads, 0..) |payload, index| {
        file_entries[index] = .{
            .path = payload.path,
            .sha256 = blk: {
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(payload.data, &digest, .{});
                break :blk digest;
            },
            .size = payload.data.len,
        };
        try entries.append(allocator, .{ .name = payload.path, .data = payload.data });
    }
    var files_buffer: std.Io.Writer.Allocating = .init(allocator);
    try npkg_files.emit(allocator, file_entries, &files_buffer.writer);
    try entries.append(allocator, .{ .name = npkg_files.files_entry, .data = try files_buffer.toOwnedSlice() });

    if (diagnostics.errorCount() > prior_errors) return error.InvalidPackage;

    // 全割当が完了した後に arena を移す。
    return .{
        .arena = arena,
        .archive = try zip.writeEntries(allocator, entries.items),
        .files = file_entries,
    };
}

test {
    _ = @import("npkg_test.zig");
}
