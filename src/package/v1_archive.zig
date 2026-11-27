//! `.npkg` の生成（pack）と展開前の厳格な検証（verify）。
//!
//! `verify` は §3.2〜§3.5 をメモリ上で検査し、検証済みの METADATA.toml・
//! COMMANDS.json・ファイル索引と、ZIP 内の実バイト列を所有する `Verified`
//! を返す。`pack` はプロジェクトルートと §2 マニフェストから、指定した
//! 種別（universal / esm / native-source / native-prebuilt）の Canonical ZIP
//! を決定的に生成する。
//!
//! 旧制御ファイル（`FILES.toml`・`commands.json`）は `error.LegacyArchive`
//! として拒否し、名前を読み替えたり変換したりしない。
//!
//! LicenseRef の細則（O04）: SPDX 式に現れる `LicenseRef-<id>` それぞれに
//! ついて `LICENSES/LicenseRef-<id>.txt` を要求し、全 `.npkg` に同梱する。
//! 本文が空（空白のみ）の場合は不足として拒否する。

const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml.zig");
const diag = @import("diagnostics.zig");
const glob = @import("glob.zig");
const types = @import("v1_types.zig");
const zip = @import("v1_zip.zig");
const meta = @import("v1_metadata.zig");
const mfiles = @import("v1_metadata_files.zig");
const mcommands = @import("v1_metadata_commands.zig");
const mmanifest = @import("v1_metadata_manifest.zig");
const commands_gen = @import("npkg_commands_gen.zig");

const Allocator = std.mem.Allocator;

pub const metadata_path = "NAKO-PKG/METADATA.toml";
pub const files_path = "NAKO-PKG/FILES.json";
pub const commands_path = "NAKO-PKG/COMMANDS.json";
pub const archive_prefix = "NAKO-PKG/";

const legacy_paths = [_][]const u8{
    "NAKO-PKG/FILES.toml",
    "NAKO-PKG/commands.json",
};

/// 生成側の単一ファイル読み込み上限。総量上限は ZIP 生成時に再計上する。
const max_project_file_bytes: u64 = 256 * 1024 * 1024;

