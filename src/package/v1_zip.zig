//! v1 Canonical ZIP の生成と、配布物として受理できる ZIP の検証。
//!
//! 仕様 §3.2 の正規形（UTF-8 の昇順、DOS 固定日時、通常ファイルのみ、
//! 上限の段階計上、局所ヘッダ照合、CRC とサイズの照合）を扱う。パスは URL
//! やホスト OS の区切りから独立した相対 POSIX パスとして検査する。
//!
//! 受理範囲（O06 の細則。詳細は docs/package-system/V1_CANONICAL_ZIP.md）:
//! - EFS ビット付きの名前は UTF-8 として検証する。EFS なしの名前は、標準
//!   ZIP の CP437 と UTF-8 が一致する ASCII だけを受理する。これにより
//!   Python の zipfile などが ASCII 名に EFS を立てない通常の ZIP を、
//!   ほかの規則が成立するときに受理する。
//! - 大小文字衝突は Unicode の単純 case fold（`unicode_case.simpleFold`）で
//!   比較する。Unicode 正規化や ß→ss のような完全 case folding は行わない。
//! - 構造として妥当な ZIP64（EOCD64・locator・ZIP64 extra の必要分）を
//!   受理する。上限（圧縮後 25 MiB 等）を超える値は従来どおり拒否する。
//! - データ記述子（general purpose bit 3）は、中央ディレクトリの CRC と
//!   サイズに一致する場合だけ受理する。
//! - 追加フィールドは、長さの整合するブロックとして読み飛ばす。ZIP64
//!   以外の ID は意味を解釈しない（パスや時刻の判断には使わない）。
//!
//! 生成側は STORED と DEFLATE の双方を扱う。DEFLATE は Zig 標準の
//! `std.compress.flate` を使い、読み込み側も同じ実装で展開する。生成物の
//! バイト列は入力と圧縮方式だけから決まり、ファイルシステムの時刻・順序・
//! 属性を写さない。

const std = @import("std");
const types = @import("v1_types.zig");
const unicode_case = @import("unicode_case");
const flate = std.compress.flate;

const Allocator = std.mem.Allocator;

pub const default_max_compressed_bytes: u64 = 25 * 1024 * 1024;
pub const default_max_uncompressed_bytes: u64 = 100 * 1024 * 1024;
pub const default_max_files: usize = 2_000;

/// 展開前に適用する安全上限。仕様 §3.2-4 の既定値。
pub const Limits = struct {
    max_compressed_bytes: u64 = default_max_compressed_bytes,
    max_uncompressed_bytes: u64 = default_max_uncompressed_bytes,
    max_files: usize = default_max_files,
};

pub const Compression = enum { stored, deflate };

/// ZIP へ収録する通常ファイル。`path` は正規化済みの相対 POSIX パス。
pub const SourceEntry = struct {
    path: []const u8,
    data: []const u8,
    compression: Compression = .stored,
};

pub const Error = error{
    OutOfMemory,
    InvalidArchive,
    EntryCountExceeded,
    CompressedSizeExceeded,
    UncompressedSizeExceeded,
    Zip64Unsupported,
    InvalidZip64,
    EncryptionUnsupported,
    DataDescriptorMismatch,
    InvalidExtraField,
    UnsupportedCompression,
    UnsupportedEntryType,
    DirectoryEntry,
    SymlinkEntry,
    InvalidPath,
    InvalidUtf8Path,
    AmbiguousPathEncoding,
    DuplicateEntry,
    NameCollision,
    NotSorted,
    TimestampMismatch,
    NonCanonicalHeader,
    LocalHeaderMismatch,
    NonCanonicalLayout,
    InvalidSizes,
    InvalidDeflate,
    SizeMismatch,
    ChecksumMismatch,
    EntryNameTooLong,
};

// DOS 日時 1980-01-01 00:00:00。date = (year-1980)<<9 | month<<5 | day。
const canonical_dos_date: u16 = 0x0021;
const canonical_dos_time: u16 = 0;
const utf8_flag: u16 = 0x0800;
const data_descriptor_flag: u16 = 0x0008;
const version_needed: u16 = 20;
const version_made_by: u16 = 20;

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

/// `offset` から `count` バイトが入力内にあるか。加算のオーバーフローを
/// 避けてから境界を判定する。
fn hasBytes(bytes: []const u8, offset: u64, count: u64) bool {
    const length: u64 = bytes.len;
    if (offset > length) return false;
    return length - offset >= count;
}

