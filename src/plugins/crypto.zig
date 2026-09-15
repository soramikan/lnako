const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const low_level_hash = @import("../runtime/low_level_hash.zig");
const common = @import("system/common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const Context = struct {
    context: *anyopaque,
    randomBytesFn: *const fn (context: *anyopaque, output: []u8) anyerror!void,

    fn randomBytes(self: Context, output: []u8) !void {
        try self.randomBytesFn(self.context, output);
    }
};

pub const hash_names = [_][]const u8{
    "RSA-MD5",
    "RSA-RIPEMD160",
    "RSA-SHA1",
    "RSA-SHA1-2",
    "RSA-SHA224",
    "RSA-SHA256",
    "RSA-SHA3-224",
    "RSA-SHA3-256",
    "RSA-SHA3-384",
    "RSA-SHA3-512",
    "RSA-SHA384",
    "RSA-SHA512",
    "RSA-SHA512/224",
    "RSA-SHA512/256",
    "RSA-SM3",
    "blake2b512",
    "blake2s256",
    "id-rsassa-pkcs1-v1_5-with-sha3-224",
    "id-rsassa-pkcs1-v1_5-with-sha3-256",
    "id-rsassa-pkcs1-v1_5-with-sha3-384",
    "id-rsassa-pkcs1-v1_5-with-sha3-512",
    "md5",
    "md5-sha1",
    "md5WithRSAEncryption",
    "ripemd",
    "ripemd160",
    "ripemd160WithRSA",
    "rmd160",
    "sha1",
    "sha1WithRSAEncryption",
    "sha224",
    "sha224WithRSAEncryption",
    "sha256",
    "sha256WithRSAEncryption",
    "sha3-224",
    "sha3-256",
    "sha3-384",
    "sha3-512",
    "sha384",
    "sha384WithRSAEncryption",
    "sha512",
    "sha512-224",
    "sha512-224WithRSAEncryption",
    "sha512-256",
    "sha512-256WithRSAEncryption",
    "sha512WithRSAEncryption",
    "shake128",
    "shake256",
    "sm3",
    "sm3WithRSAEncryption",
    "ssl3-md5",
    "ssl3-sha1",
};

pub fn call(runtime: *Runtime, context: ?Context, name: []const u8, arguments: []const Value) !?Value {
    if (std.mem.eql(u8, name, "ハッシュ関数一覧取得")) {
        var result = try runtime.createArray();
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        for (hash_names) |hash_name| _ = try result.array.push(try runtime.stringUtf8(hash_name));
        return result;
    }
    if (std.mem.eql(u8, name, "ハッシュ値計算")) return try calculateHash(runtime, arguments);
    if (std.mem.eql(u8, name, "ランダムUUID生成")) {
        const actual = context orelse return error.SecureRandomUnavailable;
        var bytes: [16]u8 = undefined;
        try actual.randomBytes(&bytes);
        const uuid = formatUuid(bytes);
        return try runtime.stringUtf8(&uuid);
    }
    if (std.mem.eql(u8, name, "ランダム配列生成")) {
        const actual = context orelse return error.SecureRandomUnavailable;
        const count_number = try runtime.valueToNumber(common.argument(arguments, 0));
        if (std.math.isInf(count_number) or count_number < 0 or count_number > 65_536) return error.InvalidRandomByteCount;
        const count: usize = if (std.math.isNan(count_number)) 0 else @intFromFloat(@trunc(count_number));
        const bytes = try runtime.allocator().alloc(u8, count);
        defer runtime.allocator().free(bytes);
        try actual.randomBytes(bytes);
        return try runtime.createUint8Array(bytes);
    }
    return null;
}

pub fn formatUuid(raw: [16]u8) [36]u8 {
    var bytes = raw;
    bytes[6] = bytes[6] & 0x0f | 0x40;
    bytes[8] = bytes[8] & 0x3f | 0x80;
    var uuid: [36]u8 = undefined;
    const alphabet = "0123456789abcdef";
    var source_index: usize = 0;
    var output_index: usize = 0;
    while (source_index < bytes.len) : (source_index += 1) {
        if (output_index == 8 or output_index == 13 or output_index == 18 or output_index == 23) {
            uuid[output_index] = '-';
            output_index += 1;
        }
        uuid[output_index] = alphabet[bytes[source_index] >> 4];
        uuid[output_index + 1] = alphabet[bytes[source_index] & 0x0f];
        output_index += 2;
    }
    return uuid;
}