/// 展開前検証を通過した `.npkg`。メタデータは仕様どおり TOML の文書として、
/// 命令索引は JSON の文書として公開し、P04 が `metadata.root` /
/// `commands.value` を直接参照できるようにする。
pub const Verified = struct {
    arena: std.heap.ArenaAllocator,
    archive: zip.Archive,
    files: mfiles.Model,
    metadata: toml.Document,
    metadata_model: meta.Model,
    commands: std.json.Parsed(std.json.Value),
    commands_model: mcommands.Model,

    pub fn deinit(self: *Verified) void {
        self.archive.deinit();
        self.commands.deinit();
        self.metadata.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// アーカイブ内の実バイト列（ZIP の展開結果）。入力バイト列の寿命に
    /// 依存しない。
    pub fn entryBytes(self: *const Verified, path: []const u8) ?[]const u8 {
        return self.archive.entryBytes(path);
    }

    /// 共通 exports のサブパスに対応する実ファイルのバイト列。アーティファクト
    /// 固有の `artifact.entries` があればそちらを優先する。
    pub fn selectedEntry(self: *const Verified, subpath: []const u8) ![]const u8 {
        const path = self.metadata_model.selectedEntry(subpath) orelse
            return error.UnknownExport;
        return self.archive.entryBytes(path) orelse error.MissingEntry;
    }

    pub fn entryCount(self: *const Verified) usize {
        return self.archive.entryCount();
    }

    pub fn entryPath(self: *const Verified, index: usize) []const u8 {
        return self.archive.entryPath(index);
    }

    pub fn packageId(self: *const Verified) []const u8 {
        return self.metadata_model.package.id;
    }

    pub fn packageVersion(self: *const Verified) []const u8 {
        return self.metadata_model.package.version;
    }

    pub fn packageLicense(self: *const Verified) []const u8 {
        return self.metadata_model.package.license;
    }

    pub fn artifactKind(self: *const Verified) types.Kind {
        return self.metadata_model.artifact.kind;
    }

    pub fn runtimes(self: *const Verified) []const types.Runtime {
        return self.metadata_model.artifact.runtimes;
    }

    pub fn native(self: *const Verified) ?meta.Native {
        return self.metadata_model.artifact.native;
    }

    pub fn exports(self: *const Verified) []const meta.Export {
        return self.metadata_model.exports;
    }

    pub fn dependencies(self: *const Verified) []const types.Dependency {
        return self.metadata_model.dependencies;
    }

    pub fn fileEntries(self: *const Verified) []const mfiles.Entry {
        return self.files.files;
    }

    /// global 入口の命令名集合（昇順・重複なし・定数を含まない）。
    pub fn globalCommandNames(self: *const Verified, allocator: Allocator) ![]const []const u8 {
        return mcommands.globalCommandNames(allocator, self.commands_model);
    }
};

/// 既定の上限で `.npkg` バイト列を検証する。
pub fn verify(allocator: Allocator, bytes: []const u8) !Verified {
    return verifyWithLimits(allocator, bytes, .{});
}

pub fn verifyWithLimits(
    allocator: Allocator,
    bytes: []const u8,
    limits: zip.Limits,
) !Verified {
    var archive = try zip.open(allocator, bytes, limits);
    errdefer archive.deinit();

    for (0..archive.entryCount()) |index| {
        const path = archive.entryPath(index);
        if (isLegacyControlPath(path)) return error.LegacyArchive;
        if (std.mem.eql(u8, path, "NAKO-PKG")) return error.UnexpectedControlFile;
        if (std.mem.startsWith(u8, path, archive_prefix) and
            !std.mem.eql(u8, path, metadata_path) and
            !std.mem.eql(u8, path, files_path) and
            !std.mem.eql(u8, path, commands_path))
        {
            return error.UnexpectedControlFile;
        }
    }

    const metadata_bytes = archive.entryBytes(metadata_path) orelse return error.MissingControlFile;
    const files_bytes = archive.entryBytes(files_path) orelse return error.MissingControlFile;
    const commands_bytes = archive.entryBytes(commands_path) orelse return error.MissingControlFile;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const model_allocator = arena.allocator();

    // 旧 METADATA.toml は TOML 構文上のトップレベルキー
    // `schemaVersion` / `schema-version` で識別する。説明文やコメントに
    // 同じ語を含む正当な v1 は拒否しない。読み替えも行わない。
    var parsed_metadata = meta.parse(allocator, metadata_bytes, model_allocator) catch |err| switch (err) {
        error.LegacySchema => return error.LegacyArchive,
        else => return err,
    };
    errdefer parsed_metadata.document.deinit();
    var parsed_commands = try mcommands.parse(allocator, commands_bytes, model_allocator);
    errdefer parsed_commands.document.deinit();
    const files_model = try mfiles.parse(model_allocator, files_bytes);

    try validateCross(&archive, files_model, &parsed_metadata.model, &parsed_commands.model, model_allocator);

    return .{
        .arena = arena,
        .archive = archive,
        .files = files_model,
        .metadata = parsed_metadata.document,
        .metadata_model = parsed_metadata.model,
        .commands = parsed_commands.document,
        .commands_model = parsed_commands.model,
    };
}

fn isLegacyControlPath(path: []const u8) bool {
    for (legacy_paths) |legacy| {
        if (std.mem.eql(u8, path, legacy)) return true;
    }
    return false;
}

/// METADATA と COMMANDS の exports キー集合・binding を一致させる。
fn validateCommandExports(metadata: *const meta.Model, commands: *const mcommands.Model) !void {
    if (metadata.exports.len != commands.exports.len) return error.ExportMismatch;
    for (metadata.exports) |export_entry| {
        const command_export = commands.findExport(export_entry.subpath) orelse
            return error.ExportMismatch;
        if (command_export.binding != export_entry.binding) return error.BindingMismatch;
    }
}

fn validateCross(
    archive: *const zip.Archive,
    files: mfiles.Model,
    metadata: *const meta.Model,
    commands: *const mcommands.Model,
    allocator: Allocator,
) !void {
    try validateCommandExports(metadata, commands);
    if (files.find(metadata_path) == null or files.find(commands_path) == null)
        return error.FileIndexMismatch;

    // exports が選択する実ファイルと native ライブラリの存在。
    for (metadata.exports) |export_entry| {
        const selected = metadata.selectedEntry(export_entry.subpath) orelse
            return error.InvalidMetadata;
        if (!archive.contains(selected)) return error.MissingEntry;
    }
    if (metadata.artifact.kind == .@"native-prebuilt") {
        const native = metadata.artifact.native orelse return error.MissingEntry;
        const library = native.library_path orelse return error.MissingEntry;
        if (!archive.contains(library)) return error.MissingEntry;
    }
    if (metadata.artifact.kind == .@"native-source") {
        if (metadata.artifact.native) |native| {
            if (native.library_path) |library| {
                if (!archive.contains(library)) return error.MissingEntry;
            }
        }
    }

    // LicenseRef の本文。
    const references = try meta.licenseRefs(allocator, metadata.package.license);
    for (references) |reference| {
        const path = try meta.licenseRefPath(allocator, reference);
        const body = archive.entryBytes(path) orelse return error.MissingLicenseText;
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) return error.MissingLicenseText;
        if (files.find(path) == null) return error.FileIndexMismatch;
    }

    // 索引に載る全ファイルと FILES.json を除く全通常ファイルの 1 対 1 対応。
    if (files.files.len != archive.entryCount() - 1) return error.FileIndexMismatch;
    for (0..archive.entryCount()) |index| {
        const path = archive.entryPath(index);
        if (std.mem.eql(u8, path, files_path)) continue;
        const listed = files.find(path) orelse return error.FileIndexMismatch;
        const data = archive.entryBytes(path) orelse return error.FileIndexMismatch;
        if (listed.size != data.len) return error.FileIndexMismatch;
        const digest = mfiles.hash(data);
        if (!std.mem.eql(u8, &listed.sha256, &digest)) return error.HashMismatch;
    }
    for (files.files) |listed| {
        if (archive.entryBytes(listed.path) == null) return error.FileIndexMismatch;
    }
}

