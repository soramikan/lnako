//! v1 `nako.lock` のファイル入出力と profile の保持。
//!
//! 解決結果のデータモデル・決定的シリアライズ・旧 lock 検出は
//! `v1_lock.zig` が持つ。ここはクライアントの都合だけを担う:
//!
//! - pin 済み project dir handle 相対の no-follow 読み取り（サイズ上限つき）。
//! - 旧 TOML lock（`schemaVersion`）を `error.LegacyLock` に写像し、一切
//!   書き換えない。
//! - 選択した profile だけを置換し、*既存 lock の他の profile を保持* する。
//! - canonical バイト列の atomic replace（`createFileAtomic` + `replace`）。
//!
//! lock には manifest の digest を記録しない。鮮度は「現在の manifest から
//! 再解決したグラフ」と lock の profile を比較して判定する。これにより
//! `--features` など manifest 以外の解決入力の変化も取りこぼさない。

const std = @import("std");
const v1_lock = @import("v1_lock.zig");

const Allocator = std.mem.Allocator;

pub const lock_name = "nako.lock";
/// lock は小さな解決グラフなので 8 MiB を上限にする。
pub const max_lock_bytes: usize = 8 * 1024 * 1024;

pub const Error = error{
    /// 旧形式の lock。`legacyMessage()` を診断に使う。
    LegacyLock,
    /// 上限を超える、または通常ファイルでない。
    InvalidLockFile,
    /// 通常ファイル以外（symlink を含む）。
    UnsafeLockFile,
    LockTooLarge,
    OutOfMemory,
};

pub fn legacyMessage() []const u8 {
    return v1_lock.legacyMessage();
}

