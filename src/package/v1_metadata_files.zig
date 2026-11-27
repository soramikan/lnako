//! `NAKO-PKG/FILES.json` のモデル・決定的シリアライズ・厳格な解析。
//!
//! 仕様 §3.4。`files` は `FILES.json` 自身を除く全通常ファイルと 1 対 1 で
//! 対応し、パスの UTF-8 バイト順に並ぶ。サイズと SHA-256 は実バイト列と
//! 照合する（照合はアーカイブ検証が行う）。

const std = @import("std");
const json = @import("v1_metadata_json.zig");
const types = @import("v1_types.zig");

const Allocator = std.mem.Allocator;

pub const schema_version: u32 = 1;
pub const files_path = "NAKO-PKG/FILES.json";

pub const Error = error{
    OutOfMemory,
    InvalidJson,
    InvalidFiles,
    InvalidSchemaVersion,
    MissingField,
    InvalidFieldType,
    InvalidPath,
    InvalidHash,
    DuplicatePath,
    NotSorted,
};

pub const Entry = struct {
    path: []const u8,
    size: u64,
    sha256: [32]u8,
};

pub const Model = struct {
    files: []const Entry = &.{},

    /// `parse` が通常アロケータへ割り当てたモデルを解放する。arena 管理下の
    /// モデルでは呼ばなくてよい。
    pub fn deinit(self: *Model, allocator: Allocator) void {
        for (self.files) |entry| allocator.free(entry.path);
        allocator.free(self.files);
        self.* = undefined;
    }

    pub fn find(self: *const Model, path: []const u8) ?Entry {
        for (self.files) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }
};

fn entryLessThan(_: void, left: Entry, right: Entry) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

pub fn hash(data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return digest;
}

pub fn entryFor(path: []const u8, data: []const u8) Entry {
    return .{ .path = path, .size = data.len, .sha256 = hash(data) };
}

/// 決定的な FILES.json を書き出す。`entries` は昇順へ並べ替えた写しを使う。
pub fn emit(allocator: Allocator, entries: []const Entry) ![]u8 {
    const sorted = try allocator.dupe(Entry, entries);
    defer allocator.free(sorted);
    std.mem.sort(Entry, sorted, {}, entryLessThan);

    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("{\"schema_version\":1,\"files\":[");
    for (sorted, 0..) |entry, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try std.json.Stringify.value(entry.path, .{}, writer);
        try writer.print(",\"size\":{d},\"sha256\":\"sha256:{s}\"}}", .{
            entry.size,
            std.fmt.bytesToHex(entry.sha256, .lower),
        });
    }
    try writer.writeAll("]}\n");
    return output.toOwnedSlice();
}

/// JSON を解析して所有権を持つモデルを返す。パス文字列は `allocator` が
/// 所有するため、JSON の一時 arena を解放した後も使用できる。
pub fn parse(allocator: Allocator, bytes: []const u8) !Model {
    var parsed = json.parse(allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return error.InvalidJson,
    };
    defer parsed.deinit();
    return validate(allocator, parsed.value);
}

/// 解析済み JSON からモデルを作る。配列は `allocator` が所有し、文字列は
/// JSON の arena を借用する。
pub fn validate(allocator: Allocator, value: std.json.Value) !Model {
    const root = json.object(value) catch return error.InvalidFiles;
    const version = json.integerField(root, "schema_version") catch return error.InvalidFiles;
    if (version != schema_version) return error.InvalidSchemaVersion;
    const files_value = json.field(root, "files") catch return error.InvalidFiles;
    const files = json.array(files_value) catch return error.InvalidFiles;
    const entries = try allocator.alloc(Entry, files.items.len);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| allocator.free(entry.path);
        allocator.free(entries);
    }
    for (files.items, 0..) |item, index| {
        const object = json.object(item) catch return error.InvalidFiles;
        const path = json.stringField(object, "path") catch return error.InvalidFiles;
        const size = json.integerField(object, "size") catch return error.InvalidFiles;
        if (size < 0) return error.InvalidFiles;
        const text = json.stringField(object, "sha256") catch return error.InvalidFiles;
        if (!types.validPath(path)) return error.InvalidPath;
        if (std.mem.eql(u8, path, files_path)) return error.InvalidPath;
        const digest = decodeHash(text) orelse return error.InvalidHash;
        entries[index] = .{
            .path = try allocator.dupe(u8, path),
            .size = @intCast(size),
            .sha256 = digest,
        };
        initialized = index + 1;
        if (index > 0) {
            const order = std.mem.order(u8, entries[index - 1].path, path);
            if (order == .eq) return error.DuplicatePath;
            if (order == .gt) return error.NotSorted;
        }
    }
    return .{ .files = entries };
}

pub fn decodeHash(text: []const u8) ?[32]u8 {
    if (text.len != 71 or !std.mem.eql(u8, text[0..7], "sha256:")) return null;
    var digest: [32]u8 = undefined;
    for (text[7..], 0..) |byte, index| {
        const value: u8 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            else => return null,
        };
        if (index % 2 == 0) {
            digest[index / 2] = value << 4;
        } else {
            digest[index / 2] |= value;
        }
    }
    return digest;
}