fn calculateHash(runtime: *Runtime, arguments: []const Value) !Value {
    const input = try valueBytes(runtime, common.argument(arguments, 0));
    defer runtime.allocator().free(input);
    const algorithm = try valueUtf8(runtime, common.argument(arguments, 1));
    defer runtime.allocator().free(algorithm);
    const digest = try calculateDigest(runtime.allocator(), input, algorithm);
    defer runtime.allocator().free(digest);

    const encoding_value = common.argument(arguments, 2);
    if (encoding_value == .undefined or encoding_value == .null_value) return runtime.createBytes(digest);
    const encoding = try valueUtf8(runtime, encoding_value);
    defer runtime.allocator().free(encoding);
    if (std.ascii.eqlIgnoreCase(encoding, "hex")) {
        const result = try runtime.allocator().alloc(u8, digest.len * 2);
        defer runtime.allocator().free(result);
        _ = std.fmt.bufPrint(result, "{x}", .{digest}) catch unreachable;
        return runtime.stringUtf8(result);
    }
    if (std.ascii.eqlIgnoreCase(encoding, "base64") or std.ascii.eqlIgnoreCase(encoding, "base64url")) {
        const result = try runtime.allocator().alloc(u8, std.base64.standard.Encoder.calcSize(digest.len));
        defer runtime.allocator().free(result);
        _ = std.base64.standard.Encoder.encode(result, digest);
        if (std.ascii.eqlIgnoreCase(encoding, "base64")) return runtime.stringUtf8(result);
        for (result) |*byte| byte.* = switch (byte.*) {
            '+' => '-',
            '/' => '_',
            else => byte.*,
        };
        var length = result.len;
        while (length > 0 and result[length - 1] == '=') length -= 1;
        return runtime.stringUtf8(result[0..length]);
    }
    if (std.ascii.eqlIgnoreCase(encoding, "latin1") or std.ascii.eqlIgnoreCase(encoding, "binary")) {
        const units = try runtime.allocator().alloc(u16, digest.len);
        defer runtime.allocator().free(units);
        for (digest, 0..) |byte, index| units[index] = byte;
        return runtime.stringCodeUnits(units);
    }
    if (std.ascii.eqlIgnoreCase(encoding, "utf8") or std.ascii.eqlIgnoreCase(encoding, "utf-8")) return runtime.stringUtf8Lossy(digest);
    return error.UnsupportedDigestEncoding;
}

