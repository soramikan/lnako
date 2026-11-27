//! v1 Canonical ZIP の単体テスト。適合性フィクスチャ Z-02〜Z-04・Z-07・
//! Z-08・Z-11・Z-12 と、ZIP の安全検査（ZIP64・暗号化・局所ヘッダ・CRC・
//! サイズ・DEFLATE）を扱う。

const std = @import("std");
const testing = std.testing;
const zip = @import("v1_zip.zig");
const types = @import("v1_types.zig");

const Allocator = std.mem.Allocator;

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn eocdOffset(bytes: []const u8) usize {
    return bytes.len - 22;
}

fn centralOffset(bytes: []const u8) usize {
    return readU32(bytes, eocdOffset(bytes) + 16);
}

fn centralN(bytes: []const u8, index: usize) usize {
    var offset = centralOffset(bytes);
    var current: usize = 0;
    while (current < index) : (current += 1) {
        const name_len = readU16(bytes, offset + 28);
        const extra_len = readU16(bytes, offset + 30);
        const comment_len = readU16(bytes, offset + 32);
        offset += 46 + name_len + extra_len + comment_len;
    }
    return offset;
}

fn localOfCentral(bytes: []const u8, central: usize) usize {
    return readU32(bytes, central + 42);
}

fn sample(allocator: Allocator) ![]u8 {
    const entries = [_]zip.SourceEntry{
        .{ .path = "a.txt", .data = "abc" },
        .{ .path = "b.txt", .data = "hello hello hello", .compression = .deflate },
    };
    return zip.build(allocator, &entries, .{});
}

test "Z-02 相対パスの禁止例 ../evil を拒否する" {
    try testing.expect(!types.validPath("../evil"));
    try testing.expect(!types.validPath("a/../b"));
    try testing.expect(!types.validPath("/abs"));
    try testing.expect(!types.validPath("a\\b"));
    try testing.expect(!types.validPath("C:/windows"));
    try testing.expect(!types.validPath("a//b"));
    try testing.expect(!types.validPath("./a"));
    const entries = [_]zip.SourceEntry{.{ .path = "../evil", .data = "x" }};
    try testing.expectError(error.InvalidPath, zip.build(testing.allocator, &entries, .{}));
}

test "Z-03 エントリ種別検査でシンボリックリンクを拒否する" {
    const allocator = testing.allocator;
    const bytes = try sample(allocator);
    defer allocator.free(bytes);
    const central = centralN(bytes, 0);
    writeU16(bytes, central + 4, 0x0314); // version made by: Unix
    writeU32(bytes, central + 38, @as(u32, 0o120777) << 16);
    try testing.expectError(error.SymlinkEntry, zip.open(allocator, bytes, .{}));
}

test "Z-04 大小文字を無視した名前衝突を拒否する" {
    const entries = [_]zip.SourceEntry{
        .{ .path = "A.txt", .data = "1" },
        .{ .path = "a.txt", .data = "2" },
    };
    try testing.expectError(error.NameCollision, zip.build(testing.allocator, &entries, .{}));
}

test "Z-07 展開量の上限を超えた時点で中断する" {
    const allocator = testing.allocator;
    const entries = [_]zip.SourceEntry{
        .{ .path = "payload.bin", .data = "0123456789", .compression = .deflate },
    };
    try testing.expectError(error.UncompressedSizeExceeded, zip.build(allocator, &entries, .{
        .max_uncompressed_bytes = 9,
    }));

    const bytes = try zip.build(allocator, &entries, .{});
    defer allocator.free(bytes);
    try testing.expectError(error.UncompressedSizeExceeded, zip.open(allocator, bytes, .{
        .max_uncompressed_bytes = 9,
    }));
    // 既定値の 100 MiB を小さくした同一経路。上限に達した直前で止まる。
    var archive = try zip.open(allocator, bytes, .{ .max_uncompressed_bytes = 10 });
    defer archive.deinit();
    try testing.expectEqualStrings("0123456789", archive.entryBytes("payload.bin").?);
}

