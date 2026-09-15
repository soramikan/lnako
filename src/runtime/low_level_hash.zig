const std = @import("std");
const foundation = @import("low_level_foundation.zig");

/// Issue #32のincremental hashが対象とするアルゴリズム。`ハッシュ値計算` と
/// 同じ正規化（英数字以外を除去して小文字化）で解決する。RIPEMD-160とSM3は
/// stdに逐次stateが無いため、one-shotの `ハッシュ値計算` だけが対応する。
pub const Algorithm = enum {
    md5,
    md5_sha1,
    sha1,
    sha224,
    sha256,
    sha384,
    sha512,
    sha512_224,
    sha512_256,
    sha3_224,
    sha3_256,
    sha3_384,
    sha3_512,
    blake2b512,
    blake2s256,
    shake128,
    shake256,
    ripemd160,
    sm3,

    pub fn fromName(source: []const u8) ?Algorithm {
        var normalized: [96]u8 = undefined;
        const key = normalize(source, &normalized) orelse return null;
        return fromNormalized(key);
    }

    fn fromNormalized(key: []const u8) ?Algorithm {
        if (isAny(key, &.{ "md5", "rsamd5", "md5withrsaencryption", "ssl3md5" })) return .md5;
        if (std.mem.eql(u8, key, "md5sha1")) return .md5_sha1;
        if (isAny(key, &.{ "sha1", "rsasha1", "rsasha12", "sha1withrsaencryption", "ssl3sha1" })) return .sha1;
        if (isAny(key, &.{ "sha224", "rsasha224", "sha224withrsaencryption" })) return .sha224;
        if (isAny(key, &.{ "sha256", "rsasha256", "sha256withrsaencryption" })) return .sha256;
        if (isAny(key, &.{ "sha384", "rsasha384", "sha384withrsaencryption" })) return .sha384;
        if (isAny(key, &.{ "sha512", "rsasha512", "sha512withrsaencryption" })) return .sha512;
        if (isAny(key, &.{ "sha512224", "rsasha512224", "sha512224withrsaencryption" })) return .sha512_224;
        if (isAny(key, &.{ "sha512256", "rsasha512256", "sha512256withrsaencryption" })) return .sha512_256;
        if (isAny(key, &.{ "sha3224", "rsasha3224", "idrsassapkcs1v15withsha3224" })) return .sha3_224;
        if (isAny(key, &.{ "sha3256", "rsasha3256", "idrsassapkcs1v15withsha3256" })) return .sha3_256;
        if (isAny(key, &.{ "sha3384", "rsasha3384", "idrsassapkcs1v15withsha3384" })) return .sha3_384;
        if (isAny(key, &.{ "sha3512", "rsasha3512", "idrsassapkcs1v15withsha3512" })) return .sha3_512;
        if (std.mem.eql(u8, key, "blake2b512")) return .blake2b512;
        if (std.mem.eql(u8, key, "blake2s256")) return .blake2s256;
        if (std.mem.eql(u8, key, "shake128")) return .shake128;
        if (std.mem.eql(u8, key, "shake256")) return .shake256;
        if (isAny(key, &.{ "ripemd", "ripemd160", "ripemd160withrsa", "rmd160", "rsaripemd160" })) return .ripemd160;
        if (isAny(key, &.{ "sm3", "sm3withrsaencryption", "rsasm3" })) return .sm3;
        return null;
    }

    /// 逐次stateを保持できるアルゴリズムか。RIPEMD-160とSM3は `false` で、
    /// `ハッシュ開始` は `ENOTSUP` を返す。
    pub fn isIncremental(self: Algorithm) bool {
        return switch (self) {
            .ripemd160, .sm3 => false,
            else => true,
        };
    }

    pub fn digestLength(self: Algorithm) usize {
        return switch (self) {
            .md5 => 16,
            .md5_sha1 => 36,
            .sha1 => 20,
            .sha224 => 28,
            .sha256 => 32,
            .sha384 => 48,
            .sha512 => 64,
            .sha512_224 => 28,
            .sha512_256 => 32,
            .sha3_224 => 28,
            .sha3_256 => 32,
            .sha3_384 => 48,
            .sha3_512 => 64,
            .blake2b512 => 64,
            .blake2s256 => 32,
            .shake128 => 16,
            .shake256 => 32,
            .ripemd160 => 20,
            .sm3 => 32,
        };
    }

    fn stream(self: Algorithm) ?StreamAlgorithm {
        return switch (self) {
            .md5 => .md5,
            .md5_sha1 => .md5_sha1,
            .sha1 => .sha1,
            .sha224 => .sha224,
            .sha256 => .sha256,
            .sha384 => .sha384,
            .sha512 => .sha512,
            .sha512_224 => .sha512_224,
            .sha512_256 => .sha512_256,
            .sha3_224 => .sha3_224,
            .sha3_256 => .sha3_256,
            .sha3_384 => .sha3_384,
            .sha3_512 => .sha3_512,
            .blake2b512 => .blake2b512,
            .blake2s256 => .blake2s256,
            .shake128 => .shake128,
            .shake256 => .shake256,
            .ripemd160, .sm3 => null,
        };
    }
};