fn appendInt(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

/// Unicode の単純大文字小文字折り畳み（`unicode_case.simpleFold`）を
/// コードポイントごとに適用した比較キー。ASCII だけでなく UTF-8 パスの
/// 非 ASCII 大文字小文字衝突も検出する。Unicode 正規化（NFC/NFD）や
/// 複数コードポイントへの完全 case folding（ß→ss 等）は行わない。
fn caseFoldKey(allocator: Allocator, text: []const u8) ![]u8 {
    var folded: std.ArrayList(u8) = .empty;
    errdefer folded.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
            return error.InvalidUtf8Path;
        if (index + length > text.len) return error.InvalidUtf8Path;
        const codepoint = std.unicode.utf8Decode(text[index .. index + length]) catch
            return error.InvalidUtf8Path;
        const canonical = unicode_case.simpleFold(codepoint);
        var buffer: [4]u8 = undefined;
        const encoded = std.unicode.utf8Encode(canonical, &buffer) catch
            return error.InvalidUtf8Path;
        try folded.appendSlice(allocator, buffer[0..@intCast(encoded)]);
        index += length;
    }
    return folded.toOwnedSlice(allocator);
}

/// EFS ありなら UTF-8、EFS なしなら ASCII のみを許す。EFS なしの非 ASCII は
/// CP437 の名前を UTF-8 と誤認する余地があるため拒否する。
fn validPathEncoding(name: []const u8, flags: u16) !void {
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8Path;
    if ((flags & utf8_flag) == 0) {
        for (name) |byte| {
            if (byte >= 0x80) return error.AmbiguousPathEncoding;
        }
    }
}

/// 生の DEFLATE ビット列へ圧縮する。圧縮結果も同じ `pack` 版で決定的になる。
fn deflate(allocator: Allocator, data: []const u8) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 64 * 1024);
    errdefer output.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&output.writer, &window, .raw, .fastest);
    try compressor.writer.writeAll(data);
    try compressor.writer.flush();
    try compressor.finish();
    return output.toOwnedSlice();
}