test "Z-07 既定上限100MiB+1の実展開を最初の超過で中断する" {
    const allocator = testing.allocator;
    try testing.expectEqual(@as(u64, 100 * 1024 * 1024), zip.default_max_uncompressed_bytes);
    const expanded = zip.default_max_uncompressed_bytes + 1;
    const bomb = try deflateZeros(allocator, expanded);
    defer allocator.free(bomb.body);
    // 10 バイトの代替ではなく、宣言どおり 100 MiB + 1 バイトへ展開する
    // DEFLATE 入力を既定上限のまま通す。
    const bytes = try rawSingle(allocator, .{
        .name = "payload.bin",
        .data = "",
        .body = bomb.body,
        .method = 8,
        .crc = bomb.crc,
        .uncompressed_size = @intCast(expanded),
    });
    defer allocator.free(bytes);
    try testing.expectError(error.UncompressedSizeExceeded, zip.open(allocator, bytes, .{}));
}

test "Z-08 固定DOS日時以外を拒否する" {
    const allocator = testing.allocator;
    const bytes = try sample(allocator);
    defer allocator.free(bytes);
    const central = centralN(bytes, 0);
    const local = localOfCentral(bytes, central);
    writeU16(bytes, central + 14, 0x0022);
    writeU16(bytes, local + 12, 0x0022);
    try testing.expectError(error.TimestampMismatch, zip.open(allocator, bytes, .{}));
}

test "Z-11 独立したディレクトリエントリを拒否する" {
    const allocator = testing.allocator;
    const bytes = try rawDirectoryZip(allocator);
    defer allocator.free(bytes);
    try testing.expectError(error.DirectoryEntry, zip.open(allocator, bytes, .{}));

    // 末尾スラッシュのない名前でも、外部属性がディレクトリなら拒否する。
    const file_bytes = try sample(allocator);
    defer allocator.free(file_bytes);
    const central = centralN(file_bytes, 0);
    writeU32(file_bytes, central + 38, 0x10);
    try testing.expectError(error.DirectoryEntry, zip.open(allocator, file_bytes, .{}));
}

test "Z-12 同一入力からZIPバイト列とSHA-256が一致する" {
    const allocator = testing.allocator;
    const first = try sample(allocator);
    defer allocator.free(first);
    const second = try sample(allocator);
    defer allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);
    var first_digest: [32]u8 = undefined;
    var second_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(first, &first_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(second, &second_digest, .{});
    try testing.expectEqualSlices(u8, &first_digest, &second_digest);
    var archive = try zip.open(allocator, first, .{});
    defer archive.deinit();
    try testing.expectEqualStrings("abc", archive.entryBytes("a.txt").?);
    try testing.expectEqualStrings("hello hello hello", archive.entryBytes("b.txt").?);
}

test "DEFLATEエントリを展開してCRCとサイズを照合する" {
    const allocator = testing.allocator;
    const entries = [_]zip.SourceEntry{
        .{ .path = "data.json", .data = "hello hello hello hello hello hello hello", .compression = .deflate },
    };
    const bytes = try zip.build(allocator, &entries, .{});
    defer allocator.free(bytes);
    const central = centralN(bytes, 0);
    try testing.expectEqual(@as(u16, 8), readU16(bytes, central + 10));
    try testing.expect(readU32(bytes, central + 20) < readU32(bytes, central + 24));
    var archive = try zip.open(allocator, bytes, .{});
    defer archive.deinit();
    try testing.expectEqualStrings("hello hello hello hello hello hello hello", archive.entryBytes("data.json").?);
}