pub const PackOptions = struct {
    kind: types.Kind,
    compression: zip.Compression = .stored,
    limits: zip.Limits = .{},
    native: mmanifest.NativeOverrides = .{},
    /// ESM の runtimes をマニフェスト外から固定する場合に指定する。
    esm_runtimes: ?[]const types.Runtime = null,
    /// 明示入力の v1 COMMANDS.json。ESM の JS/TS 入口や native ライブラリの
    /// ように、`.nako3` の静的抽出では実命令を記述できないアーティファクトで
    /// 使う。省略時は従来どおり取り込み閉包から生成する。指定時も exports の
    /// キー集合と binding は METADATA.toml と一致しなければならない。
    commands_json: ?[]const u8 = null,
};

/// プロジェクトルートと §2 マニフェスト（TOML 文書）から `.npkg` を生成する。
/// 同じ入力・同じ pack 版・同じ設定からはバイト単位で一致する。
pub fn pack(
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    manifest_document: *const toml.Document,
    options: PackOptions,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var projection = try mmanifest.project(
        arena,
        manifest_document,
        options.kind,
        options.native,
        options.esm_runtimes,
    );

    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);

    var collector = Collector{
        .allocator = arena,
        .limits = options.limits,
        .files = .empty,
        .index = .empty,
        .uncompressed = 0,
    };
    try collectMatched(&collector, io, directory, projection);
    try addRequiredFiles(&collector, io, directory, projection);

    // native-source は共通 entry（多くの場合 `.nako3`）ではなく、収録した
    // ビルド入力を種別固有の入口にする。複数候補がある場合は推測しない。
    if (projection.model.artifact.kind == .@"native-source") {
        if (try selectedSourceBuildInput(projection, collector.files.items)) |build_input| {
            try mmanifest.projectSourceBuildEntry(arena, &projection, build_input);
        }
    }

    for (projection.model.exports) |export_entry| {
        const selected = projection.model.selectedEntry(export_entry.subpath) orelse
            return error.InvalidMetadata;
        if (!collector.index.contains(selected)) return error.MissingExportEntry;
    }

    const metadata_bytes = try meta.emit(arena, projection.model);
    try collector.addControl(metadata_path, metadata_bytes);
    const commands_bytes = if (options.commands_json) |commands_source|
        try explicitCommands(arena, &projection.model, commands_source)
    else
        try buildCommands(arena, projection.model, &collector);
    try collector.addControl(commands_path, commands_bytes);

    const file_entries = try arena.alloc(mfiles.Entry, collector.files.items.len);
    for (collector.files.items, 0..) |file, index| {
        file_entries[index] = mfiles.entryFor(file.path, file.data);
    }
    const files_bytes = try mfiles.emit(arena, file_entries);
    try collector.addControl(files_path, files_bytes);

    const inputs = try arena.alloc(zip.SourceEntry, collector.files.items.len);
    for (collector.files.items, 0..) |file, index| {
        inputs[index] = .{
            .path = file.path,
            .data = file.data,
            .compression = options.compression,
        };
    }
    return zip.build(allocator, inputs, options.limits);
}