const StreamAlgorithm = enum {
    md5,
    md5_sha1,
    sha1,
    sha224,
    sha256,
    sha384,
    sha512,
    sha512_224,
    sha512_256,
    sha3_224,
    sha3_256,
    sha3_384,
    sha3_512,
    blake2b512,
    blake2s256,
    shake128,
    shake256,
};

const Md5Sha1 = struct {
    md5: std.crypto.hash.Md5,
    sha1: std.crypto.hash.Sha1,
};

/// 逐次ハッシュstate。startで初期化し、updateを任意回数呼び、finalizeで
/// digestを得る。`std.crypto.hash` のstateは値型でヒープ確保を持たない。
pub const Hasher = union(StreamAlgorithm) {
    md5: std.crypto.hash.Md5,
    md5_sha1: Md5Sha1,
    sha1: std.crypto.hash.Sha1,
    sha224: std.crypto.hash.sha2.Sha224,
    sha256: std.crypto.hash.sha2.Sha256,
    sha384: std.crypto.hash.sha2.Sha384,
    sha512: std.crypto.hash.sha2.Sha512,
    sha512_224: std.crypto.hash.sha2.Sha512_224,
    sha512_256: std.crypto.hash.sha2.Sha512_256,
    sha3_224: std.crypto.hash.sha3.Sha3_224,
    sha3_256: std.crypto.hash.sha3.Sha3_256,
    sha3_384: std.crypto.hash.sha3.Sha3_384,
    sha3_512: std.crypto.hash.sha3.Sha3_512,
    blake2b512: std.crypto.hash.blake2.Blake2b512,
    blake2s256: std.crypto.hash.blake2.Blake2s256,
    shake128: std.crypto.hash.sha3.Shake128,
    shake256: std.crypto.hash.sha3.Shake256,

    pub fn start(algorithm: Algorithm) ?Hasher {
        const stream = algorithm.stream() orelse return null;
        return switch (stream) {
            .md5 => .{ .md5 = std.crypto.hash.Md5.init(.{}) },
            .md5_sha1 => .{ .md5_sha1 = .{ .md5 = std.crypto.hash.Md5.init(.{}), .sha1 = std.crypto.hash.Sha1.init(.{}) } },
            .sha1 => .{ .sha1 = std.crypto.hash.Sha1.init(.{}) },
            .sha224 => .{ .sha224 = std.crypto.hash.sha2.Sha224.init(.{}) },
            .sha256 => .{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) },
            .sha384 => .{ .sha384 = std.crypto.hash.sha2.Sha384.init(.{}) },
            .sha512 => .{ .sha512 = std.crypto.hash.sha2.Sha512.init(.{}) },
            .sha512_224 => .{ .sha512_224 = std.crypto.hash.sha2.Sha512_224.init(.{}) },
            .sha512_256 => .{ .sha512_256 = std.crypto.hash.sha2.Sha512_256.init(.{}) },
            .sha3_224 => .{ .sha3_224 = std.crypto.hash.sha3.Sha3_224.init(.{}) },
            .sha3_256 => .{ .sha3_256 = std.crypto.hash.sha3.Sha3_256.init(.{}) },
            .sha3_384 => .{ .sha3_384 = std.crypto.hash.sha3.Sha3_384.init(.{}) },
            .sha3_512 => .{ .sha3_512 = std.crypto.hash.sha3.Sha3_512.init(.{}) },
            .blake2b512 => .{ .blake2b512 = std.crypto.hash.blake2.Blake2b512.init(.{}) },
            .blake2s256 => .{ .blake2s256 = std.crypto.hash.blake2.Blake2s256.init(.{}) },
            .shake128 => .{ .shake128 = std.crypto.hash.sha3.Shake128.init(.{}) },
            .shake256 => .{ .shake256 = std.crypto.hash.sha3.Shake256.init(.{}) },
        };
    }

    /// bytesを無変換で投入する。何度でも呼べる。
    pub fn update(self: *Hasher, bytes: []const u8) void {
        switch (self.*) {
            .md5 => |*hasher| hasher.update(bytes),
            .md5_sha1 => |*pair| {
                pair.md5.update(bytes);
                pair.sha1.update(bytes);
            },
            .sha1 => |*hasher| hasher.update(bytes),
            .sha224 => |*hasher| hasher.update(bytes),
            .sha256 => |*hasher| hasher.update(bytes),
            .sha384 => |*hasher| hasher.update(bytes),
            .sha512 => |*hasher| hasher.update(bytes),
            .sha512_224 => |*hasher| hasher.update(bytes),
            .sha512_256 => |*hasher| hasher.update(bytes),
            .sha3_224 => |*hasher| hasher.update(bytes),
            .sha3_256 => |*hasher| hasher.update(bytes),
            .sha3_384 => |*hasher| hasher.update(bytes),
            .sha3_512 => |*hasher| hasher.update(bytes),
            .blake2b512 => |*hasher| hasher.update(bytes),
            .blake2s256 => |*hasher| hasher.update(bytes),
            .shake128 => |*hasher| hasher.update(bytes),
            .shake256 => |*hasher| hasher.update(bytes),
        }
    }

    /// digestをallocatorで確保して返す。`md5_sha1` はmd5とsha1を連結する。
    pub fn finalize(self: *Hasher, allocator: std.mem.Allocator) ![]u8 {
        var output: [64]u8 = undefined;
        const length = self.writeDigest(&output);
        return allocator.dupe(u8, output[0..length]);
    }

    fn writeDigest(self: *Hasher, output: *[64]u8) usize {
        switch (self.*) {
            .md5 => |*hasher| {
                var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
                hasher.final(&digest);
                @memcpy(output[0..digest.len], &digest);
                return digest.len;
            },
            .md5_sha1 => |*pair| {
                var md5_digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
                var sha1_digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
                pair.md5.final(&md5_digest);
                pair.sha1.final(&sha1_digest);
                @memcpy(output[0..md5_digest.len], &md5_digest);
                @memcpy(output[md5_digest.len..][0..sha1_digest.len], &sha1_digest);
                return md5_digest.len + sha1_digest.len;
            },
            .sha1 => |*hasher| return finalFixed(std.crypto.hash.Sha1, hasher, output),
            .sha224 => |*hasher| return finalFixed(std.crypto.hash.sha2.Sha224, hasher, output),
            .sha256 => |*hasher| return finalFixed(std.crypto.hash.sha2.Sha256, hasher, output),
            .sha384 => |*hasher| return finalFixed(std.crypto.hash.sha2.Sha384, hasher, output),
            .sha512 => |*hasher| return finalFixed(std.crypto.hash.sha2.Sha512, hasher, output),
            .sha512_224 => |*hasher| return finalFixed(std.crypto.hash.sha2.Sha512_224, hasher, output),
            .sha512_256 => |*hasher| return finalFixed(std.crypto.hash.sha2.Sha512_256, hasher, output),
            .sha3_224 => |*hasher| return finalFixed(std.crypto.hash.sha3.Sha3_224, hasher, output),
            .sha3_256 => |*hasher| return finalFixed(std.crypto.hash.sha3.Sha3_256, hasher, output),
            .sha3_384 => |*hasher| return finalFixed(std.crypto.hash.sha3.Sha3_384, hasher, output),
            .sha3_512 => |*hasher| return finalFixed(std.crypto.hash.sha3.Sha3_512, hasher, output),
            .blake2b512 => |*hasher| return finalFixed(std.crypto.hash.blake2.Blake2b512, hasher, output),
            .blake2s256 => |*hasher| return finalFixed(std.crypto.hash.blake2.Blake2s256, hasher, output),
            .shake128 => |*hasher| {
                hasher.final(output[0..16]);
                return 16;
            },
            .shake256 => |*hasher| {
                hasher.final(output[0..32]);
                return 32;
            },
        }
    }
};