/// 入力から正規形 ZIP を生成する。入力順は問わず、パスの UTF-8 バイト順に
/// 並べて書き出す。ディレクトリエントリは生成しない。
pub fn build(allocator: Allocator, inputs: []const SourceEntry, limits: Limits) ![]u8 {
    const sorted = try allocator.dupe(SourceEntry, inputs);
    defer allocator.free(sorted);
    std.mem.sort(SourceEntry, sorted, {}, struct {
        fn lessThan(_: void, left: SourceEntry, right: SourceEntry) bool {
            return std.mem.order(u8, left.path, right.path) == .lt;
        }
    }.lessThan);

    if (sorted.len > limits.max_files) return error.EntryCountExceeded;
    var folded_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer folded_arena_state.deinit();
    var folded_names: std.StringHashMapUnmanaged(void) = .empty;
    var compressed_total: u64 = 0;
    var uncompressed_total: u64 = 0;

    for (sorted, 0..) |entry, index| {
        if (!types.validPath(entry.path)) return error.InvalidPath;
        if (entry.path[entry.path.len - 1] == '/') return error.DirectoryEntry;
        if (entry.path.len > std.math.maxInt(u16)) return error.EntryNameTooLong;
        if (index > 0 and std.mem.eql(u8, sorted[index - 1].path, entry.path)) {
            return error.DuplicateEntry;
        }
        const folded = try caseFoldKey(folded_arena_state.allocator(), entry.path);
        const result = try folded_names.getOrPut(folded_arena_state.allocator(), folded);
        if (result.found_existing) return error.NameCollision;
        if (entry.data.len > std.math.maxInt(u32)) return error.Zip64Unsupported;
        uncompressed_total = std.math.add(u64, uncompressed_total, entry.data.len) catch
            return error.UncompressedSizeExceeded;
        if (uncompressed_total > limits.max_uncompressed_bytes) return error.UncompressedSizeExceeded;
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const offsets = try allocator.alloc(u32, sorted.len);
    defer allocator.free(offsets);
    const compressed_bodies = try allocator.alloc([]const u8, sorted.len);
    defer allocator.free(compressed_bodies);
    const owned_bodies = try allocator.alloc(bool, sorted.len);
    defer allocator.free(owned_bodies);
    @memset(owned_bodies, false);
    defer for (compressed_bodies, owned_bodies) |body, owned| {
        if (owned) allocator.free(body);
    };

    for (sorted, 0..) |entry, index| {
        var body = entry.data;
        var owned = false;
        if (entry.compression == .deflate) {
            body = try deflate(allocator, entry.data);
            owned = true;
        }
        compressed_bodies[index] = body;
        owned_bodies[index] = owned;
        if (body.len > std.math.maxInt(u32)) return error.Zip64Unsupported;
        compressed_total = std.math.add(u64, compressed_total, body.len) catch
            return error.CompressedSizeExceeded;
        if (compressed_total > limits.max_compressed_bytes) return error.CompressedSizeExceeded;
    }

    for (sorted, 0..) |entry, index| {
        const body = compressed_bodies[index];
        offsets[index] = std.math.cast(u32, output.items.len) orelse return error.Zip64Unsupported;
        const crc = std.hash.Crc32.hash(entry.data);
        try appendInt(&output, allocator, u32, 0x04034b50);
        try appendInt(&output, allocator, u16, version_needed);
        try appendInt(&output, allocator, u16, utf8_flag);
        try appendInt(&output, allocator, u16, if (entry.compression == .deflate) 8 else 0);
        try appendInt(&output, allocator, u16, canonical_dos_time);
        try appendInt(&output, allocator, u16, canonical_dos_date);
        try appendInt(&output, allocator, u32, crc);
        try appendInt(&output, allocator, u32, @intCast(body.len));
        try appendInt(&output, allocator, u32, @intCast(entry.data.len));
        try appendInt(&output, allocator, u16, @intCast(entry.path.len));
        try appendInt(&output, allocator, u16, 0);
        try output.appendSlice(allocator, entry.path);
        try output.appendSlice(allocator, body);
    }

    const central_offset = std.math.cast(u32, output.items.len) orelse return error.Zip64Unsupported;
    for (sorted, 0..) |entry, index| {
        const body = compressed_bodies[index];
        try appendInt(&output, allocator, u32, 0x02014b50);
        try appendInt(&output, allocator, u16, version_made_by);
        try appendInt(&output, allocator, u16, version_needed);
        try appendInt(&output, allocator, u16, utf8_flag);
        try appendInt(&output, allocator, u16, if (entry.compression == .deflate) 8 else 0);
        try appendInt(&output, allocator, u16, canonical_dos_time);
        try appendInt(&output, allocator, u16, canonical_dos_date);
        try appendInt(&output, allocator, u32, std.hash.Crc32.hash(entry.data));
        try appendInt(&output, allocator, u32, @intCast(body.len));
        try appendInt(&output, allocator, u32, @intCast(entry.data.len));
        try appendInt(&output, allocator, u16, @intCast(entry.path.len));
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u32, 0);
        try appendInt(&output, allocator, u32, offsets[index]);
        try output.appendSlice(allocator, entry.path);
    }
    const central_size = std.math.cast(u32, output.items.len - central_offset) orelse
        return error.Zip64Unsupported;
    const count = std.math.cast(u16, sorted.len) orelse return error.Zip64Unsupported;
    try appendInt(&output, allocator, u32, 0x06054b50);
    try appendInt(&output, allocator, u16, 0);
    try appendInt(&output, allocator, u16, 0);
    try appendInt(&output, allocator, u16, count);
    try appendInt(&output, allocator, u16, count);
    try appendInt(&output, allocator, u32, central_size);
    try appendInt(&output, allocator, u32, central_offset);
    try appendInt(&output, allocator, u16, 0);
    if (output.items.len > limits.max_compressed_bytes) return error.CompressedSizeExceeded;
    return output.toOwnedSlice(allocator);
}

/// 検証済みの ZIP。全メモリを内蔵 arena が所有するため、入力バイト列の
/// 寿命に依存せず `entryBytes` を呼べる。
pub const Archive = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    index: std.StringHashMapUnmanaged(usize),

    pub const Entry = struct {
        path: []const u8,
        data: []const u8,
    };

    pub fn deinit(self: *Archive) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn entryBytes(self: *const Archive, path: []const u8) ?[]const u8 {
        const index = self.index.get(path) orelse return null;
        return self.entries[index].data;
    }

    pub fn contains(self: *const Archive, path: []const u8) bool {
        return self.index.contains(path);
    }

    pub fn entryCount(self: *const Archive) usize {
        return self.entries.len;
    }

    pub fn entryPath(self: *const Archive, index: usize) []const u8 {
        return self.entries[index].path;
    }
};

