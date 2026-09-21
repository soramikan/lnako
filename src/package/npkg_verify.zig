//! `.npkg` アーカイブのインストール前検証。
//!
//! バイト列から ZIP central directory を読み、SPECIFICATION §6.5 の検証を行う:
//! 必須 `NAKO-PKG` エントリの存在・schema version・エントリ名の規範性と重複・
//! §6.1 の正規形（ソート順・UTF-8 フラグ・時刻ゼロ・extra/comment なし）、
//! `FILES.toml` と payload エントリ集合の一致・hash/size 照合、
//! `METADATA.toml` の構造、対象環境（runtime/os/cpu/abi/min-os/libc/
//! features/engines）との適合。検証は静的であり、パッケージの初期化コードや
//! 任意コードは実行しない。

const std = @import("std");
const diag = @import("diagnostics.zig");
const manifest_mod = @import("manifest.zig");
const npkg_commands = @import("npkg_commands.zig");
const npkg_files = @import("npkg_files.zig");
const npkg_metadata = @import("npkg_metadata.zig");
const features_mod = @import("features.zig");
const semver = @import("semver.zig");

const Allocator = std.mem.Allocator;

const max_entries = 100_000;
const max_total_size = 1024 * 1024 * 1024;
/// EOCD 検索範囲（EOCD 22 バイト + 最大コメント 65535 バイト）。
const eocd_search = 22 + 65535;

/// 検証対象環境。`os`/`cpu`/`abi` が空の場合、`when`/`min-os`/`libc` 等の
/// 条件付き artifact は適合を証明できないため選択されない（保守方向）。
pub const Target = struct {
    runtime: []const u8 = "lnako",
    os: []const u8 = "",
    cpu: []const u8 = "",
    abi: []const u8 = "",
    os_version: ?[]const u8 = null,
    libc: ?[]const u8 = null,
    compat_js: bool = false,
    /// 有効化を要求する feature 名。`[features]` 定義の推移展開と
    /// `default`（`default_features` が真の場合）を加えた集合が
    /// artifact 照合に使われる。
    features: []const []const u8 = &.{},
    /// `default` feature を有効化するか（依存解決と同じ既定で真）。
    default_features: bool = true,
    /// なでしこ言語バージョン。`engines.nako` 照合と marker の `version`
    /// 評価に使う。null の場合はこれらの制約を未検査とする。
    nako_version: ?semver.Version = null,
    /// 処理系バージョン（`engines.cnako`/`engines.lnako` 照合用）。
    /// null のキーは未検査。言語バージョンと処理系バージョンは独立に
    /// 指定する（lnako のリリース番号と対応する言語版は一致しないため）。
    cnako_version: ?semver.Version = null,
    lnako_version: ?semver.Version = null,

    fn artifactTarget(self: Target) manifest_mod.ArtifactTarget {
        return .{
            .runtime = self.runtime,
            .os = self.os,
            .cpu = self.cpu,
            .abi = self.abi,
            .os_version = self.os_version,
            .libc = self.libc,
            .compat_js = self.compat_js,
            .version = self.nako_version,
            .features = self.features,
        };
    }
};