test "ZIP64: 妥当なEOCD64とZIP64 extraを受理する" {
    const allocator = testing.allocator;
    const base = try sample(allocator);
    defer allocator.free(base);
    const eocd64 = try withZip64Eocd(allocator, base);
    defer allocator.free(eocd64);
    var archive = try zip.open(allocator, eocd64, .{});
    defer archive.deinit();
    try testing.expectEqualStrings("abc", archive.entryBytes("a.txt").?);
    try testing.expectEqualStrings("hello hello hello", archive.entryBytes("b.txt").?);

    const central_extra = try zip64SizeExtra(allocator, 3, 3);
    defer allocator.free(central_extra);
    const central_zip64 = try rawSingle(allocator, .{
        .name = "z.txt",
        .data = "abc",
        .central_extra = central_extra,
        .local_compressed = 3,
        .local_uncompressed = 3,
        .central_compressed = 0xFFFFFFFF,
        .central_uncompressed = 0xFFFFFFFF,
    });
    defer allocator.free(central_zip64);
    var central_archive = try zip.open(allocator, central_zip64, .{});
    defer central_archive.deinit();
    try testing.expectEqualStrings("abc", central_archive.entryBytes("z.txt").?);

    const local_extra = try zip64SizeExtra(allocator, 3, 3);
    defer allocator.free(local_extra);
    const local_zip64 = try rawSingle(allocator, .{
        .name = "z.txt",
        .data = "abc",
        .local_extra = local_extra,
        .local_compressed = 0xFFFFFFFF,
        .local_uncompressed = 0xFFFFFFFF,
    });
    defer allocator.free(local_zip64);
    var local_archive = try zip.open(allocator, local_zip64, .{});
    defer local_archive.deinit();
    try testing.expectEqualStrings("abc", local_archive.entryBytes("z.txt").?);
}

test "ZIP64: 不正なEOCD64とサイズヘッダを拒否する" {
    const allocator = testing.allocator;
    const missing_locator = try sample(allocator);
    defer allocator.free(missing_locator);
    writeU32(missing_locator, eocdOffset(missing_locator) + 16, 0xFFFFFFFF);
    try testing.expectError(error.InvalidZip64, zip.open(allocator, missing_locator, .{}));

    const missing_record = try sample(allocator);
    defer allocator.free(missing_record);
    writeU16(missing_record, eocdOffset(missing_record) + 10, 0xFFFF);
    try testing.expectError(error.InvalidZip64, zip.open(allocator, missing_record, .{}));

    const missing_extra = try rawSingle(allocator, .{
        .name = "z.txt",
        .data = "abc",
        .central_compressed = 0xFFFFFFFF,
        .central_uncompressed = 0xFFFFFFFF,
    });
    defer allocator.free(missing_extra);
    try testing.expectError(error.InvalidZip64, zip.open(allocator, missing_extra, .{}));
}

test "標準ZIP: EFS未設定のASCIIパスを受理し、非ASCIIは拒否する" {
    const allocator = testing.allocator;
    const bytes = try sample(allocator);
    defer allocator.free(bytes);
    clearUtf8Flags(bytes);
    var archive = try zip.open(allocator, bytes, .{});
    defer archive.deinit();
    try testing.expectEqualStrings("abc", archive.entryBytes("a.txt").?);

    const raw = try rawSingle(allocator, .{ .name = "é.txt", .data = "abc", .flags = 0 });
    defer allocator.free(raw);
    try testing.expectError(error.AmbiguousPathEncoding, zip.open(allocator, raw, .{}));
}

test "Z-04 UTF-8パスの大小文字衝突も拒否する" {
    const entries = [_]zip.SourceEntry{
        .{ .path = "Ä.txt", .data = "1" },
        .{ .path = "ä.txt", .data = "2" },
    };
    try testing.expectError(error.NameCollision, zip.build(testing.allocator, &entries, .{}));
}