/// Calculate a Node-compatible digest without depending on the Interpreter
/// value model.  AOT uses this same implementation so every supported alias
/// and digest length has one source of truth.
pub fn calculateDigest(allocator: std.mem.Allocator, input: []const u8, algorithm: []const u8) ![]u8 {
    const resolved = low_level_hash.Algorithm.fromName(algorithm) orelse return error.UnsupportedHashAlgorithm;
    var digest: std.ArrayList(u8) = .empty;
    errdefer digest.deinit(allocator);
    switch (resolved) {
        .md5 => try appendHash(std.crypto.hash.Md5, allocator, &digest, input),
        .md5_sha1 => {
            try appendHash(std.crypto.hash.Md5, allocator, &digest, input);
            try appendHash(std.crypto.hash.Sha1, allocator, &digest, input);
        },
        .sha1 => try appendHash(std.crypto.hash.Sha1, allocator, &digest, input),
        .sha224 => try appendHash(std.crypto.hash.sha2.Sha224, allocator, &digest, input),
        .sha256 => try appendHash(std.crypto.hash.sha2.Sha256, allocator, &digest, input),
        .sha384 => try appendHash(std.crypto.hash.sha2.Sha384, allocator, &digest, input),
        .sha512 => try appendHash(std.crypto.hash.sha2.Sha512, allocator, &digest, input),
        .sha512_224 => try appendHash(std.crypto.hash.sha2.Sha512_224, allocator, &digest, input),
        .sha512_256 => try appendHash(std.crypto.hash.sha2.Sha512_256, allocator, &digest, input),
        .sha3_224 => try appendHash(std.crypto.hash.sha3.Sha3_224, allocator, &digest, input),
        .sha3_256 => try appendHash(std.crypto.hash.sha3.Sha3_256, allocator, &digest, input),
        .sha3_384 => try appendHash(std.crypto.hash.sha3.Sha3_384, allocator, &digest, input),
        .sha3_512 => try appendHash(std.crypto.hash.sha3.Sha3_512, allocator, &digest, input),
        .blake2b512 => try appendHash(std.crypto.hash.blake2.Blake2b512, allocator, &digest, input),
        .blake2s256 => try appendHash(std.crypto.hash.blake2.Blake2s256, allocator, &digest, input),
        .shake128 => {
            const output = try digest.addManyAsSlice(allocator, 16);
            std.crypto.hash.sha3.Shake128.hash(input, output, .{});
        },
        .shake256 => {
            const output = try digest.addManyAsSlice(allocator, 32);
            std.crypto.hash.sha3.Shake256.hash(input, output, .{});
        },
        .ripemd160 => {
            const output = try digest.addManyAsSlice(allocator, 20);
            ripemd160(input, output[0..20]);
        },
        .sm3 => {
            const output = try digest.addManyAsSlice(allocator, 32);
            sm3(input, output[0..32]);
        },
    }
    return digest.toOwnedSlice(allocator);
}

fn appendHash(comptime Hash: type, allocator: std.mem.Allocator, output: *std.ArrayList(u8), input: []const u8) !void {
    var digest: [Hash.digest_length]u8 = undefined;
    Hash.hash(input, &digest, .{});
    try output.appendSlice(allocator, &digest);
}

fn valueBytes(runtime: *Runtime, value: Value) ![]u8 {
    if (value == .bytes) return runtime.allocator().dupe(u8, value.bytes.bytes);
    return valueUtf8(runtime, value);
}

fn valueUtf8(runtime: *Runtime, value: Value) ![]u8 {
    const text = try runtime.valueToString(value);
    return text.string.toUtf8Lossy(runtime.allocator());
}

fn ripemd160(input: []const u8, output: *[20]u8) void {
    var state = [5]u32{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 };
    var offset: usize = 0;
    while (offset + 64 <= input.len) : (offset += 64) ripemdBlock(&state, input[offset..][0..64]);
    var tail: [128]u8 = @splat(0);
    const remainder = input[offset..];
    @memcpy(tail[0..remainder.len], remainder);
    tail[remainder.len] = 0x80;
    const padded_length: usize = if (remainder.len < 56) 64 else 128;
    writeU64(@ptrCast(&tail[padded_length - 8]), @as(u64, input.len) *% 8, .little);
    ripemdBlock(&state, tail[0..64]);
    if (padded_length == 128) ripemdBlock(&state, tail[64..128]);
    for (state, 0..) |word, index| writeU32(output[index * 4 ..][0..4], word, .little);
}

fn ripemdBlock(state: *[5]u32, block: *const [64]u8) void {
    const r_left = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8, 3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12, 1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2, 4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13 };
    const r_right = [_]u8{ 5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12, 6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2, 15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13, 8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14, 12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11 };
    const s_left = [_]u5{ 11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8, 7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12, 11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5, 11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12, 9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6 };
    const s_right = [_]u5{ 8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6, 9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11, 9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5, 15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8, 8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11 };
    var words: [16]u32 = undefined;
    for (&words, 0..) |*word, index| word.* = readU32(block[index * 4 ..][0..4], .little);
    var left = state.*;
    var right = state.*;
    for (0..80) |round| {
        const previous_left = left;
        const left_temp = std.math.rotl(u32, previous_left[0] +% ripemdFunction(round, previous_left[1], previous_left[2], previous_left[3]) +% words[r_left[round]] +% ripemdConstant(round), s_left[round]) +% previous_left[4];
        left = .{ previous_left[4], left_temp, previous_left[1], std.math.rotl(u32, previous_left[2], 10), previous_left[3] };
        const previous_right = right;
        const right_temp = std.math.rotl(u32, previous_right[0] +% ripemdFunction(79 - round, previous_right[1], previous_right[2], previous_right[3]) +% words[r_right[round]] +% ripemdRightConstant(round), s_right[round]) +% previous_right[4];
        right = .{ previous_right[4], right_temp, previous_right[1], std.math.rotl(u32, previous_right[2], 10), previous_right[3] };
    }
    const first = state[1] +% left[2] +% right[3];
    state[1] = state[2] +% left[3] +% right[4];
    state[2] = state[3] +% left[4] +% right[0];
    state[3] = state[4] +% left[0] +% right[1];
    state[4] = state[0] +% left[1] +% right[2];
    state[0] = first;
}