/// 検証済み `.npkg`。全メモリは内蔵 arena が所有する。
pub const Verified = struct {
    arena: std.heap.ArenaAllocator,
    manifest: manifest_mod.Manifest,
    files: []npkg_files.FileEntry,
    commands: []npkg_commands.Command,

    pub fn deinit(self: *Verified) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const ZipEntry = struct {
    name: []const u8,
    flags: u16,
    method: u16,
    mod_time: u16,
    mod_date: u16,
    crc: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    disk_start: u16,
    extra_len: u16,
    comment_len: u16,
    local_offset: u32,
};

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

/// central directory を走査してエントリ一覧を返す。ZIP64・複数 disk・
/// データ記述子は受理しない（生成側が使わない形式）。
fn readCentralDirectory(allocator: Allocator, archive: []const u8) ![]ZipEntry {
    if (archive.len < 22) return error.InvalidArchive;
    const search_start = if (archive.len > eocd_search) archive.len - eocd_search else 0;
    var eocd_offset: ?usize = null;
    var index = archive.len - 22;
    while (true) : (index -= 1) {
        if (readInt(u32, archive, index) == 0x06054b50) {
            eocd_offset = index;
            break;
        }
        if (index == search_start) break;
    }
    const eocd = eocd_offset orelse return error.InvalidArchive;
    // 複数 disk・EOCD comment・末尾の余剰バイトは正規形でないため拒否する。
    // 加算は u64/usize で行い、細工された offset の u32 オーバーフローで
    // 境界検査を迂回できないようにする。
    if (readInt(u16, archive, eocd + 4) != 0 or readInt(u16, archive, eocd + 6) != 0)
        return error.InvalidArchive;
    const entry_count = readInt(u16, archive, eocd + 10);
    if (readInt(u16, archive, eocd + 8) != entry_count) return error.InvalidArchive;
    const cd_size = readInt(u32, archive, eocd + 12);
    const cd_offset = readInt(u32, archive, eocd + 16);
    if (entry_count > max_entries) return error.InvalidArchive;
    if (readInt(u16, archive, eocd + 20) != 0 or eocd + 22 != archive.len)
        return error.InvalidArchive;
    const cd_end = @as(u64, cd_offset) + @as(u64, cd_size);
    if (cd_end > archive.len or cd_end > eocd) return error.InvalidArchive;

    var entries: std.ArrayList(ZipEntry) = .empty;
    var offset: usize = cd_offset;
    for (0..entry_count) |_| {
        if (offset + 46 > archive.len or readInt(u32, archive, offset) != 0x02014b50)
            return error.InvalidArchive;
        const name_len = readInt(u16, archive, offset + 28);
        const extra_len = readInt(u16, archive, offset + 30);
        const comment_len = readInt(u16, archive, offset + 32);
        const name_start = offset + 46;
        const name_end = name_start + @as(usize, name_len) + extra_len + comment_len;
        if (name_end > archive.len) return error.InvalidArchive;
        const name = archive[name_start .. name_start + name_len];
        try entries.append(allocator, .{
            .name = name,
            .flags = readInt(u16, archive, offset + 8),
            .method = readInt(u16, archive, offset + 10),
            .mod_time = readInt(u16, archive, offset + 12),
            .mod_date = readInt(u16, archive, offset + 14),
            .crc = readInt(u32, archive, offset + 16),
            .compressed_size = readInt(u32, archive, offset + 20),
            .uncompressed_size = readInt(u32, archive, offset + 24),
            .disk_start = readInt(u16, archive, offset + 34),
            .extra_len = extra_len,
            .comment_len = comment_len,
            .local_offset = readInt(u32, archive, offset + 42),
        });
        offset = name_end;
    }
    if (offset != @as(usize, @intCast(cd_end))) return error.InvalidArchive;
    return entries.toOwnedSlice(allocator);
}

/// local header を辿って entry 内容を返す。`NAKO-PKG` 形式は stored のみ
/// 規定するため method 0 以外は受理しない。local header のファイル名が
/// central directory の名前と一致しないアーカイブは拒否する（二重名義で
/// 検証済み内容と展開先をずらす偽装を防ぐ）。
fn readEntryData(archive: []const u8, entry: ZipEntry) ![]u8 {
    // offset 加算は全て usize で行う（u32 の local_offset に 30 や 65535 を
    // 足しても桁あふれしない）。細工された offset がパニックや境界検査の
    // 迂回を引き起こさないよう、スライス前に常に範囲を確認する。
    const lh: usize = entry.local_offset;
    if (lh + 30 > archive.len or readInt(u32, archive, lh) != 0x04034b50)
        return error.InvalidArchive;
    const local_name_len: usize = readInt(u16, archive, lh + 26);
    const local_extra_len: usize = readInt(u16, archive, lh + 28);
    const data_offset = lh + 30 + local_name_len + local_extra_len;
    const data_end = data_offset + @as(usize, entry.compressed_size);
    if (data_end > archive.len) return error.InvalidArchive;
    const local_name = archive[lh + 30 .. lh + 30 + local_name_len];
    if (!std.mem.eql(u8, local_name, entry.name)) return error.InvalidArchive;
    // local header も正規形を要求する: UTF-8 フラグ・stored・時刻ゼロ・
    // extra なし、CRC・size は central directory と一致。両 header を
    // 独立に検査しないと、検証側と展開側で読む内容がずれ得る。
    if (readInt(u16, archive, lh + 6) != 0x0800 or
        readInt(u16, archive, lh + 8) != 0 or
        readInt(u16, archive, lh + 10) != 0 or
        readInt(u16, archive, lh + 12) != 0 or
        readInt(u32, archive, lh + 14) != entry.crc or
        local_extra_len != 0 or
        readInt(u32, archive, lh + 18) != entry.compressed_size or
        readInt(u32, archive, lh + 22) != entry.uncompressed_size)
    {
        return error.InvalidArchive;
    }
    if (entry.method != 0) return error.InvalidArchive;
    const compressed = archive[data_offset..data_end];
    if (compressed.len != entry.uncompressed_size) return error.InvalidArchive;
    // ZIP の CRC-32 を内容から再計算して照合する。FILES.toml の SHA-256 で
    // 内容自体は保証されるが、展開側が CRC を検査するため、CRC だけ壊れた
    // アーカイブを「検証済みだが展開不能」として通さない。
    if (std.hash.Crc32.hash(compressed) != entry.crc) return error.InvalidArchive;
    return @constCast(compressed);
}

fn report(diagnostics: *diag.List, code: []const u8, path: []const u8, comptime format: []const u8, args: anytype) !void {
    try diagnostics.addFmt(code, .err, path, .{}, format, args);
}

/// artifact 照合用の有効 feature 集合を返す。依存解決の feature
/// unification と同じ意味論とする。`[features]` に定義された要求名は
/// 推移展開して有効集合へ入れ、`use_default` が真なら `default` も有効化
/// する。未定義の要求名と依存 alias は orphan 相当として有効集合へ
/// 入れない（その名を要求する artifact は適合しない）。
fn effectiveFeatures(allocator: Allocator, manifest: *const manifest_mod.Manifest, requested_names: []const []const u8, use_default: bool) ![]const []const u8 {
    var aliases = try manifest.dependencyAliases(allocator);
    defer aliases.deinit();
    var requested: std.ArrayList([]const u8) = .empty;
    for (requested_names) |name| {
        if (manifest.features.contains(name)) try requested.append(allocator, name);
    }
    var expanded = features_mod.expand(allocator, &manifest.features, requested.items, use_default, &aliases, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // 定義の参照先（未定義名・巡回）は manifest 検証段階で受理され得る
        // ため、照合不能として InvalidPackage に正規化する。
        error.FeatureCycle, error.UnknownFeature => return error.InvalidPackage,
    };
    defer expanded.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    var iterator = expanded.features.keyIterator();
    while (iterator.next()) |key| try out.append(allocator, key.*);
    return out.items;
}

/// `.npkg` バイト列を検証し、解析済みメタデータを返す。
/// 失敗時は diagnostics へ記録して `error.InvalidPackage` を返す。
pub fn verify(
    backing_allocator: Allocator,
    archive: []const u8,
    target: Target,
    diagnostics: *diag.List,
) !Verified {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const prior_errors = diagnostics.errorCount();

    const zip_entries = readCentralDirectory(allocator, archive) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try report(diagnostics, diag.E029_INVALID_VALUE, ".npkg", "archive is not a readable ZIP", .{});
            return error.InvalidPackage;
        },
    };

    // エントリ名の規範性・重複・正規形・メタデータ領域の検査と内容の読み出し。
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var contents: std.StringHashMapUnmanaged([]u8) = .empty;
    var total_uncompressed: u64 = 0;
    var previous_name: ?[]const u8 = null;
    for (zip_entries) |entry| {
        // 重複・規範性・格納形式は directory エントリを含む全エントリに
        // 適用する（§6.5）。directory エントリは末尾 `/` のため規範 path に
        // 適合せず、ここで拒否される。
        if (previous_name) |previous| {
            if (std.mem.order(u8, previous, entry.name) == .gt) {
                try report(diagnostics, diag.E029_INVALID_VALUE, entry.name, "archive entry \"{s}\" is not in canonical sorted order", .{entry.name});
                continue;
            }
        }
        previous_name = entry.name;
        if ((try seen.getOrPut(allocator, entry.name)).found_existing) {
            try report(diagnostics, diag.E038_NPKG_DUPLICATE_ENTRY, entry.name, "duplicate archive entry \"{s}\"", .{entry.name});
            continue;
        }
        if (!npkg_files.isCanonicalPath(entry.name)) {
            try report(diagnostics, diag.E040_NPKG_NONCANONICAL_PATH, entry.name, "archive entry \"{s}\" is not a canonical path", .{entry.name});
            continue;
        }
        if (entry.method != 0) {
            try report(diagnostics, diag.E029_INVALID_VALUE, entry.name, "archive entry \"{s}\" uses non-stored compression", .{entry.name});
            continue;
        }
        // §6.1 の正規形: UTF-8 フラグのみ・時刻ゼロ・extra/comment なし・
        // 単一 disk・stored は compressed == uncompressed。外部作成物にも
        // 正規形を強制し、検証したバイト列が生成側の決定的出力と同じ形を
        // 持つことを保証する。
        if (entry.flags != 0x0800 or entry.mod_time != 0 or entry.mod_date != 0 or
            entry.extra_len != 0 or entry.comment_len != 0 or entry.disk_start != 0 or
            entry.compressed_size != entry.uncompressed_size)
        {
            try report(diagnostics, diag.E029_INVALID_VALUE, entry.name, "archive entry \"{s}\" is not in canonical form", .{entry.name});
            continue;
        }
        if (npkg_files.isMetadataPath(entry.name)) {
            const known = [_][]const u8{ npkg_files.metadata_entry, npkg_files.files_entry, npkg_files.commands_entry };
            var listed = false;
            for (known) |k| {
                if (std.mem.eql(u8, entry.name, k)) listed = true;
            }
            if (!listed) {
                try report(diagnostics, diag.E037_NPKG_UNLISTED_ENTRY, entry.name, "unexpected metadata entry \"{s}\"", .{entry.name});
                continue;
            }
        }
        total_uncompressed += entry.uncompressed_size;
        if (total_uncompressed > max_total_size) {
            try report(diagnostics, diag.E029_INVALID_VALUE, entry.name, "archive exceeds the total size limit", .{});
            return error.InvalidPackage;
        }
        const data = readEntryData(archive, entry) catch {
            try report(diagnostics, diag.E029_INVALID_VALUE, entry.name, "archive entry \"{s}\" is not readable", .{entry.name});
            continue;
        };
        try contents.put(allocator, entry.name, data);
    }

    for ([_][]const u8{ npkg_files.metadata_entry, npkg_files.files_entry, npkg_files.commands_entry }) |required| {
        if (!contents.contains(required)) {
            try report(diagnostics, diag.E036_NPKG_MISSING_ENTRY, required, "required archive entry \"{s}\" is missing", .{required});
        }
    }
    if (diagnostics.errorCount() > prior_errors) return error.InvalidPackage;

    // メタデータの構造と schema version。
    const manifest = npkg_metadata.parse(allocator, contents.get(npkg_files.metadata_entry).?, diagnostics) catch |err| switch (err) {
        error.InvalidManifest => return error.InvalidPackage,
        else => return err,
    };
    const files = npkg_files.parse(allocator, contents.get(npkg_files.files_entry).?, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidPackage,
    };
    const commands = npkg_commands.parse(allocator, contents.get(npkg_files.commands_entry).?, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidPackage,
    };
    // 配布単位は少なくとも1件の payload を要する（生成側と同じ不変条件。
    // メタデータ3エントリだけのアーカイブは何も配布しない）。
    if (files.entries.len == 0) {
        try report(diagnostics, diag.E036_NPKG_MISSING_ENTRY, npkg_files.files_entry, "package contains no distributable payload files", .{});
    }

    // FILES.toml と payload の集合・hash・size 照合。
    var listed: std.StringHashMapUnmanaged(npkg_files.FileEntry) = .empty;
    for (files.entries) |file| try listed.put(allocator, file.path, file);
    for (zip_entries) |entry| {
        if (entry.name.len != 0 and entry.name[entry.name.len - 1] == '/') continue;
        if (npkg_files.isMetadataPath(entry.name)) continue;
        if (!npkg_files.isCanonicalPath(entry.name)) continue;
        const file = listed.get(entry.name) orelse {
            try report(diagnostics, diag.E037_NPKG_UNLISTED_ENTRY, entry.name, "payload \"{s}\" is not listed in FILES.toml", .{entry.name});
            continue;
        };
        const data = contents.get(entry.name) orelse continue;
        if (data.len != file.size) {
            try report(diagnostics, diag.E009_HASH_MISMATCH, entry.name, "size of \"{s}\" does not match FILES.toml", .{entry.name});
            continue;
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        if (!std.mem.eql(u8, &digest, &file.sha256)) {
            try report(diagnostics, diag.E009_HASH_MISMATCH, entry.name, "sha256 of \"{s}\" does not match FILES.toml", .{entry.name});
        }
    }
    for (files.entries) |file| {
        if (!contents.contains(file.path)) {
            try report(diagnostics, diag.E036_NPKG_MISSING_ENTRY, file.path, "indexed file \"{s}\" is missing from the archive", .{file.path});
        }
    }

    // `dependencies.path` の依存先は package 内に同梱されていなければ
    // 配布先で再現できない。依存先の manifest が索引に無い宣言は拒否する。
    var dep_iterator = manifest.dependencies.path.valueIterator();
    while (dep_iterator.next()) |dep| {
        const dep_manifest = try std.fmt.allocPrint(allocator, "{s}/nako.toml", .{dep.path});
        if (!listed.contains(dep_manifest)) {
            try report(diagnostics, diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY, dep.path, "path dependency \"{s}\" is not included in the package", .{dep.path});
        }
    }

    // exports が参照するファイルが索引（=payload、集合一致は検証済み）へ
    // 収録されているか。宣言だけ存在して実体が無い export を拒否する。
    for (manifest.exports) |export_entry| {
        if (export_entry.path) |path| {
            if (!listed.contains(path)) {
                try report(diagnostics, diag.E036_NPKG_MISSING_ENTRY, path, "export \"{s}\" source \"{s}\" is not included in the package", .{ export_entry.name, path });
            }
        }
        for ([_][]const manifest_mod.ArtifactDecl{ export_entry.native, export_entry.esm }) |decls| {
            for (decls) |decl| {
                if (!listed.contains(decl.path)) {
                    try report(diagnostics, diag.E036_NPKG_MISSING_ENTRY, decl.path, "export \"{s}\" artifact \"{s}\" is not included in the package", .{ export_entry.name, decl.path });
                }
            }
        }
    }

    // 対象環境との適合: runtime・engines・各 export の artifact 選択。
    _ = try manifest.checkRuntime(target.runtime, diagnostics, .{});
    // 言語版と処理系版は独立した制約として検査する。対象 runtime の
    // 処理系版のみを渡し、値が不明な制約は未検査とする。
    _ = try manifest.checkEngines(
        target.nako_version,
        if (std.mem.eql(u8, target.runtime, "cnako")) target.cnako_version else null,
        if (std.mem.eql(u8, target.runtime, "lnako")) target.lnako_version else null,
        diagnostics,
        .{},
    );
    // artifact 照合の feature 集合は、要求名に [features] 定義の推移展開と
    // default（無効化可能）を加えた有効集合とする（依存解決と同じ意味論）。
    var artifact_target = target.artifactTarget();
    artifact_target.features = try effectiveFeatures(allocator, &manifest, target.features, target.default_features);
    for (manifest.exports) |*export_entry| {
        _ = try export_entry.resolve(allocator, artifact_target, false, diagnostics);
    }

    if (diagnostics.errorCount() > prior_errors) return error.InvalidPackage;

    // 全割当が完了した後に arena を移す。manifest/files/commands は
    // いずれも arena 由来の document が所有するため個別 deinit は不要。
    return .{
        .arena = arena,
        .manifest = manifest,
        .files = files.entries,
        .commands = commands.commands,
    };
}

/// `.npkg` ファイルを読んで検証する。
pub fn verifyFile(
    backing_allocator: Allocator,
    io: std.Io,
    path: []const u8,
    target: Target,
    diagnostics: *diag.List,
) !Verified {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, backing_allocator, .limited(max_total_size));
    defer backing_allocator.free(bytes);
    return verify(backing_allocator, bytes, target, diagnostics);
}

test {
    _ = @import("npkg_test.zig");
}