const CentralEntry = struct {
    name: []const u8,
    flags: u16,
    method: u16,
    mod_time: u16,
    mod_date: u16,
    crc32: u32,
    compressed_size: u64,
    uncompressed_size: u64,
    version_made_by: u16,
    external_attrs: u32,
    local_offset: u64,
    zip64_sizes: bool,
};

const EndOfCentralDirectory = struct {
    central_size: u64,
    central_offset: u64,
    entry_count: u64,
    /// 中央ディレクトリの直後にあるレコード（EOCD または ZIP64 EOCD）の位置。
    central_end: u64,
};

/// EOCD を末尾から探す。コメントは許容するが、EOCD の終端は入力の終端と
/// 一致しなければならない（末尾の余剰バイトを拒否する）。
fn findEndOfCentralDirectory(bytes: []const u8) !usize {
    if (bytes.len < 22) return error.InvalidArchive;
    const min_offset = if (bytes.len > 22 + 65535) bytes.len - 22 - 65535 else 0;
    var offset = bytes.len - 22;
    while (true) : (offset -= 1) {
        if (readInt(u32, bytes, offset) == 0x06054b50) {
            const comment_len = readInt(u16, bytes, offset + 20);
            if (offset + 22 + comment_len == bytes.len) return offset;
        }
        if (offset == min_offset) break;
    }
    return error.InvalidArchive;
}

/// EOCD と、存在すれば ZIP64 EOCD/locator を読む。ディスク番号は単一 disk
/// だけを受理する。ZIP64 の値は 64 bit のまま返し、上限判定は呼出し側で行う。
fn readEndOfCentralDirectory(bytes: []const u8) !EndOfCentralDirectory {
    const eocd = try findEndOfCentralDirectory(bytes);
    if (eocd + 22 > bytes.len) return error.InvalidArchive;
    if (readInt(u16, bytes, eocd + 4) != 0 or readInt(u16, bytes, eocd + 6) != 0)
        return error.InvalidArchive;

    const raw_disk_entries = readInt(u16, bytes, eocd + 8);
    const raw_entry_count = readInt(u16, bytes, eocd + 10);
    const raw_central_size = readInt(u32, bytes, eocd + 12);
    const raw_central_offset = readInt(u32, bytes, eocd + 16);
    const sentinel = raw_disk_entries == 0xFFFF or raw_entry_count == 0xFFFF or
        raw_central_size == 0xFFFFFFFF or raw_central_offset == 0xFFFFFFFF;

    const locator_offset: ?usize = if (eocd >= 20 and
        readInt(u32, bytes, eocd - 20) == 0x07064b50) eocd - 20 else null;

    if (locator_offset) |locator| {
        if (readInt(u32, bytes, locator + 4) != 0) return error.InvalidZip64;
        if (readInt(u32, bytes, locator + 16) != 1) return error.InvalidZip64;
        const zip64_offset64 = readInt(u64, bytes, locator + 8);
        if (!hasBytes(bytes, zip64_offset64, 12)) return error.InvalidZip64;
        const zip64_offset = std.math.cast(usize, zip64_offset64) orelse
            return error.InvalidZip64;
        if (readInt(u32, bytes, zip64_offset) != 0x06064b50) return error.InvalidZip64;
        const record_size = readInt(u64, bytes, zip64_offset + 4);
        if (record_size < 44) return error.InvalidZip64;
        const record_end = std.math.add(u64, zip64_offset + 12, record_size) catch
            return error.InvalidZip64;
        if (record_end != locator) return error.InvalidZip64;
        if (readInt(u32, bytes, zip64_offset + 16) != 0 or
            readInt(u32, bytes, zip64_offset + 20) != 0)
            return error.InvalidZip64;
        const zip64_disk_entries = readInt(u64, bytes, zip64_offset + 24);
        const zip64_total_entries = readInt(u64, bytes, zip64_offset + 32);
        const zip64_central_size = readInt(u64, bytes, zip64_offset + 40);
        const zip64_central_offset = readInt(u64, bytes, zip64_offset + 48);
        if (zip64_disk_entries != zip64_total_entries) return error.InvalidZip64;

        if (raw_disk_entries != 0xFFFF and @as(u64, raw_disk_entries) != zip64_total_entries)
            return error.InvalidZip64;
        if (raw_entry_count != 0xFFFF and @as(u64, raw_entry_count) != zip64_total_entries)
            return error.InvalidZip64;
        if (raw_central_size != 0xFFFFFFFF and
            @as(u64, raw_central_size) != zip64_central_size)
            return error.InvalidZip64;
        if (raw_central_offset != 0xFFFFFFFF and
            @as(u64, raw_central_offset) != zip64_central_offset)
            return error.InvalidZip64;

        return .{
            .central_size = zip64_central_size,
            .central_offset = zip64_central_offset,
            .entry_count = zip64_total_entries,
            .central_end = zip64_offset,
        };
    }

    if (sentinel) return error.InvalidZip64;
    if (raw_disk_entries != raw_entry_count) return error.InvalidArchive;
    return .{
        .central_size = raw_central_size,
        .central_offset = raw_central_offset,
        .entry_count = raw_entry_count,
        .central_end = eocd,
    };
}