/// P02 の `Manifest`（`pub doc: toml.Document` を持つ）を受け取る薄い適合。
pub fn packManifest(
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    manifest: anytype,
    options: PackOptions,
) ![]u8 {
    return pack(allocator, io, root, &manifest.doc, options);
}

const CollectedFile = struct {
    path: []const u8,
    data: []const u8,
};

const Collector = struct {
    allocator: Allocator,
    limits: zip.Limits,
    files: std.ArrayList(CollectedFile),
    index: std.StringHashMapUnmanaged(usize),
    uncompressed: u64,

    fn addPayload(self: *Collector, path: []const u8, data: []const u8) !void {
        if (self.index.contains(path)) return;
        const added = std.math.add(u64, self.uncompressed, data.len) catch
            return error.UncompressedSizeExceeded;
        if (added > self.limits.max_uncompressed_bytes) return error.UncompressedSizeExceeded;
        try self.files.append(self.allocator, .{ .path = path, .data = data });
        try self.index.put(self.allocator, path, self.files.items.len - 1);
        self.uncompressed = added;
    }

    fn addControl(self: *Collector, path: []const u8, data: []const u8) !void {
        try self.addPayload(path, data);
    }
};

fn isNakoSource(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".nako3") or
        std.ascii.eqlIgnoreCase(extension, ".dncl") or
        std.ascii.eqlIgnoreCase(extension, ".dncl2");
}

const default_exclude_components = [_][]const u8{
    ".git", ".zig-cache", "zig-out", "node_modules", ".nako",
};
const default_excluded_names = [_][]const u8{
    "nako.lock", ".DS_Store",
};

fn isExcludedPath(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        for (default_exclude_components) |excluded| {
            if (std.mem.eql(u8, component, excluded)) return true;
        }
        for (default_excluded_names) |excluded| {
            if (std.mem.eql(u8, component, excluded)) return true;
        }
    }
    return false;
}

fn hasGlobSyntax(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?") != null;
}

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

fn matchesProjection(projection: mmanifest.Projection, path: []const u8) bool {
    if (matchesInclude(projection.universal_include, path)) return true;
    return switch (projection.model.artifact.kind) {
        .esm => matchesInclude(projection.esm_include, path),
        .@"native-source" => matchesInclude(projection.source_include, path),
        else => false,
    };
}