test "Z-04 UTF-8パスの大小文字衝突を読み込み時にも拒否する" {
    const allocator = testing.allocator;
    const entries = [_]zip.SourceEntry{
        .{ .path = "A1.txt", .data = "1" },
        .{ .path = "B1.txt", .data = "2" },
    };
    const bytes = try zip.build(allocator, &entries, .{});
    defer allocator.free(bytes);
    const first = centralN(bytes, 0);
    const second = centralN(bytes, 1);
    @memcpy(bytes[first + 46 .. first + 52], "Ä.txt");
    @memcpy(bytes[second + 46 .. second + 52], "ä.txt");
    const first_local = localOfCentral(bytes, first);
    const second_local = localOfCentral(bytes, second);
    @memcpy(bytes[first_local + 30 .. first_local + 36], "Ä.txt");
    @memcpy(bytes[second_local + 30 .. second_local + 36], "ä.txt");
    try testing.expectError(error.NameCollision, zip.open(allocator, bytes, .{}));
}

test "データ記述子付きの標準ZIPを受理し、不一致を拒否する" {
    const allocator = testing.allocator;
    const accepted = try rawSingle(allocator, .{
        .name = "a.txt",
        .data = "abc",
        .flags = 0x0808,
        .descriptor = true,
    });
    defer allocator.free(accepted);
    var archive = try zip.open(allocator, accepted, .{});
    defer archive.deinit();
    try testing.expectEqualStrings("abc", archive.entryBytes("a.txt").?);

    const no_signature = try rawSingle(allocator, .{
        .name = "a.txt",
        .data = "abc",
        .flags = 0x0808,
        .descriptor = true,
        .descriptor_signature = false,
    });
    defer allocator.free(no_signature);
    var no_signature_archive = try zip.open(allocator, no_signature, .{});
    defer no_signature_archive.deinit();
    try testing.expectEqualStrings("abc", no_signature_archive.entryBytes("a.txt").?);

    const mismatch = try rawSingle(allocator, .{
        .name = "a.txt",
        .data = "abc",
        .flags = 0x0808,
        .descriptor = true,
        .descriptor_crc = 0,
    });
    defer allocator.free(mismatch);
    try testing.expectError(error.DataDescriptorMismatch, zip.open(allocator, mismatch, .{}));
}

test "安全な追加フィールドを受理し、壊れたブロックを拒否する" {
    const allocator = testing.allocator;
    const safe_extra = [_]u8{ 0x55, 0x54, 0x05, 0x00, 1, 2, 3, 4, 5 };
    const accepted = try rawSingle(allocator, .{
        .name = "a.txt",
        .data = "abc",
        .local_extra = &safe_extra,
        .central_extra = &safe_extra,
    });
    defer allocator.free(accepted);
    var archive = try zip.open(allocator, accepted, .{});
    defer archive.deinit();
    try testing.expectEqualStrings("abc", archive.entryBytes("a.txt").?);

    const broken_extra = [_]u8{ 0x55, 0x54, 0x05, 0x00, 0x01 };
    const broken = try rawSingle(allocator, .{
        .name = "a.txt",
        .data = "abc",
        .local_extra = &broken_extra,
    });
    defer allocator.free(broken);
    try testing.expectError(error.InvalidExtraField, zip.open(allocator, broken, .{}));
}

test "圧縮後上限はZIP実バイト長にも適用する" {
    const allocator = testing.allocator;
    const bytes = try sample(allocator);
    defer allocator.free(bytes);
    try testing.expectError(error.CompressedSizeExceeded, zip.open(allocator, bytes, .{
        .max_compressed_bytes = bytes.len - 1,
    }));
}

test "局所ヘッダの名前・CRC・サイズ不一致を拒否する" {
    const allocator = testing.allocator;
    const bytes = try sample(allocator);
    defer allocator.free(bytes);
    const central = centralN(bytes, 0);
    const local = localOfCentral(bytes, central);
    bytes[local + 30] = 'z';
    try testing.expectError(error.LocalHeaderMismatch, zip.open(allocator, bytes, .{}));
}