const Zip64Values = struct {
    uncompressed: ?u64 = null,
    compressed: ?u64 = null,
    local_offset: ?u64 = null,
    disk_start: ?u32 = null,
};

fn readExtraU64(extra: []const u8, offset: *usize) !u64 {
    if (offset.* + 8 > extra.len) return error.InvalidZip64;
    const value = readInt(u64, extra, offset.*);
    offset.* += 8;
    return value;
}

fn readExtraU32(extra: []const u8, offset: *usize) !u32 {
    if (offset.* + 4 > extra.len) return error.InvalidZip64;
    const value = readInt(u32, extra, offset.*);
    offset.* += 4;
    return value;
}

/// 追加フィールドのブロックを走査する。ZIP64 (0x0001) は重複を拒否し、
/// それ以外の ID は長さだけ確認して読み飛ばす（パス・時刻の意味には使わない）。
fn scanExtra(extra: []const u8) !?[]const u8 {
    var offset: usize = 0;
    var zip64: ?[]const u8 = null;
    while (offset < extra.len) {
        if (offset + 4 > extra.len) return error.InvalidExtraField;
        const id = readInt(u16, extra, offset);
        const size = readInt(u16, extra, offset + 2);
        offset += 4;
        if (offset + size > extra.len) return error.InvalidExtraField;
        if (id == 0x0001) {
            if (zip64 != null) return error.InvalidZip64;
            zip64 = extra[offset .. offset + size];
        }
        offset += size;
    }
    return zip64;
}

/// APPNOTE の順序（展開後サイズ、圧縮後サイズ、局所ヘッダ位置、disk）で、
/// センチネルになったフィールドだけを ZIP64 extra から読む。センチネルが
/// 一つもないのに ZIP64 extra がある場合や、余剰・不足は拒否する。
fn zip64Values(
    block: ?[]const u8,
    need_uncompressed: bool,
    need_compressed: bool,
    need_offset: bool,
    need_disk: bool,
) !Zip64Values {
    const needed = need_uncompressed or need_compressed or need_offset or need_disk;
    if (!needed) {
        if (block != null) return error.InvalidZip64;
        return .{};
    }
    const extra = block orelse return error.InvalidZip64;
    var offset: usize = 0;
    var values = Zip64Values{};
    if (need_uncompressed) values.uncompressed = try readExtraU64(extra, &offset);
    if (need_compressed) values.compressed = try readExtraU64(extra, &offset);
    if (need_offset) values.local_offset = try readExtraU64(extra, &offset);
    if (need_disk) {
        values.disk_start = try readExtraU32(extra, &offset);
    }
    if (offset != extra.len) return error.InvalidZip64;
    return values;
}

