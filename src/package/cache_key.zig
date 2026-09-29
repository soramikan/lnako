const std = @import("std");
const lock_model = @import("lock_model.zig");

const Allocator = std.mem.Allocator;

/// Build a deterministic cache key from lock source fields.
pub fn shortKey(allocator: Allocator, prefix: []const u8, parts: []const []const u8) Allocator.Error![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(prefix);
    for (parts) |part| {
        hasher.update(&.{0});
        hasher.update(part);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, hex[0..16] });
}

/// Use a normalized SHA-256 digest when available; otherwise retain the declared
/// digest and artifact URL in the key so digest format changes cannot reuse data.
pub fn artifactKey(allocator: Allocator, prefix: []const u8, declared_hash: []const u8, identity: []const u8) Allocator.Error![]u8 {
    var digest: [32]u8 = undefined;
    if (lock_model.normalizeSha256(declared_hash, &digest)) {
        const hex = std.fmt.bytesToHex(digest, .lower);
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, hex[0..32] });
    }
    return shortKey(allocator, prefix, &.{ declared_hash, identity });
}