test "CRC不一致を拒否する" {
    const allocator = testing.allocator;
    const bytes = try sample(allocator);
    defer allocator.free(bytes);
    const central = centralN(bytes, 0);
    const local = localOfCentral(bytes, central);
    writeU32(bytes, central + 16, 0);
    writeU32(bytes, local + 14, 0);
    try testing.expectError(error.ChecksumMismatch, zip.open(allocator, bytes, .{}));
}

test "暗号化フラグを拒否する" {
    const allocator = testing.allocator;
    const encrypted = try sample(allocator);
    defer allocator.free(encrypted);
    const encrypted_central = centralN(encrypted, 0);
    writeU16(encrypted, encrypted_central + 8, 0x0801);
    try testing.expectError(error.EncryptionUnsupported, zip.open(allocator, encrypted, .{}));
}

test "昇順でないエントリ名を拒否する" {
    const allocator = testing.allocator;
    const bytes = try sample(allocator);
    defer allocator.free(bytes);
    const first = centralN(bytes, 0);
    const second = centralN(bytes, 1);
    @memcpy(bytes[first + 46 .. first + 51], "b.txt");
    @memcpy(bytes[second + 46 .. second + 51], "a.txt");
    try testing.expectError(error.NotSorted, zip.open(allocator, bytes, .{}));
}

test "DEFLATEの宣言サイズより実展開が大きい場合を拒否する" {
    const allocator = testing.allocator;
    const entries = [_]zip.SourceEntry{
        .{ .path = "payload.bin", .data = "0123456789", .compression = .deflate },
    };
    const bytes = try zip.build(allocator, &entries, .{});
    defer allocator.free(bytes);
    const central = centralN(bytes, 0);
    const local = localOfCentral(bytes, central);
    writeU32(bytes, central + 24, 9);
    writeU32(bytes, local + 22, 9);
    try testing.expectError(error.SizeMismatch, zip.open(allocator, bytes, .{}));
}