/// 配布物として受理できる ZIP を読み、全エントリを展開して返す。上限は
/// 実バイト列と展開量の双方へ段階的に適用し、超過した時点で中断する。
pub fn open(allocator: Allocator, bytes: []const u8, limits: Limits) !Archive {
    if (bytes.len > limits.max_compressed_bytes) return error.CompressedSizeExceeded;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const eocd = try readEndOfCentralDirectory(bytes);
    if (eocd.entry_count > @as(u64, limits.max_files)) return error.EntryCountExceeded;
    const entry_count: usize = @intCast(eocd.entry_count);
    const central_offset: u64 = eocd.central_offset;
    const central_end: u64 = std.math.add(u64, eocd.central_offset, eocd.central_size) catch
        return error.InvalidArchive;
    if (central_end != eocd.central_end) return error.InvalidArchive;
    if (central_end > bytes.len) return error.InvalidArchive;

    const central = try arena_allocator.alloc(CentralEntry, entry_count);
    var offset: u64 = central_offset;
    var total_compressed: u64 = 0;
    var previous_name: ?[]const u8 = null;
    var folded_names: std.StringHashMapUnmanaged(void) = .empty;
    for (central) |*entry| {
        if (!hasBytes(bytes, offset, 46)) return error.InvalidArchive;
        const record: usize = @intCast(offset);
        if (readInt(u32, bytes, record) != 0x02014b50) return error.InvalidArchive;
        const name_len = readInt(u16, bytes, record + 28);
        const extra_len = readInt(u16, bytes, record + 30);
        const comment_len = readInt(u16, bytes, record + 32);
        const record_end = std.math.add(u64, offset + 46, @as(u64, name_len) + extra_len + comment_len) catch
            return error.InvalidArchive;
        if (record_end > bytes.len) return error.InvalidArchive;
        const name = bytes[record + 46 ..][0..name_len];
        if (name.len == 0) return error.InvalidPath;
        if (name[name.len - 1] == '/') return error.DirectoryEntry;
        try validPathEncoding(name, readInt(u16, bytes, record + 8));
        if (!types.validPath(name)) return error.InvalidPath;

        const flags = readInt(u16, bytes, record + 8);
        if ((flags & 0x0001) != 0 or (flags & 0x0040) != 0)
            return error.EncryptionUnsupported;
        if ((flags & ~(utf8_flag | data_descriptor_flag)) != 0)
            return error.NonCanonicalHeader;
        const method = readInt(u16, bytes, record + 10);
        if (method != 0 and method != 8) return error.UnsupportedCompression;
        if (readInt(u16, bytes, record + 12) != canonical_dos_time or
            readInt(u16, bytes, record + 14) != canonical_dos_date)
            return error.TimestampMismatch;
        if (comment_len != 0) return error.NonCanonicalHeader;

        const extra = bytes[record + 46 + name_len ..][0..extra_len];
        const zip64 = try scanExtra(extra);
        const raw_uncompressed = readInt(u32, bytes, record + 24);
        const raw_compressed = readInt(u32, bytes, record + 20);
        const raw_offset = readInt(u32, bytes, record + 42);
        const raw_disk = readInt(u16, bytes, record + 34);
        const need_uncompressed = raw_uncompressed == 0xFFFFFFFF;
        const need_compressed = raw_compressed == 0xFFFFFFFF;
        const need_offset = raw_offset == 0xFFFFFFFF;
        const need_disk = raw_disk == 0xFFFF;
        const resolved = try zip64Values(
            zip64,
            need_uncompressed,
            need_compressed,
            need_offset,
            need_disk,
        );
        const disk_start = if (need_disk) resolved.disk_start.? else raw_disk;
        if (disk_start != 0) return error.InvalidArchive;

        entry.* = .{
            .name = name,
            .flags = flags,
            .method = method,
            .mod_time = readInt(u16, bytes, record + 12),
            .mod_date = readInt(u16, bytes, record + 14),
            .crc32 = readInt(u32, bytes, record + 16),
            .compressed_size = if (need_compressed)
                resolved.compressed.?
            else
                raw_compressed,
            .uncompressed_size = if (need_uncompressed)
                resolved.uncompressed.?
            else
                raw_uncompressed,
            .version_made_by = readInt(u16, bytes, record + 4),
            .external_attrs = readInt(u32, bytes, record + 38),
            .local_offset = if (need_offset) resolved.local_offset.? else raw_offset,
            .zip64_sizes = need_uncompressed or need_compressed,
        };

        if (previous_name) |previous| {
            const order = std.mem.order(u8, previous, name);
            if (order == .eq) return error.DuplicateEntry;
            if (order == .gt) return error.NotSorted;
        }
        previous_name = name;
        const folded = try caseFoldKey(arena_allocator, name);
        const result = try folded_names.getOrPut(arena_allocator, folded);
        if (result.found_existing) return error.NameCollision;

        const made_by_os = entry.version_made_by >> 8;
        if (made_by_os == 3 or (entry.external_attrs >> 16) != 0) {
            const mode = entry.external_attrs >> 16;
            const file_type = mode & 0o170000;
            if (file_type == 0o120000) return error.SymlinkEntry;
            if (file_type == 0o040000) return error.DirectoryEntry;
            if (file_type != 0 and file_type != 0o100000) return error.UnsupportedEntryType;
        }
        if ((entry.external_attrs & 0x10) != 0) return error.DirectoryEntry;
        if ((entry.external_attrs & 0x08) != 0) return error.UnsupportedEntryType;

        total_compressed = std.math.add(u64, total_compressed, entry.compressed_size) catch
            return error.CompressedSizeExceeded;
        if (total_compressed > limits.max_compressed_bytes) return error.CompressedSizeExceeded;

        offset = record_end;
    }
    if (offset != central_end) return error.InvalidArchive;

    const entries = try arena_allocator.alloc(Archive.Entry, central.len);
    var index_map: std.StringHashMapUnmanaged(usize) = .empty;
    var total_uncompressed: u64 = 0;
    var expected_local: u64 = 0;
    for (central, 0..) |entry, index| {
        if (entry.local_offset != expected_local) return error.NonCanonicalLayout;
        const local: u64 = entry.local_offset;
        if (!hasBytes(bytes, local, 30)) return error.InvalidArchive;
        const local_index: usize = @intCast(local);
        if (readInt(u32, bytes, local_index) != 0x04034b50) return error.LocalHeaderMismatch;
        const local_name_len = readInt(u16, bytes, local_index + 26);
        const local_extra_len = readInt(u16, bytes, local_index + 28);
        const extra_offset = std.math.add(u64, local + 30, local_name_len) catch
            return error.InvalidArchive;
        const data_offset = std.math.add(u64, extra_offset, local_extra_len) catch
            return error.InvalidArchive;
        const data_end = std.math.add(u64, data_offset, entry.compressed_size) catch
            return error.InvalidArchive;
        if (data_end > central_offset) return error.InvalidArchive;
        if (local_name_len != entry.name.len) return error.LocalHeaderMismatch;
        const local_name = bytes[local_index + 30 ..][0..local_name_len];
        if (!std.mem.eql(u8, local_name, entry.name)) return error.LocalHeaderMismatch;
        if (readInt(u16, bytes, local_index + 6) != entry.flags or
            readInt(u16, bytes, local_index + 8) != entry.method or
            readInt(u16, bytes, local_index + 10) != entry.mod_time or
            readInt(u16, bytes, local_index + 12) != entry.mod_date)
        {
            return error.LocalHeaderMismatch;
        }

        const local_extra = bytes[@intCast(extra_offset)..][0..local_extra_len];
        const local_zip64 = try scanExtra(local_extra);
        const raw_crc = readInt(u32, bytes, local_index + 14);
        const raw_compressed = readInt(u32, bytes, local_index + 18);
        const raw_uncompressed = readInt(u32, bytes, local_index + 22);
        const need_uncompressed = raw_uncompressed == 0xFFFFFFFF;
        const need_compressed = raw_compressed == 0xFFFFFFFF;
        const resolved = try zip64Values(
            local_zip64,
            need_uncompressed,
            need_compressed,
            false,
            false,
        );
        const local_uncompressed = if (need_uncompressed)
            resolved.uncompressed.?
        else
            raw_uncompressed;
        const local_compressed = if (need_compressed)
            resolved.compressed.?
        else
            raw_compressed;
        const has_descriptor = (entry.flags & data_descriptor_flag) != 0;
        if (has_descriptor) {
            if (raw_crc != 0 and raw_crc != entry.crc32) return error.LocalHeaderMismatch;
            if (local_uncompressed != 0 and local_uncompressed != entry.uncompressed_size)
                return error.LocalHeaderMismatch;
            if (local_compressed != 0 and local_compressed != entry.compressed_size)
                return error.LocalHeaderMismatch;
        } else {
            if (raw_crc != entry.crc32 or
                local_compressed != entry.compressed_size or
                local_uncompressed != entry.uncompressed_size)
                return error.LocalHeaderMismatch;
        }

        const compressed = bytes[@intCast(data_offset)..@intCast(data_end)];
        const remaining = limits.max_uncompressed_bytes - total_uncompressed;
        const data = switch (entry.method) {
            0 => try storedData(arena_allocator, compressed, entry.uncompressed_size, remaining),
            8 => try inflateData(
                arena_allocator,
                compressed,
                entry.uncompressed_size,
                remaining,
            ),
            else => unreachable,
        };
        if (std.hash.Crc32.hash(data) != entry.crc32) return error.ChecksumMismatch;
        total_uncompressed = std.math.add(u64, total_uncompressed, data.len) catch
            return error.UncompressedSizeExceeded;

        var next_local = data_end;
        if (has_descriptor) {
            next_local = try readDataDescriptor(bytes, data_end, central_offset, entry);
        }
        // パスも入力バイト列から複製する。Archive は入力の寿命に依存しない。
        const owned_name = try arena_allocator.dupe(u8, entry.name);
        entries[index] = .{ .path = owned_name, .data = data };
        try index_map.put(arena_allocator, owned_name, index);
        expected_local = next_local;
    }
    if (expected_local != central_offset) return error.NonCanonicalLayout;
    return .{ .arena = arena, .entries = entries, .index = index_map };
}