fn finalFixed(comptime Hash: type, hasher: *Hash, output: *[64]u8) usize {
    var digest: [Hash.digest_length]u8 = undefined;
    hasher.final(&digest);
    @memcpy(output[0..digest.len], &digest);
    return digest.len;
}

pub const HashStartError = error{ UnsupportedHashAlgorithm, IncrementalHashUnsupported };

/// 正規化したアルゴリズム名から逐次hasherを開始する。未知の名前は
/// `UnsupportedHashAlgorithm`（EINVAL）、逐次stateを持たないRIPEMD-160/SM3は
/// `IncrementalHashUnsupported`（ENOTSUP）を返す。
pub fn startNamed(name: []const u8) HashStartError!Hasher {
    const algorithm = Algorithm.fromName(name) orelse return error.UnsupportedHashAlgorithm;
    return Hasher.start(algorithm) orelse error.IncrementalHashUnsupported;
}

/// `ハッシュ完了` のENCODING。省略時はraw bytesで、既存 `ハッシュ値計算` と
/// 同じencoding名を受け付ける。
pub const Encoding = enum {
    raw,
    hex,
    base64,
    base64url,
    latin1,
    utf8,

    pub fn fromName(source: []const u8) ?Encoding {
        if (std.ascii.eqlIgnoreCase(source, "raw")) return .raw;
        if (std.ascii.eqlIgnoreCase(source, "hex")) return .hex;
        if (std.ascii.eqlIgnoreCase(source, "base64")) return .base64;
        if (std.ascii.eqlIgnoreCase(source, "base64url")) return .base64url;
        if (std.ascii.eqlIgnoreCase(source, "latin1") or std.ascii.eqlIgnoreCase(source, "binary")) return .latin1;
        if (std.ascii.eqlIgnoreCase(source, "utf8") or std.ascii.eqlIgnoreCase(source, "utf-8")) return .utf8;
        return null;
    }
};