/// `source_include` に一致する収録物から native-source のビルド入力を
/// 選ぶ。候補が一つならそのパス、なければ null を返す。複数の
/// `build.zig` がある場合はどれを選ぶか推測せず `AmbiguousBuildInput` を
/// 返し、呼出し側が `source_include` を絞れるようにする。
fn selectedSourceBuildInput(
    projection: mmanifest.Projection,
    files: []const CollectedFile,
) !?[]const u8 {
    var selected: ?[]const u8 = null;
    for (files) |file| {
        if (!matchesInclude(projection.source_include, file.path)) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(file.path), mmanifest.source_build_file)) continue;
        if (selected) |already| {
            if (!std.mem.eql(u8, already, file.path)) return error.AmbiguousBuildInput;
        } else {
            selected = file.path;
        }
    }
    return selected;
}

fn walkPath(allocator: Allocator, path: []const u8) ![]const u8 {
    if (comptime builtin.os.tag == .windows) {
        const normalized = try allocator.alloc(u8, path.len);
        for (path, 0..) |byte, index| normalized[index] = if (byte == '\\') '/' else byte;
        return normalized;
    }
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;
    return allocator.dupe(u8, path);
}

const OpenedProjectFile = struct {
    file: std.Io.File,
    size: u64,
};

/// `path` を no-follow で開く。途中の親成分は `statFile` と `openDir` の
/// 両方を no-follow で行い、通常のディレクトリだけをたどる。最終成分は
/// 通常ファイルであることを確認し、開いたハンドルでも種別を再確認する。
/// `stat` と `open` の間に symlink へ差し替えられても、no-follow の
/// `open` が追随しないため fail-closed になる。
fn openProjectFileNoFollow(
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
) !OpenedProjectFile {
    var current = directory;
    var owns_current = false;
    defer if (owns_current) current.close(io);

    var components = std.mem.splitScalar(u8, path, '/');
    var component = components.next() orelse return error.InvalidPath;
    while (components.next()) |next| {
        const info = current.statFile(io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.SymLinkLoop => return error.SymlinkNotAllowed,
            else => return err,
        };
        if (info.kind == .sym_link) return error.SymlinkNotAllowed;
        if (info.kind != .directory) return error.NotDir;
        const opened = current.openDir(io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
            // stat 後に symlink へ差し替えられた場合、Linux の
            // O_NOFOLLOW|O_DIRECTORY は NotDir を返す。通常ファイルへの
            // 差し替えも含め、ここでは fail-closed で拒否する。
            error.SymLinkLoop, error.NotDir => return error.SymlinkNotAllowed,
            else => return err,
        };
        const opened_info = opened.stat(io) catch |err| {
            opened.close(io);
            return err;
        };
        if (opened_info.kind == .sym_link) {
            opened.close(io);
            return error.SymlinkNotAllowed;
        }
        if (opened_info.kind != .directory) {
            opened.close(io);
            return error.NotDir;
        }
        if (owns_current) current.close(io);
        current = opened;
        owns_current = true;
        component = next;
    }

    const info = current.statFile(io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.SymLinkLoop => return error.SymlinkNotAllowed,
        else => return err,
    };
    if (info.kind == .sym_link) return error.SymlinkNotAllowed;
    if (info.kind != .file) return error.UnsupportedFileType;

    var file = current.openFile(io, component, .{
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.SymLinkLoop => return error.SymlinkNotAllowed,
        error.IsDir, error.NotDir => return error.UnsupportedFileType,
        else => return err,
    };
    errdefer file.close(io);
    // Windows の reparse point は no-follow で開くと link 自体のハンドルに
    // なるため、開いた後にも種別を確認する。
    const opened_info = try file.stat(io);
    if (opened_info.kind == .sym_link) return error.SymlinkNotAllowed;
    if (opened_info.kind != .file) return error.UnsupportedFileType;
    return .{ .file = file, .size = opened_info.size };
}

/// 必須ファイルを walk と同じ no-follow 経路で読み込む。
fn readProjectFile(
    allocator: Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    sub_path: []const u8,
    limit: u64,
) ![]const u8 {
    var opened = openProjectFileNoFollow(io, directory, sub_path) catch |err| switch (err) {
        error.FileNotFound => return error.MissingEntry,
        else => return err,
    };
    defer opened.file.close(io);
    if (opened.size > limit) return error.StreamTooLong;
    var file_reader = opened.file.reader(io, &.{});
    return file_reader.interface.allocRemaining(allocator, .limited(@intCast(limit))) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

/// 収録済みの必須ファイルでも、walk 後に symlink へ置換されていないことを
/// 同じ no-follow 経路で確認する。
fn verifyProjectFileNoFollow(
    io: std.Io,
    directory: std.Io.Dir,
    sub_path: []const u8,
) !void {
    var opened = openProjectFileNoFollow(io, directory, sub_path) catch |err| switch (err) {
        error.FileNotFound => return error.MissingEntry,
        else => return err,
    };
    opened.file.close(io);
}

fn collectMatched(
    collector: *Collector,
    io: std.Io,
    directory: std.Io.Dir,
    projection: mmanifest.Projection,
) !void {
    var walker = try directory.walk(collector.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => continue,
            .file => {
                const path = try walkPath(collector.allocator, entry.path);
                if (isExcludedPath(path)) continue;
                if (!matchesProjection(projection, path)) continue;
                if (!types.validPath(path)) return error.InvalidPath;
                if (std.mem.startsWith(u8, path, archive_prefix) or
                    std.mem.eql(u8, path, "NAKO-PKG"))
                    return error.ReservedPath;
                const data = try readProjectFile(
                    collector.allocator,
                    io,
                    entry.dir,
                    entry.basename,
                    @min(max_project_file_bytes, collector.limits.max_uncompressed_bytes),
                );
                try collector.addPayload(path, data);
            },
            .sym_link => {
                const path = try walkPath(collector.allocator, entry.path);
                if (isExcludedPath(path)) continue;
                if (matchesProjection(projection, path)) return error.SymlinkNotAllowed;
            },
            else => {
                const path = try walkPath(collector.allocator, entry.path);
                if (isExcludedPath(path)) continue;
                if (matchesProjection(projection, path)) return error.UnsupportedFileType;
            },
        }
    }
}

fn addRequiredFiles(
    collector: *Collector,
    io: std.Io,
    directory: std.Io.Dir,
    projection: mmanifest.Projection,
) !void {
    if (projection.model.artifact.kind == .esm) {
        const entry = projection.esm_entry orelse return error.MissingEntry;
        _ = try addProjectFile(collector, io, directory, entry);
    }
    if (projection.model.artifact.kind == .@"native-prebuilt") {
        const native = projection.model.artifact.native orelse return error.MissingLibrary;
        const library = native.library_path orelse return error.MissingLibrary;
        if (!types.validPath(library)) return error.InvalidLibraryPath;
        _ = addProjectFile(collector, io, directory, library) catch |err| switch (err) {
            error.MissingEntry => return error.MissingLibrary,
            else => return err,
        };
    }
    const references = try meta.licenseRefs(collector.allocator, projection.model.package.license);
    for (references) |reference| {
        const path = try meta.licenseRefPath(collector.allocator, reference);
        const data = addProjectFile(collector, io, directory, path) catch |err| switch (err) {
            error.MissingEntry => return error.MissingLicenseText,
            else => return err,
        };
        if (std.mem.trim(u8, data, " \t\r\n").len == 0) return error.MissingLicenseText;
    }
}

fn addProjectFile(
    collector: *Collector,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
) ![]const u8 {
    if (!types.validPath(path)) return error.InvalidPath;
    if (collector.index.get(path)) |index| {
        try verifyProjectFileNoFollow(io, directory, path);
        return collector.files.items[index].data;
    }
    const data = try readProjectFile(
        collector.allocator,
        io,
        directory,
        path,
        @min(max_project_file_bytes, collector.limits.max_uncompressed_bytes),
    );
    try collector.addPayload(path, data);
    return data;
}

const SourceProviderState = struct {
    collector: *const Collector,

    fn read(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?[]u8 {
        const self: *SourceProviderState = @ptrCast(@alignCast(context));
        const index = self.collector.index.get(path) orelse return null;
        return try allocator.dupe(u8, self.collector.files.items[index].data);
    }

    fn provider(self: *SourceProviderState) commands_gen.SourceProvider {
        return .{ .context = self, .readFn = SourceProviderState.read };
    }
};

/// 明示入力の COMMANDS.json を既存の解析・交叉検査・emit に通す。入力の
/// 表記ゆれは emit が正規形へそろえるため、pack の出力は決定的なままになる。
/// 空の commands / constants は合法であり、拒否しない。
fn explicitCommands(
    allocator: Allocator,
    metadata: *const meta.Model,
    source: []const u8,
) ![]const u8 {
    var parsed = mcommands.parse(allocator, source, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommands,
    };
    defer parsed.document.deinit();
    try validateCommandExports(metadata, &parsed.model);
    return mcommands.emit(allocator, parsed.model.exports);
}

/// 公開ソースの取り込み閉包から命令と定数を抽出する。既存の静的抽出器が
/// 返す公開変数は v1 の `constants`、公開関数は `commands`（kind は
/// `function`）へ写す。JS・ネイティブライブラリの入口は命令を持たないため
/// 空の一覧にする。明示入力がある場合は `explicitCommands` が優先する。
fn buildCommands(
    allocator: Allocator,
    model: meta.Model,
    collector: *const Collector,
) ![]const u8 {
    const exports = try allocator.alloc(mcommands.Export, model.exports.len);
    for (model.exports, 0..) |export_entry, index| {
        const selected_entry = model.selectedEntry(export_entry.subpath) orelse return error.InvalidMetadata;
        // native-prebuilt は既定入口をライブラリへ、native-source は
        // ビルド入力へ差し替えるが、共通 exports の `.nako3` が同梱されて
        // いれば命令の静的抽出元として使う。明示 `--commands` がある場合は
        // この関数自体が呼ばれない。
        var entry_path = selected_entry;
        if ((model.artifact.kind == .@"native-prebuilt" or
            model.artifact.kind == .@"native-source") and
            collector.index.contains(export_entry.entry))
        {
            entry_path = export_entry.entry;
        }
        var command_list: std.ArrayList(mcommands.Command) = .empty;
        var constant_list: std.ArrayList([]const u8) = .empty;
        if (isNakoSource(entry_path)) {
            var provider_state = SourceProviderState{ .collector = collector };
            var diagnostics = diag.List.init(allocator);
            defer diagnostics.deinit();
            var result = commands_gen.generate(
                allocator,
                provider_state.provider(),
                &.{entry_path},
                &diagnostics,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidCommands,
            };
            defer result.deinit();
            // `commands_gen.Result` の arena はこのブロックの終端で解放される。
            // `pack` の呼出し側 arena が親であっても、解放後の参照に依存しない
            // よう、索引へ残す文字列はすべてここで複製する。
            for (result.commands) |command| {
                const name = try allocator.dupe(u8, command.name);
                if (command.variable) {
                    try constant_list.append(allocator, name);
                    continue;
                }
                const args = try allocator.alloc(mcommands.Arg, command.args.len);
                for (command.args, 0..) |arg_name, arg_index| {
                    var josi: []const []const u8 = &.{};
                    if (arg_index < command.josi.len) {
                        const josi_strings = try allocator.alloc([]const u8, 1);
                        josi_strings[0] = try allocator.dupe(u8, command.josi[arg_index]);
                        josi = josi_strings;
                    }
                    args[arg_index] = .{
                        .name = try allocator.dupe(u8, arg_name),
                        .josi = josi,
                    };
                }
                try command_list.append(allocator, .{
                    .name = name,
                    .kind = "function",
                    .args = args,
                });
            }
        }
        exports[index] = .{
            .subpath = export_entry.subpath,
            .binding = export_entry.binding,
            .commands = command_list.items,
            .constants = constant_list.items,
        };
    }
    return mcommands.emit(allocator, exports);
}