/// データ記述子を読み、中央ディレクトリの CRC・サイズと照合する。署名は
/// 任意。ZIP64 のサイズを使ったエントリでは 8 バイトのサイズを読む。
fn readDataDescriptor(
    bytes: []const u8,
    start: u64,
    limit: u64,
    entry: CentralEntry,
) !u64 {
    var position = start;
    if (position + 4 > limit) return error.DataDescriptorMismatch;
    if (readInt(u32, bytes, @intCast(position)) == 0x08074b50) position += 4;
    const width: u64 = if (entry.zip64_sizes) 8 else 4;
    if (position + 4 + width + width > limit) return error.DataDescriptorMismatch;
    const crc = readInt(u32, bytes, @intCast(position));
    position += 4;
    const compressed: u64 = if (width == 8)
        readInt(u64, bytes, @intCast(position))
    else
        readInt(u32, bytes, @intCast(position));
    position += width;
    const uncompressed: u64 = if (width == 8)
        readInt(u64, bytes, @intCast(position))
    else
        readInt(u32, bytes, @intCast(position));
    position += width;
    if (crc != entry.crc32 or compressed != entry.compressed_size or
        uncompressed != entry.uncompressed_size)
    {
        return error.DataDescriptorMismatch;
    }
    return position;
}

fn storedData(
    allocator: Allocator,
    compressed: []const u8,
    declared_size: u64,
    remaining: u64,
) ![]u8 {
    if (compressed.len != declared_size) return error.InvalidSizes;
    if (compressed.len > remaining) return error.UncompressedSizeExceeded;
    return try allocator.dupe(u8, compressed);
}