/// ハッシュhandleのindexは、ファイルhandle（1から連番）とraw値が衝突しない
/// よう上位bitを立てた別空間から払い出す。これにより、ハッシュhandleを
/// ファイル命令へ、またはファイルhandleをハッシュ命令へ渡した場合は、
/// どちらのtableにも一致が無く `EBADF` になる。
pub const hash_handle_index_base: u32 = 0x8000_0000;

pub const HashEntry = struct {
    id: foundation.HandleId,
    hasher: Hasher,
};

/// 生成番号付きのハッシュhandle表。完了・破棄後もindexのgenerationを進める
/// ため、index再利用によるuse-after-freeを誤検出しない。
pub const HashHandleTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(HashEntry) = .empty,
    generations: std.AutoHashMap(u32, u32),
    free_indices: std.ArrayList(u32) = .empty,
    next_index: u32 = hash_handle_index_base,

    pub fn init(allocator: std.mem.Allocator) HashHandleTable {
        return .{ .allocator = allocator, .generations = std.AutoHashMap(u32, u32).init(allocator) };
    }

    pub fn deinit(self: *HashHandleTable) void {
        self.entries.deinit(self.allocator);
        self.generations.deinit();
        self.free_indices.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *const HashHandleTable) usize {
        return self.entries.items.len;
    }

    pub fn find(self: *HashHandleTable, id: foundation.HandleId) ?*HashEntry {
        for (self.entries.items) |*entry| {
            if (entry.id.index == id.index and entry.id.generation == id.generation) return entry;
        }
        return null;
    }

    pub fn insert(self: *HashHandleTable, hasher: Hasher) !foundation.HandleId {
        const id = try self.allocateId();
        errdefer self.free_indices.append(self.allocator, id.index) catch {};
        try self.entries.append(self.allocator, .{ .id = id, .hasher = hasher });
        return id;
    }

    /// 完了・破棄で同じindexのgenerationを進め、空きindexとして再利用する。
    pub fn remove(self: *HashHandleTable, id: foundation.HandleId) ?HashEntry {
        for (self.entries.items, 0..) |*entry, index| {
            if (entry.id.index == id.index and entry.id.generation == id.generation) {
                const removed = self.entries.swapRemove(index);
                if (self.generations.getPtr(id.index)) |generation| {
                    generation.* = generation.* +% 1;
                    if (generation.* == 0) generation.* = 1;
                }
                self.free_indices.append(self.allocator, id.index) catch {};
                return removed;
            }
        }
        return null;
    }

    fn allocateId(self: *HashHandleTable) !foundation.HandleId {
        if (self.free_indices.pop()) |index| {
            const generation = self.generations.get(index) orelse 1;
            return .{ .index = index, .generation = if (generation == 0) 1 else generation };
        }
        var index: u32 = self.next_index;
        if (index < hash_handle_index_base) index = hash_handle_index_base;
        // ファイルhandleのindex空間へ巻き戻らないよう、必ずbase以上に留める。
        while (self.generations.contains(index)) {
            index +%= 1;
            if (index < hash_handle_index_base) index = hash_handle_index_base;
        }
        try self.generations.put(index, 1);
        self.next_index = index +% 1;
        if (self.next_index < hash_handle_index_base) self.next_index = hash_handle_index_base;
        return .{ .index = index, .generation = 1 };
    }
};