fn ripemdFunction(round: usize, x: u32, y: u32, z: u32) u32 {
    return switch (round / 16) {
        0 => x ^ y ^ z,
        1 => (x & y) | (~x & z),
        2 => (x | ~y) ^ z,
        3 => (x & z) | (y & ~z),
        else => x ^ (y | ~z),
    };
}

fn ripemdConstant(round: usize) u32 {
    return switch (round / 16) {
        0 => 0x00000000,
        1 => 0x5a827999,
        2 => 0x6ed9eba1,
        3 => 0x8f1bbcdc,
        else => 0xa953fd4e,
    };
}

fn ripemdRightConstant(round: usize) u32 {
    return switch (round / 16) {
        0 => 0x50a28be6,
        1 => 0x5c4dd124,
        2 => 0x6d703ef3,
        3 => 0x7a6d76e9,
        else => 0x00000000,
    };
}

fn sm3(input: []const u8, output: *[32]u8) void {
    var state = [8]u32{ 0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e };
    var offset: usize = 0;
    while (offset + 64 <= input.len) : (offset += 64) sm3Block(&state, input[offset..][0..64]);
    var tail: [128]u8 = @splat(0);
    const remainder = input[offset..];
    @memcpy(tail[0..remainder.len], remainder);
    tail[remainder.len] = 0x80;
    const padded_length: usize = if (remainder.len < 56) 64 else 128;
    writeU64(@ptrCast(&tail[padded_length - 8]), @as(u64, input.len) *% 8, .big);
    sm3Block(&state, tail[0..64]);
    if (padded_length == 128) sm3Block(&state, tail[64..128]);
    for (state, 0..) |word, index| writeU32(output[index * 4 ..][0..4], word, .big);
}

fn sm3Block(state: *[8]u32, block: *const [64]u8) void {
    var words: [68]u32 = undefined;
    var expanded: [64]u32 = undefined;
    for (words[0..16], 0..) |*word, index| word.* = readU32(block[index * 4 ..][0..4], .big);
    for (16..68) |index| {
        const mixed = words[index - 16] ^ words[index - 9] ^ std.math.rotl(u32, words[index - 3], 15);
        words[index] = mixed ^ std.math.rotl(u32, mixed, 15) ^ std.math.rotl(u32, mixed, 23) ^ std.math.rotl(u32, words[index - 13], 7) ^ words[index - 6];
    }
    for (0..64) |index| expanded[index] = words[index] ^ words[index + 4];
    var work = state.*;
    for (0..64) |round| {
        const previous = work;
        const a12 = std.math.rotl(u32, previous[0], 12);
        const constant: u32 = if (round < 16) 0x79cc4519 else 0x7a879d8a;
        const first = std.math.rotl(u32, a12 +% previous[4] +% std.math.rotl(u32, constant, @as(u5, @intCast(round % 32))), 7);
        const second = first ^ a12;
        const tt1 = (if (round < 16) previous[0] ^ previous[1] ^ previous[2] else (previous[0] & previous[1]) | (previous[0] & previous[2]) | (previous[1] & previous[2])) +% previous[3] +% second +% expanded[round];
        const tt2 = (if (round < 16) previous[4] ^ previous[5] ^ previous[6] else (previous[4] & previous[5]) | (~previous[4] & previous[6])) +% previous[7] +% first +% words[round];
        work = .{ tt1, previous[0], std.math.rotl(u32, previous[1], 9), previous[2], sm3Permutation(tt2), previous[4], std.math.rotl(u32, previous[5], 19), previous[6] };
    }
    for (state, work) |*word, value| word.* ^= value;
}