/// DEFLATE を 16 KiB ずつ展開し、宣言サイズと残り上限を超えた時点で中断する。
fn inflateData(
    allocator: Allocator,
    compressed: []const u8,
    declared_size: u64,
    remaining: u64,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var input = std.Io.Reader.fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var decompressor = flate.Decompress.init(&input, .raw, &window);
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const produced: u64 = output.items.len;
        if (produced > declared_size or produced > remaining)
            return error.UncompressedSizeExceeded;
        const declared_remaining: u64 = declared_size - produced;
        const limit_remaining: u64 = remaining - produced;
        // 上限まで読むため +1 するが、宣言サイズが u64 の最大値でも
        // オーバーフローしないよう先にバッファ長と比較する。
        const readable = @min(declared_remaining, limit_remaining);
        const capacity64: u64 = if (readable >= buffer.len) buffer.len else readable + 1;
        const capacity: usize = @intCast(capacity64);
        const read_len = decompressor.reader.readSliceShort(buffer[0..capacity]) catch
            return error.InvalidDeflate;
        if (read_len == 0) break;
        const next = std.math.add(u64, produced, read_len) catch return error.SizeMismatch;
        if (next > declared_size) return error.SizeMismatch;
        if (next > remaining) return error.UncompressedSizeExceeded;
        try output.appendSlice(allocator, buffer[0..read_len]);
    }
    if (output.items.len != declared_size) return error.SizeMismatch;
    return output.toOwnedSlice(allocator);
}