pub fn normalize(source: []const u8, output: []u8) ?[]const u8 {
    var length: usize = 0;
    for (source) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) continue;
        if (length == output.len) return null;
        output[length] = std.ascii.toLower(byte);
        length += 1;
    }
    return output[0..length];
}

fn isAny(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}

test "アルゴリズム名はハッシュ値計算と同じ正規化で解決する" {
    try std.testing.expectEqual(Algorithm.sha256, Algorithm.fromName("SHA-256").?);
    try std.testing.expectEqual(Algorithm.sha256, Algorithm.fromName("RSA-SHA256").?);
    try std.testing.expectEqual(Algorithm.sha256, Algorithm.fromName("sha256WithRSAEncryption").?);
    try std.testing.expectEqual(Algorithm.md5, Algorithm.fromName("ssl3-md5").?);
    try std.testing.expectEqual(Algorithm.md5_sha1, Algorithm.fromName("md5-sha1").?);
    try std.testing.expectEqual(Algorithm.sha512_256, Algorithm.fromName("sha512/256").?);
    try std.testing.expectEqual(Algorithm.sha3_512, Algorithm.fromName("id-rsassa-pkcs1-v1_5-with-sha3-512").?);
    try std.testing.expectEqual(Algorithm.ripemd160, Algorithm.fromName("rmd160").?);
    try std.testing.expectEqual(Algorithm.sm3, Algorithm.fromName("sm3").?);
    try std.testing.expect(Algorithm.fromName("crc32") == null);
    try std.testing.expect(Algorithm.fromName("") == null);
    try std.testing.expect(!Algorithm.ripemd160.isIncremental());
    try std.testing.expect(!Algorithm.sm3.isIncremental());
    try std.testing.expect(Algorithm.sha256.isIncremental());
    try std.testing.expectEqual(@as(usize, 32), Algorithm.sha256.digestLength());
    try std.testing.expectEqual(@as(usize, 36), Algorithm.md5_sha1.digestLength());
}