fn sm3Permutation(value: u32) u32 {
    return value ^ std.math.rotl(u32, value, 9) ^ std.math.rotl(u32, value, 17);
}

fn readU32(bytes: *const [4]u8, endian: std.builtin.Endian) u32 {
    return std.mem.readInt(u32, bytes, endian);
}

fn writeU32(bytes: *[4]u8, value: u32, endian: std.builtin.Endian) void {
    std.mem.writeInt(u32, bytes, value, endian);
}

fn writeU64(bytes: *[8]u8, value: u64, endian: std.builtin.Endian) void {
    std.mem.writeInt(u64, bytes, value, endian);
}

test "Node互換ハッシュの標準・RIPEMD・SM3を計算する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const source = try runtime.stringUtf8("abc");
    const hex = try runtime.stringUtf8("hex");
    const cases = [_]struct { name: []const u8, expected: []const u8 }{
        .{ .name = "md5", .expected = "900150983cd24fb0d6963f7d28e17f72" },
        .{ .name = "sha256", .expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
        .{ .name = "ripemd160", .expected = "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc" },
        .{ .name = "sm3", .expected = "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0" },
    };
    for (cases) |case| {
        const name = try runtime.stringUtf8(case.name);
        const result = (try call(&runtime, null, "ハッシュ値計算", &.{ source, name, hex })).?;
        const utf8 = try result.string.toUtf8Lossy(std.testing.allocator);
        defer std.testing.allocator.free(utf8);
        try std.testing.expectEqualStrings(case.expected, utf8);
    }
}

test "UUIDのversionとvariantビットを固定する" {
    const TestRandom = struct {
        fn fill(_: *anyopaque, output: []u8) !void {
            for (output, 0..) |*byte, index| byte.* = @intCast(index);
        }
    };
    var marker: u8 = 0;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const result = (try call(&runtime, .{ .context = &marker, .randomBytesFn = TestRandom.fill }, "ランダムUUID生成", &.{})).?;
    const utf8 = try result.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("00010203-0405-4607-8809-0a0b0c0d0e0f", utf8);

    const random = (try call(&runtime, .{ .context = &marker, .randomBytesFn = TestRandom.fill }, "ランダム配列生成", &.{.{ .number = 4 }})).?;
    try std.testing.expectEqual(value_mod.ByteKind.uint8_array, random.bytes.kind);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, random.bytes.bytes);
}

test "ハッシュ値計算の全別名は逐次ハッシュと同じアルゴリズムへ解決する" {
    const allocator = std.testing.allocator;
    const input = "The quick brown fox jumps over the lazy dog";
    var incremental_count: usize = 0;
    var one_shot_only_count: usize = 0;
    for (hash_names) |name| {
        const algorithm = low_level_hash.Algorithm.fromName(name) orelse {
            std.debug.print("未知のハッシュ別名: {s}\n", .{name});
            return error.UnsupportedHashAlgorithm;
        };
        const one_shot = try calculateDigest(allocator, input, name);
        defer allocator.free(one_shot);
        if (!algorithm.isIncremental()) {
            one_shot_only_count += 1;
            try std.testing.expectEqual(algorithm.digestLength(), one_shot.len);
            try std.testing.expectError(error.IncrementalHashUnsupported, low_level_hash.startNamed(name));
            continue;
        }
        incremental_count += 1;
        var hasher = try low_level_hash.startNamed(name);
        var offset: usize = 0;
        while (offset < input.len) : (offset += 5) hasher.update(input[offset..@min(input.len, offset + 5)]);
        const streamed = try hasher.finalize(allocator);
        defer allocator.free(streamed);
        try std.testing.expectEqualSlices(u8, one_shot, streamed);
    }
    try std.testing.expect(incremental_count > 0);
    try std.testing.expect(one_shot_only_count > 0);
}