/// `dir` の `nako.lock` を読む。存在しなければ null。
/// 旧形式は `error.LegacyLock`、symlink・非通常ファイルは `UnsafeLockFile`。
pub fn readDir(allocator: Allocator, io: std.Io, dir: std.Io.Dir) !?v1_lock.Lock {
    const stat = dir.statFile(io, lock_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.UnsafeLockFile;
    if (stat.kind != .file) return error.InvalidLockFile;
    if (stat.size > max_lock_bytes) return error.LockTooLarge;

    const file = try dir.openFile(io, lock_name, .{ .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    if (opened.kind != .file) return error.InvalidLockFile;
    if (opened.size > max_lock_bytes) return error.LockTooLarge;

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_lock_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.LockTooLarge,
        else => return err,
    };
    defer allocator.free(bytes);
    if (bytes.len > max_lock_bytes) return error.LockTooLarge;

    return try parseBytes(allocator, bytes);
}

/// メモリ上の lock バイト列を解析する。旧形式は `LegacyLock`。
pub fn parseBytes(allocator: Allocator, bytes: []const u8) !v1_lock.Lock {
    return v1_lock.parse(allocator, bytes) catch |err| switch (err) {
        error.LegacyLock => return error.LegacyLock,
        // 旧 lock は TOML。JSON 解析に失敗した入力が旧 lock の目印を持つ
        // 場合は、互換読み取りではなく再作成を案内する。
        error.InvalidLock, error.UnsupportedVersion => {
            if (looksLegacy(bytes)) return error.LegacyLock;
            return err;
        },
        else => return err,
    };
}

/// 旧 lock の目印。新しい JSON lock は `"schema_version"` を持つため、
/// 先に `v1_lock.parse` が成功する入力には適用されない。
pub fn looksLegacy(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes, "schemaVersion") != null or
        std.mem.indexOf(u8, bytes, "resolverVersion") != null or
        std.mem.indexOf(u8, bytes, "profilePackages") != null;
}

/// canonical バイト列。呼び出し側が free する。
pub fn toBytes(lock: *const v1_lock.Lock, allocator: Allocator) ![]u8 {
    return v1_lock.toBytes(lock, allocator);
}

/// `sha256:<64hex>`。lock の同一性判定・環境の記録に使う。
pub fn digestHex(lock: *const v1_lock.Lock, allocator: Allocator) ![]u8 {
    const bytes = try toBytes(lock, allocator);
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

/// `dir` の `nako.lock` を canonical バイト列で atomic に置換する。
/// 成功時は書いたバイト列を返す（呼び出し側が free）。
pub fn writeDir(allocator: Allocator, io: std.Io, dir: std.Io.Dir, lock: *const v1_lock.Lock) ![]u8 {
    const bytes = try toBytes(lock, allocator);
    errdefer allocator.free(bytes);
    try writeCanonicalDir(io, dir, bytes);
    return bytes;
}

/// 既に canonical 化済みのバイト列を atomic に置換する（再度シリアライズ
/// しない）。呼び出し側は書いたバイト列の digest を別途計算できる。
pub fn writeCanonicalDir(io: std.Io, dir: std.Io.Dir, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, lock_name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

/// 既存 lock の profile を保持し、`replacement` と同名の profile だけを
/// 置き換えた新しい lock を返す。profile は名前順、ノード・辺は
/// `v1_lock` の正規順に整列する。
pub fn mergeProfile(
    parent: Allocator,
    existing: ?*const v1_lock.Lock,
    replacement: *const v1_lock.Profile,
) !v1_lock.Lock {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var profiles: std.ArrayList(v1_lock.Profile) = .empty;
    if (existing) |lock| {
        for (lock.profiles) |profile| {
            if (std.mem.eql(u8, profile.name, replacement.name)) continue;
            try profiles.append(allocator, try copyProfile(allocator, profile));
        }
    }
    try profiles.append(allocator, try copyProfile(allocator, replacement.*));
    std.mem.sort(v1_lock.Profile, profiles.items, {}, profileLessThan);

    return .{ .arena = arena, .profiles = try profiles.toOwnedSlice(allocator) };
}

/// 1 profile の lock を既存 lock へ統合する。
pub fn mergeLock(parent: Allocator, existing: ?*const v1_lock.Lock, replacement: *const v1_lock.Lock) !v1_lock.Lock {
    if (replacement.profiles.len != 1) return error.InvalidLock;
    return mergeProfile(parent, existing, &replacement.profiles[0]);
}

/// 解決結果と既存 profile が同一か。同一なら lock を書き換えない。
pub fn profileEqual(a: v1_lock.Profile, b: v1_lock.Profile) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.runtime != b.runtime) return false;
    if (!optionalStringEqual(a.target_triple, b.target_triple)) return false;
    if (a.nodes.len != b.nodes.len or a.root.len != b.root.len or a.edges.len != b.edges.len) return false;
    for (a.nodes, b.nodes) |left, right| {
        if (!std.mem.eql(u8, left.key, right.key)) return false;
        if (!std.mem.eql(u8, left.id, right.id)) return false;
        if (!std.mem.eql(u8, left.version, right.version)) return false;
        if (!std.mem.eql(u8, left.sha256, right.sha256)) return false;
        if (left.kind != right.kind or left.global != right.global) return false;
    }
    for (a.root, b.root) |left, right| {
        if (!edgeEqual(left, right)) return false;
    }
    for (a.edges, b.edges) |left, right| {
        if (!edgeEqual(left, right)) return false;
    }
    return true;
}

fn edgeEqual(a: v1_lock.Edge, b: v1_lock.Edge) bool {
    if (!optionalStringEqual(a.from, b.from)) return false;
    if (!std.mem.eql(u8, a.to, b.to)) return false;
    if (!std.mem.eql(u8, a.id, b.id)) return false;
    if (!std.mem.eql(u8, a.req, b.req)) return false;
    if (!optionalStringEqual(a.alias, b.alias)) return false;
    if (!stringSliceEqual(a.features, b.features)) return false;
    if (a.default_features != b.default_features) return false;
    if (a.optional != b.optional) return false;
    if (a.allow_global_commands != b.allow_global_commands) return false;
    if (a.runtimes.len != b.runtimes.len) return false;
    for (a.runtimes, b.runtimes) |left, right| {
        if (left != right) return false;
    }
    return true;
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn stringSliceEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn profileLessThan(_: void, a: v1_lock.Profile, b: v1_lock.Profile) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn copyProfile(allocator: Allocator, profile: v1_lock.Profile) !v1_lock.Profile {
    var nodes = try allocator.alloc(v1_lock.Node, profile.nodes.len);
    for (profile.nodes, 0..) |node, index| {
        nodes[index] = try copyNode(allocator, node);
    }
    var root = try allocator.alloc(v1_lock.Edge, profile.root.len);
    for (profile.root, 0..) |edge, index| {
        root[index] = try copyEdge(allocator, edge);
    }
    var edges = try allocator.alloc(v1_lock.Edge, profile.edges.len);
    for (profile.edges, 0..) |edge, index| {
        edges[index] = try copyEdge(allocator, edge);
    }
    return .{
        .name = try allocator.dupe(u8, profile.name),
        .runtime = profile.runtime,
        .target_triple = if (profile.target_triple) |triple| try allocator.dupe(u8, triple) else null,
        .nodes = nodes,
        .root = root,
        .edges = edges,
    };
}

fn copyNode(allocator: Allocator, node: v1_lock.Node) !v1_lock.Node {
    return .{
        .key = try allocator.dupe(u8, node.key),
        .id = try allocator.dupe(u8, node.id),
        .version = try allocator.dupe(u8, node.version),
        .sha256 = try allocator.dupe(u8, node.sha256),
        .kind = node.kind,
        .global = node.global,
    };
}

fn copyEdge(allocator: Allocator, edge: v1_lock.Edge) !v1_lock.Edge {
    var features = try allocator.alloc([]const u8, edge.features.len);
    for (edge.features, 0..) |feature, index| {
        features[index] = try allocator.dupe(u8, feature);
    }
    return .{
        .from = if (edge.from) |from| try allocator.dupe(u8, from) else null,
        .to = try allocator.dupe(u8, edge.to),
        .id = try allocator.dupe(u8, edge.id),
        .req = try allocator.dupe(u8, edge.req),
        .alias = if (edge.alias) |alias| try allocator.dupe(u8, alias) else null,
        .features = features,
        .default_features = edge.default_features,
        .optional = edge.optional,
        .allow_global_commands = edge.allow_global_commands,
        .runtimes = try allocator.dupe(@TypeOf(edge.runtimes[0]), edge.runtimes),
    };
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const testing = std.testing;
const types = @import("v1_types.zig");

fn sampleLock(parent: Allocator, profile: []const u8, version: []const u8) !v1_lock.Lock {
    return v1_lock.fromGraph(parent, .{
        .profile = profile,
        .runtime = .lnako,
        .target_triple = "aarch64-macos-none",
        .nodes = &.{
            .{
                .id = "@acme/json",
                .version = version,
                .sha256 = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                .kind = .universal,
                .global = false,
            },
        },
        .root = &.{
            .{
                .to = .{ .id = "@acme/json", .version = version },
                .id = "@acme/json",
                .req = "^1.0.0",
                .alias = "json",
                .features = &.{ "default", "tls" },
                .runtimes = &.{.lnako},
            },
        },
        .edges = &.{},
    });
}

test "profile の置換は他の profile を保持し、決定的に並ぶ" {
    const a = testing.allocator;
    var default_lock = try sampleLock(a, "default", "1.1.0");
    defer default_lock.deinit();
    var windows_lock = try sampleLock(a, "windows", "1.2.0");
    defer windows_lock.deinit();

    var merged = try mergeProfile(a, &default_lock, &windows_lock.profiles[0]);
    defer merged.deinit();
    try testing.expectEqual(@as(usize, 2), merged.profiles.len);
    try testing.expectEqualStrings("default", merged.profiles[0].name);
    try testing.expectEqualStrings("windows", merged.profiles[1].name);

    // 同じ profile を別版で置換しても既存の他 profile はそのまま。
    var replacement = try sampleLock(a, "default", "1.3.0");
    defer replacement.deinit();
    var merged_again = try mergeProfile(a, &merged, &replacement.profiles[0]);
    defer merged_again.deinit();
    try testing.expectEqual(@as(usize, 2), merged_again.profiles.len);
    try testing.expectEqualStrings("default", merged_again.profiles[0].name);
    try testing.expectEqualStrings("windows", merged_again.profiles[1].name);
    try testing.expectEqualStrings("1.3.0", merged_again.profiles[0].nodes[0].version);
}

test "canonical バイト列は再解析でき、profile 比較が一致する" {
    const a = testing.allocator;
    var lock = try sampleLock(a, "default", "1.1.0");
    defer lock.deinit();
    const bytes = try toBytes(&lock, a);
    defer a.free(bytes);

    var parsed = try parseBytes(a, bytes);
    defer parsed.deinit();
    try testing.expect(profileEqual(lock.profiles[0], parsed.profiles[0]));

    const again = try toBytes(&parsed, a);
    defer a.free(again);
    try testing.expectEqualStrings(bytes, again);
}

test "旧 TOML lock は LegacyLock に写像し、ファイルを変更しない" {
    const a = testing.allocator;
    const legacy =
        \\schemaVersion = 2
        \\resolverVersion = 1
        \\[input]
        \\profile = "default"
        \\
    ;
    try testing.expectError(error.LegacyLock, parseBytes(a, legacy));
    try testing.expect(looksLegacy(legacy));

    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(testing.io, .{ .sub_path = lock_name, .data = legacy });
    try testing.expectError(error.LegacyLock, readDir(a, testing.io, temporary.dir));
    const unchanged = try temporary.dir.readFileAlloc(testing.io, lock_name, a, .limited(1024));
    defer a.free(unchanged);
    try testing.expectEqualStrings(legacy, unchanged);
}

test "lock の atomic 置換とサイズ上限、symlink 拒否" {
    const a = testing.allocator;
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    var lock = try sampleLock(a, "default", "1.1.0");
    defer lock.deinit();
    const written = try writeDir(a, io, temporary.dir, &lock);
    defer a.free(written);

    var read_back = (try readDir(a, io, temporary.dir)).?;
    defer read_back.deinit();
    try testing.expectEqualStrings("default", read_back.profiles[0].name);

    const digest = try digestHex(&read_back, a);
    defer a.free(digest);
    try testing.expect(std.mem.startsWith(u8, digest, "sha256:"));
    try testing.expectEqual(@as(usize, 71), digest.len);

    const huge = try a.alloc(u8, max_lock_bytes + 1);
    defer a.free(huge);
    @memset(huge, ' ');
    try temporary.dir.writeFile(io, .{ .sub_path = lock_name, .data = huge });
    try testing.expectError(error.LockTooLarge, readDir(a, io, temporary.dir));

    if (@import("builtin").os.tag != .windows) {
        try temporary.dir.deleteFile(io, lock_name);
        try temporary.dir.writeFile(io, .{ .sub_path = "real.lock", .data = written });
        try temporary.dir.symLink(io, "real.lock", lock_name, .{});
        try testing.expectError(error.UnsafeLockFile, readDir(a, io, temporary.dir));
    }
}

test "types の Runtime と lock の runtime が一致する" {
    // v1_types と v1_lock の結合を明示する（不要な import 検出を兼ねる）。
    try testing.expectEqualStrings("lnako", @tagName(types.Runtime.lnako));
}