test "標準テストベクタ（空・短文）を逐次計算で得る" {
    const cases = [_]struct { name: []const u8, input: []const u8, expected: []const u8 }{
        .{ .name = "sha256", .input = "", .expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
        .{ .name = "sha256", .input = "abc", .expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
        .{ .name = "sha512", .input = "abc", .expected = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f" },
        .{ .name = "md5", .input = "abc", .expected = "900150983cd24fb0d6963f7d28e17f72" },
        .{ .name = "sha1", .input = "abc", .expected = "a9993e364706816aba3e25717850c26c9cd0d89d" },
    };
    const allocator = std.testing.allocator;
    for (cases) |case| {
        const algorithm = Algorithm.fromName(case.name).?;
        var hasher = Hasher.start(algorithm).?;
        hasher.update(case.input);
        const digest = try hasher.finalize(allocator);
        defer allocator.free(digest);
        var hex: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&hex, "{x}", .{digest}) catch unreachable;
        try std.testing.expectEqualStrings(case.expected, text);
    }
}

test "1 byte刻みと一括供給で同じdigestになる" {
    const allocator = std.testing.allocator;
    const input = "The quick brown fox jumps over the lazy dog" ** 7;
    inline for ([_]Algorithm{ .sha256, .sha512, .md5, .sha3_256, .blake2b512, .md5_sha1 }) |algorithm| {
        var whole = Hasher.start(algorithm).?;
        whole.update(input);
        const whole_digest = try whole.finalize(allocator);
        defer allocator.free(whole_digest);

        var chunked = Hasher.start(algorithm).?;
        for (input) |byte| chunked.update(&.{byte});
        const chunked_digest = try chunked.finalize(allocator);
        defer allocator.free(chunked_digest);

        try std.testing.expectEqualSlices(u8, whole_digest, chunked_digest);
    }
}

test "sha512系・sha3系・shake系も逐次計算できる" {
    const allocator = std.testing.allocator;
    const input = "abcdefghijklmnopqrstuvwxyz0123456789" ** 11;
    const cases = [_]struct { name: []const u8, expected_len: usize }{
        .{ .name = "sha224", .expected_len = 28 },
        .{ .name = "sha384", .expected_len = 48 },
        .{ .name = "sha512-224", .expected_len = 28 },
        .{ .name = "sha512-256", .expected_len = 32 },
        .{ .name = "sha3-224", .expected_len = 28 },
        .{ .name = "sha3-384", .expected_len = 48 },
        .{ .name = "sha3-512", .expected_len = 64 },
        .{ .name = "blake2s256", .expected_len = 32 },
        .{ .name = "shake128", .expected_len = 16 },
        .{ .name = "shake256", .expected_len = 32 },
    };
    for (cases) |case| {
        const algorithm = Algorithm.fromName(case.name).?;
        var chunked = Hasher.start(algorithm).?;
        var start: usize = 0;
        while (start < input.len) : (start += 3) chunked.update(input[start..@min(input.len, start + 3)]);
        const digest = try chunked.finalize(allocator);
        defer allocator.free(digest);
        try std.testing.expectEqual(case.expected_len, digest.len);
    }
}

test "HashHandleTableは完了・破棄後に同じindexを世代を進めて再利用する" {
    var table = HashHandleTable.init(std.testing.allocator);
    defer table.deinit();

    const first = try table.insert(Hasher.start(.sha256).?);
    const second = try table.insert(Hasher.start(.md5).?);
    try std.testing.expect(first.index >= hash_handle_index_base);
    try std.testing.expect(second.index >= hash_handle_index_base);
    try std.testing.expect(first.index != second.index);
    try std.testing.expectEqual(@as(usize, 2), table.len());

    const removed = table.remove(first).?;
    try std.testing.expectEqual(first.index, removed.id.index);
    try std.testing.expect(table.find(first) == null);
    try std.testing.expect(table.remove(first) == null);
    try std.testing.expectEqual(@as(usize, 1), table.len());

    const reused = try table.insert(Hasher.start(.sha512).?);
    try std.testing.expectEqual(first.index, reused.index);
    try std.testing.expectEqual(first.generation +% 1, reused.generation);
    try std.testing.expect(table.find(first) == null);
    try std.testing.expect(table.find(reused) != null);
    try std.testing.expectEqual(@as(usize, 2), table.len());
}

test "startNamedは未知をUnsupported、非逐次をIncrementalUnsupportedにする" {
    var hasher = try startNamed("SHA-256");
    hasher.update("abc");
    const digest = try hasher.finalize(std.testing.allocator);
    defer std.testing.allocator.free(digest);
    try std.testing.expectEqual(@as(usize, 32), digest.len);
    try std.testing.expectError(error.UnsupportedHashAlgorithm, startNamed("crc32"));
    try std.testing.expectError(error.IncrementalHashUnsupported, startNamed("ripemd160"));
    try std.testing.expectError(error.IncrementalHashUnsupported, startNamed("sm3"));
}

test "encoding名はハッシュ値計算と同じ別名を受け付ける" {
    try std.testing.expectEqual(Encoding.raw, Encoding.fromName("raw").?);
    try std.testing.expectEqual(Encoding.hex, Encoding.fromName("HEX").?);
    try std.testing.expectEqual(Encoding.base64, Encoding.fromName("base64").?);
    try std.testing.expectEqual(Encoding.base64url, Encoding.fromName("base64url").?);
    try std.testing.expectEqual(Encoding.latin1, Encoding.fromName("binary").?);
    try std.testing.expectEqual(Encoding.utf8, Encoding.fromName("utf-8").?);
    try std.testing.expect(Encoding.fromName("base32") == null);
}
