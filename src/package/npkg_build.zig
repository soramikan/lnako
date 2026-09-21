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
    /// 解析済み `nako.toml`（出力名の決定等に使う）。
    manifest: manifest_mod.Manifest,

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

/// glob 構文は `*`・`?`・`**` のみ。`[`・`{` は literal として扱うため
/// glob 判定へ含めない（含めると `assets[old]` のような literal
/// directory が接頭辞照合されず配下を取りこぼす）。
fn hasGlobSyntax(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?") != null;
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
/// 相対の posix path。payload に収録されたファイル以外は null を返す
/// （`package.include` で除外された import 先を commands.json へ掲載した
/// まま実体を欠く .npkg が生成されないようにするため）。
const FsProvider = struct {
    io: std.Io,
    dir: std.Io.Dir,
    payloads: *const std.StringHashMapUnmanaged(void),

    fn read(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?[]u8 {
        const self: *FsProvider = @ptrCast(@alignCast(context));
        if (!self.payloads.contains(path)) return null;
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
/// `include` 指定時はパターン適合のみ（既定除外は適用しない）、未指定時は
/// 既定除外以外の全ファイル。`exclude` は生成中の出力 `.npkg` など
/// include 指定に関わらず常に除外する package 相対 path。
fn collectPayloads(
    allocator: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    include: ?[]const []const u8,
    exclude: ?[]const u8,
    diagnostics: *diag.List,
) ![]Payload {
    var payloads: std.ArrayList(Payload) = .empty;
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |walked| {
        if (walked.kind == .directory) continue;
        const path = try allocator.dupe(u8, walked.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        // 収録対象かの判定を先に行う。include・既定除外・出力除外で対象外の
        // symlink/FIFO が「通常ファイルでない」診断を出して build を失敗
        // させないため、kind 検査は収録対象に残った項目へだけ適用する。
        if (exclude) |excluded_path| {
            if (std.mem.eql(u8, path, excluded_path)) continue;
        }
        if (include) |patterns| {
            if (!matchesInclude(patterns, path)) continue;
        } else if (isExcluded(path)) {
            continue;
        }
        if (walked.kind != .file) {
            try report(diagnostics, diag.E040_NPKG_NONCANONICAL_PATH, path, "payload \"{s}\" is not a regular file", .{path});
            continue;
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

/// `dependencies` が配布可能な形か検証する。
/// - `path` 依存: package 境界内の規範 path であり、依存先 manifest
///   （`<path>/nako.toml`）が payload に収録されていること。規範形式でも
///   実体の無い依存は配布先で再現できないため拒否する。絶対パス・空成分・
///   `.`・`..`・バックスラッシュを含む宣言も同様に拒否する。
/// - `pkg` 依存の `profile`: 配布メタデータは `profiles` を含まないため
///   参照を再現できず、持つ依存は配布不能として拒否する。
fn checkDependencies(allocator: Allocator, manifest: *const manifest_mod.Manifest, payloads: []Payload, diagnostics: *diag.List) !void {
    var present: std.StringHashMapUnmanaged(void) = .empty;
    var present_built = false;
    var iterator = manifest.dependencies.path.valueIterator();
    while (iterator.next()) |dep| {
        if (!npkg_files.isCanonicalPath(dep.path)) {
            try report(diagnostics, diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY, dep.path, "path dependency \"{s}\" is not a canonical package-relative path", .{dep.path});
            continue;
        }
        if (!present_built) {
            for (payloads) |payload| try present.put(allocator, payload.path, {});
            present_built = true;
        }
        const dep_manifest = try std.fmt.allocPrint(allocator, "{s}/nako.toml", .{dep.path});
        if (!present.contains(dep_manifest)) {
            try report(diagnostics, diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY, dep.path, "path dependency \"{s}\" has no manifest in the package payload", .{dep.path});
        }
    }
    var pkg_iterator = manifest.dependencies.pkg.valueIterator();
    while (pkg_iterator.next()) |dep| {
        if (dep.profile) |profile| {
            try report(diagnostics, diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY, dep.name, "dependency \"{s}\" uses profile \"{s}\" which .npkg metadata cannot represent", .{ dep.name, profile });
        }
    }
}

/// 出力予定の `.npkg` が package root 内にあれば、その root 相対 path を
/// 返す（収集対象から除外するため）。root 外または比較不能なら null。
fn outputExcludePath(allocator: Allocator, io: std.Io, root: []const u8, output: []const u8) !?[]const u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    const relative = try std.fs.path.relative(allocator, cwd, null, root, output);
    if (relative.len == 0 or std.fs.path.isAbsolute(relative) or
        std.mem.eql(u8, relative, "..") or std.mem.startsWith(u8, relative, "../") or
        std.mem.startsWith(u8, relative, "..\\"))
    {
        return null;
    }
    std.mem.replaceScalar(u8, relative, '\\', '/');
    return relative;
}

/// build の追加オプション。
pub const Options = struct {
    /// 出力予定の `.npkg` path（cwd 相対または絶対）。package root 内に
    /// ある場合は収集対象から除外し、再ビルドで前回成果物が payload に
    /// 混入しないようにする。
    output: ?[]const u8 = null,
};

/// `root`（`nako.toml` を含む directory）から `.npkg` バイト列を生成する。
/// 失敗時は diagnostics へ記録して `error.InvalidPackage` を返す。
pub fn build(backing_allocator: Allocator, io: std.Io, root: []const u8, diagnostics: *diag.List, options: Options) !Built {
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

    // 出力先が package root 内なら収集対象から外し、再ビルドで前回の
    // 成果物が payload へ混入しないようにする。
    const default_output = try std.fmt.allocPrint(allocator, "{s}-{d}.{d}.{d}.npkg", .{
        manifest.package.name,
        manifest.package.version.major,
        manifest.package.version.minor,
        manifest.package.version.patch,
    });
    const exclude = try outputExcludePath(allocator, io, root, options.output orelse default_output);

    const payloads = try collectPayloads(allocator, io, dir, manifest.package.include, exclude, diagnostics);
    try checkExportPaths(allocator, &manifest, payloads, diagnostics);
    try checkDependencies(allocator, &manifest, payloads, diagnostics);
    if (payloads.len == 0) {
        try report(diagnostics, diag.E036_NPKG_MISSING_ENTRY, root, "package contains no distributable payload files", .{});
    }

    // commands.json: 公開入口は `exports[].path` の収録済みソースのみ。
    // そこからの静的 import 閉包は generator が辿る（export されない内部
    // ファイルの公開定義を索引へ混ぜない）。
    var payload_set: std.StringHashMapUnmanaged(void) = .empty;
    for (payloads) |payload| try payload_set.put(allocator, payload.path, {});
    var entry_seen: std.StringHashMapUnmanaged(void) = .empty;
    var entry_paths: std.ArrayList([]const u8) = .empty;
    for (manifest.exports) |export_entry| {
        const path = export_entry.path orelse continue;
        if (!payload_set.contains(path)) continue;
        if ((try entry_seen.getOrPut(allocator, path)).found_existing) continue;
        try entry_paths.append(allocator, path);
    }
    var fs_provider = FsProvider{ .io = io, .dir = dir, .payloads = &payload_set };
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

    const archive = try zip.writeEntries(allocator, entries.items);
    // 全割当が完了した後に arena を移す（戻り値の構造体リテラル内で
    // allocator を使うと、コピー済みの arena 状態に新規 chunk が
    // 含まれず解放漏れになる）。
    return .{
        .arena = arena,
        .archive = archive,
        .files = file_entries,
        .manifest = manifest,
    };
}

test {
    _ = @import("npkg_test.zig");
}