fn appendU16(list: *std.ArrayList(u8), allocator: Allocator, value: u16) !void {
    var buffer: [2]u8 = undefined;
    std.mem.writeInt(u16, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

fn appendU32(list: *std.ArrayList(u8), allocator: Allocator, value: u32) !void {
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

fn appendU64(list: *std.ArrayList(u8), allocator: Allocator, value: u64) !void {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

/// EFS ビットを落とした、ASCII 名だけの一般的な ZIP にする。
fn clearUtf8Flags(bytes: []u8) void {
    const eocd = eocdOffset(bytes);
    const count = readU16(bytes, eocd + 10);
    var offset: usize = readU32(bytes, eocd + 16);
    for (0..count) |_| {
        writeU16(bytes, offset + 8, 0);
        const local: usize = readU32(bytes, offset + 42);
        writeU16(bytes, local + 6, 0);
        offset += 46 + readU16(bytes, offset + 28) + readU16(bytes, offset + 30) +
            readU16(bytes, offset + 32);
    }
}

/// EOCD64/locator を中央ディレクトリと EOCD の間に挿入し、通常の EOCD の
/// 件数・サイズ・位置を ZIP64 センチネルにする。
fn withZip64Eocd(allocator: Allocator, base: []const u8) ![]u8 {
    const eocd = eocdOffset(base);
    const count = readU16(base, eocd + 10);
    const central_size = readU32(base, eocd + 12);
    const central_offset = readU32(base, eocd + 16);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, base[0..eocd]);
    const zip64_offset = output.items.len;
    try appendU32(&output, allocator, 0x06064b50);
    try appendU64(&output, allocator, 44);
    try appendU16(&output, allocator, 45);
    try appendU16(&output, allocator, 45);
    try appendU32(&output, allocator, 0);
    try appendU32(&output, allocator, 0);
    try appendU64(&output, allocator, count);
    try appendU64(&output, allocator, count);
    try appendU64(&output, allocator, central_size);
    try appendU64(&output, allocator, central_offset);
    try appendU32(&output, allocator, 0x07064b50);
    try appendU32(&output, allocator, 0);
    try appendU64(&output, allocator, zip64_offset);
    try appendU32(&output, allocator, 1);
    try appendU32(&output, allocator, 0x06054b50);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0xFFFF);
    try appendU16(&output, allocator, 0xFFFF);
    try appendU32(&output, allocator, 0xFFFFFFFF);
    try appendU32(&output, allocator, 0xFFFFFFFF);
    try appendU16(&output, allocator, 0);
    return output.toOwnedSlice(allocator);
}

fn zip64SizeExtra(allocator: Allocator, uncompressed: u64, compressed: u64) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendU16(&output, allocator, 0x0001);
    try appendU16(&output, allocator, 16);
    try appendU64(&output, allocator, uncompressed);
    try appendU64(&output, allocator, compressed);
    return output.toOwnedSlice(allocator);
}

const RawOptions = struct {
    name: []const u8 = "a.txt",
    data: []const u8 = "abc",
    /// 中央・局所ヘッダへ書く圧縮後バイト列。省略時は `data` をそのまま使う。
    body: ?[]const u8 = null,
    method: u16 = 0,
    /// 展開後データの CRC。`data` を持たずに圧縮済みバイト列だけを渡す場合に
    /// 明示する。
    crc: ?u32 = null,
    /// 宣言する展開後サイズ。`data` を持たない圧縮エントリ用。
    uncompressed_size: ?u32 = null,
    flags: u16 = 0x0800,
    local_extra: []const u8 = "",
    central_extra: []const u8 = "",
    local_crc: ?u32 = null,
    local_compressed: ?u32 = null,
    local_uncompressed: ?u32 = null,
    central_crc: ?u32 = null,
    central_compressed: ?u32 = null,
    central_uncompressed: ?u32 = null,
    descriptor: bool = false,
    descriptor_crc: ?u32 = null,
    descriptor_signature: bool = true,
};

/// 1 通常ファイルだけの標準 ZIP を明示的に組み立てる。EFS なし・データ
/// 記述子・追加フィールド・ZIP64 センチネルの受理/拒否を直接確かめる。
fn rawSingle(allocator: Allocator, options: RawOptions) ![]u8 {
    const body = options.body orelse options.data;
    const crc = options.crc orelse std.hash.Crc32.hash(options.data);
    const central_crc = options.central_crc orelse crc;
    const uncompressed_size = options.uncompressed_size orelse
        @as(u32, @intCast(options.data.len));
    const central_compressed = options.central_compressed orelse @as(u32, @intCast(body.len));
    const central_uncompressed = options.central_uncompressed orelse uncompressed_size;
    const local_crc = options.local_crc orelse if (options.descriptor) 0 else central_crc;
    const local_compressed = options.local_compressed orelse if (options.descriptor) 0 else central_compressed;
    const local_uncompressed = options.local_uncompressed orelse if (options.descriptor) 0 else central_uncompressed;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendU32(&output, allocator, 0x04034b50);
    try appendU16(&output, allocator, 20);
    try appendU16(&output, allocator, options.flags);
    try appendU16(&output, allocator, options.method);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0x21);
    try appendU32(&output, allocator, local_crc);
    try appendU32(&output, allocator, local_compressed);
    try appendU32(&output, allocator, local_uncompressed);
    try appendU16(&output, allocator, @intCast(options.name.len));
    try appendU16(&output, allocator, @intCast(options.local_extra.len));
    try output.appendSlice(allocator, options.name);
    try output.appendSlice(allocator, options.local_extra);
    try output.appendSlice(allocator, body);
    if (options.descriptor) {
        if (options.descriptor_signature) try appendU32(&output, allocator, 0x08074b50);
        try appendU32(&output, allocator, options.descriptor_crc orelse crc);
        try appendU32(&output, allocator, central_compressed);
        try appendU32(&output, allocator, central_uncompressed);
    }
    const central_offset = output.items.len;
    try appendU32(&output, allocator, 0x02014b50);
    try appendU16(&output, allocator, 20);
    try appendU16(&output, allocator, 20);
    try appendU16(&output, allocator, options.flags);
    try appendU16(&output, allocator, options.method);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0x21);
    try appendU32(&output, allocator, central_crc);
    try appendU32(&output, allocator, central_compressed);
    try appendU32(&output, allocator, central_uncompressed);
    try appendU16(&output, allocator, @intCast(options.name.len));
    try appendU16(&output, allocator, @intCast(options.central_extra.len));
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0);
    try appendU32(&output, allocator, 0);
    try appendU32(&output, allocator, 0);
    try output.appendSlice(allocator, options.name);
    try output.appendSlice(allocator, options.central_extra);
    const central_size = output.items.len - central_offset;
    try appendU32(&output, allocator, 0x06054b50);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 1);
    try appendU16(&output, allocator, 1);
    try appendU32(&output, allocator, @intCast(central_size));
    try appendU32(&output, allocator, @intCast(central_offset));
    try appendU16(&output, allocator, 0);
    return output.toOwnedSlice(allocator);
}

/// 展開すると `total` バイトのゼロ列になる raw DEFLATE と、その CRC を作る。
/// 100 MiB 級の入力をテスト側で保持せず、圧縮バイト列だけを組み立てる。
fn deflateZeros(allocator: Allocator, total: u64) !struct { body: []u8, crc: u32 } {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 64 * 1024);
    errdefer output.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&output.writer, &window, .raw, .fastest);
    var crc = std.hash.Crc32.init();
    const zeros: [64 * 1024]u8 = @splat(0);
    var remaining = total;
    while (remaining > 0) {
        const count: usize = @intCast(@min(remaining, zeros.len));
        try compressor.writer.writeAll(zeros[0..count]);
        crc.update(zeros[0..count]);
        remaining -= count;
    }
    try compressor.writer.flush();
    try compressor.finish();
    return .{ .body = try output.toOwnedSlice(), .crc = crc.final() };
}

/// 末尾スラッシュのディレクトリエントリだけを持つ最小 ZIP。生成側は
/// ディレクトリを作らないため、読み込み側の検査を直接確かめる。
fn rawDirectoryZip(allocator: Allocator) ![]u8 {
    const name = "NAKO-PKG/";
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendU32(&output, allocator, 0x04034b50);
    try appendU16(&output, allocator, 20);
    try appendU16(&output, allocator, 0x0800);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0x21);
    try appendU32(&output, allocator, 0);
    try appendU32(&output, allocator, 0);
    try appendU32(&output, allocator, 0);
    try appendU16(&output, allocator, name.len);
    try appendU16(&output, allocator, 0);
    try output.appendSlice(allocator, name);
    const central_offset = output.items.len;
    try appendU32(&output, allocator, 0x02014b50);
    try appendU16(&output, allocator, 20);
    try appendU16(&output, allocator, 20);
    try appendU16(&output, allocator, 0x0800);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0x21);
    try appendU32(&output, allocator, 0);
    try appendU32(&output, allocator, 0);
    try appendU32(&output, allocator, 0);
    try appendU16(&output, allocator, name.len);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0);
    try appendU32(&output, allocator, 0);
    try appendU32(&output, allocator, 0);
    try output.appendSlice(allocator, name);
    const central_size = output.items.len - central_offset;
    try appendU32(&output, allocator, 0x06054b50);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 0);
    try appendU16(&output, allocator, 1);
    try appendU16(&output, allocator, 1);
    try appendU32(&output, allocator, @intCast(central_size));
    try appendU32(&output, allocator, @intCast(central_offset));
    try appendU16(&output, allocator, 0);
    return output.toOwnedSlice(allocator);
}
