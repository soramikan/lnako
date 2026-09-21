//! `NAKO-PKG/FILES.toml` のモデル・シリアライズ・解析。
//!
//! FILES.toml は `.npkg` ペイロードの完全な索引であり、`path` →
//! `{ sha256, size }` の対応をバイト順ソートで保持する。`NAKO-PKG/` 配下の
//! メタデータ entry は索引に含めない。解析時は schemaVersion・path の正規性・
//! digest 形式・重複を検証する。
//!
//! レイアウト・検証要件は `docs/package-system/SPECIFICATION.md` §6.3。

const std = @import("std");
const toml = @import("toml.zig");
const toml_write = @import("toml_write.zig");
const diag = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;

/// FILES.toml の schema version。`SCHEMA_VERSIONS.md` §7 と対応する。
pub const schema_version: u32 = 1;

/// `.npkg` 内で予約されるメタデータ領域。ペイロードはこの下を使えない。
pub const metadata_prefix = "NAKO-PKG/";
pub const metadata_entry = "NAKO-PKG/METADATA.toml";
pub const files_entry = "NAKO-PKG/FILES.toml";
pub const commands_entry = "NAKO-PKG/commands.json";

/// FILES.toml の1項目。`sha256` は32バイトの生ダイジェスト。
/// 文字列スライスは構築側または `document` のアリーナが所有する。
pub const FileEntry = struct {
    path: []const u8,
    sha256: [32]u8,
    size: u64,
};

/// `path` がメタデータ領域 `NAKO-PKG/` 配下か。
pub fn isMetadataPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, metadata_prefix) or std.mem.eql(u8, path, "NAKO-PKG");
}

/// §6.1 の規範 path か。posix `/` 区切りで、`..`/`.`/空成分・`\`・
/// 制御文字・先頭 `/`・末尾 `/` を含まない。
pub fn isCanonicalPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[path.len - 1] == '/') return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
        for (component) |byte| {
            if (byte < 0x20 or byte == 0x7f or byte == '\\') return false;
        }
    }
    return true;
}

/// 32バイトダイジェストを小文字 hex へ書き出す。
pub fn sha256Hex(digest: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

/// `sha256:<64 hex>` を32バイトへデコードする。不正形式は null。
pub fn decodeSha256Hex(text: []const u8) ?[32]u8 {
    if (text.len != "sha256:".len + 64) return null;
    if (!std.mem.startsWith(u8, text, "sha256:")) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text["sha256:".len..]) catch return null;
    return out;
}

fn entryLessThan(_: void, a: FileEntry, b: FileEntry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// FILES.toml を決定的に書き出す。`entries` はソート写を取るため
/// 呼出し側の順序は問わない。同一入力からは常に同一バイト列になる。
pub fn emit(allocator: Allocator, entries: []const FileEntry, writer: *std.Io.Writer) !void {
    const sorted = try allocator.dupe(FileEntry, entries);
    defer allocator.free(sorted);
    std.mem.sort(FileEntry, sorted, {}, entryLessThan);

    try toml_write.writeIntegerField(writer, "schemaVersion", schema_version);
    try writer.writeByte('\n');
    for (sorted) |entry| {
        try toml_write.writeArraySectionHeader(writer, "files");
        try toml_write.writeStringField(writer, "path", entry.path);
        var digest: [7 + 64]u8 = undefined;
        @memcpy(digest[0..7], "sha256:");
        @memcpy(digest[7..], &sha256Hex(entry.sha256));
        try toml_write.writeStringField(writer, "sha256", &digest);
        // `size` は u64。TOML整数（i64）を超える巨大値もそのまま書き出す。
        try toml_write.writeKey(writer, "size");
        try writer.print(" = {d}\n", .{entry.size});
        try writer.writeByte('\n');
    }
}

/// 解析済み FILES.toml。全メモリは `document` のアリーナが所有する。
pub const Files = struct {
    document: toml.Document,
    entries: []FileEntry,

    pub fn deinit(self: *Files) void {
        self.document.deinit();
        self.* = undefined;
    }
};

const Validator = struct {
    arena: Allocator,
    diagnostics: *diag.List,
    files: *Files,

    fn report(self: *Validator, code: []const u8, path: []const u8, position: diag.Position, comptime format: []const u8, args: anytype) !void {
        try self.diagnostics.addFmt(code, .err, path, position, format, args);
    }

    /// `path` は `files[i]` 形式の診断用フィールドパス。
    fn requiredString(self: *Validator, table: *const std.StringHashMapUnmanaged(toml.Value), name: []const u8, path: []const u8) !?[]const u8 {
        const value = table.getPtr(name) orelse {
            try self.report(diag.E019_REQUIRED_FIELD_MISSING, path, .{}, "missing required field \"{s}\"", .{name});
            return null;
        };
        return self.expectString(value, name, path);
    }

    fn expectString(self: *Validator, value: *const toml.Value, name: []const u8, path: []const u8) !?[]const u8 {
        if (value.asString()) |text| return text;
        const field_path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, name });
        try self.report(diag.E023_INVALID_TYPE, field_path, value.position, "expected string \"{s}\"", .{name});
        return null;
    }

    fn requiredInteger(self: *Validator, table: *const std.StringHashMapUnmanaged(toml.Value), name: []const u8, path: []const u8) !?u64 {
        const value = table.getPtr(name) orelse {
            try self.report(diag.E019_REQUIRED_FIELD_MISSING, path, .{}, "missing required field \"{s}\"", .{name});
            return null;
        };
        const field_path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, name });
        return switch (value.kind) {
            .integer => |number| blk: {
                if (number < 0) {
                    try self.report(diag.E023_INVALID_TYPE, field_path, value.position, "expected non-negative integer \"{s}\"", .{name});
                    break :blk null;
                }
                break :blk @as(?u64, @intCast(number));
            },
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, field_path, value.position, "expected integer \"{s}\"", .{name});
                break :blk null;
            },
        };
    }

    fn rejectUnknown(self: *Validator, table: *const std.StringHashMapUnmanaged(toml.Value), allowed: []const []const u8, path: []const u8) !void {
        var iterator = table.iterator();
        while (iterator.next()) |item| {
            const key = item.key_ptr.*;
            var found = false;
            for (allowed) |name| {
                if (std.mem.eql(u8, key, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const field_path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, key });
                try self.report(diag.E022_UNKNOWN_FIELD, field_path, item.value_ptr.position, "unknown field \"{s}\"", .{key});
            }
        }
    }

    fn validateEntry(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), index: usize) !?FileEntry {
        const base = try std.fmt.allocPrint(self.arena, "files[{d}]", .{index});
        try self.rejectUnknown(table, &.{ "path", "sha256", "size" }, base);

        const path = try self.requiredString(table, "path", base);
        if (path) |text| {
            if (!isCanonicalPath(text) or isMetadataPath(text)) {
                try self.report(diag.E040_NPKG_NONCANONICAL_PATH, base, table.getPtr("path").?.position, "non-canonical payload path \"{s}\"", .{text});
            }
        }

        var sha256: ?[32]u8 = null;
        if (try self.requiredString(table, "sha256", base)) |text| {
            if (decodeSha256Hex(text)) |digest| {
                sha256 = digest;
            } else {
                try self.report(diag.E029_INVALID_VALUE, base, table.getPtr("sha256").?.position, "invalid sha256 \"{s}\" (expected \"sha256:<64 hex>\")", .{text});
            }
        }

        const size = try self.requiredInteger(table, "size", base);
        if (path == null or sha256 == null or size == null) return null;
        return FileEntry{ .path = path.?, .sha256 = sha256.?, .size = size.? };
    }

    fn validateRoot(self: *Validator) !void {
        const root = &self.files.document.root;
        try self.rejectUnknown(root, &.{ "schemaVersion", "files" }, "FILES.toml");

        const version_value = root.getPtr("schemaVersion") orelse {
            try self.report(diag.E019_REQUIRED_FIELD_MISSING, "schemaVersion", .{}, "missing required field \"schemaVersion\"", .{});
            return;
        };
        switch (version_value.kind) {
            .integer => |number| {
                if (number <= 0 or number > std.math.maxInt(u32)) {
                    try self.report(diag.E023_INVALID_TYPE, "schemaVersion", version_value.position, "expected positive integer schemaVersion", .{});
                } else if (number != schema_version) {
                    try self.report(diag.E035_UNKNOWN_NPKG_SCHEMA, "schemaVersion", version_value.position, "unsupported FILES.toml schemaVersion {d} (expected {d})", .{ number, schema_version });
                }
            },
            else => {
                try self.report(diag.E023_INVALID_TYPE, "schemaVersion", version_value.position, "expected integer schemaVersion", .{});
            },
        }

        // `files` の省略は空索引として受理する（emit は空索引を省略する）。
        const files_value = root.getPtr("files") orelse {
            self.files.entries = &.{};
            return;
        };
        const array = files_value.asArray() orelse {
            try self.report(diag.E023_INVALID_TYPE, "files", files_value.position, "expected array of tables \"files\"", .{});
            return;
        };
        var entries: std.ArrayList(FileEntry) = .empty;
        try entries.ensureTotalCapacity(self.arena, array.items.len);
        for (array.items, 0..) |item, index| {
            const table = item.asTable() orelse {
                const path = try std.fmt.allocPrint(self.arena, "files[{d}]", .{index});
                try self.report(diag.E023_INVALID_TYPE, path, item.position, "expected table entry", .{});
                continue;
            };
            if (try self.validateEntry(table, index)) |entry| entries.appendAssumeCapacity(entry);
        }
        self.files.entries = entries.items;
        try self.sortAndCheckDuplicates();
    }

    fn sortAndCheckDuplicates(self: *Validator) !void {
        std.mem.sort(FileEntry, self.files.entries, {}, entryLessThan);
        for (self.files.entries, 0..) |entry, index| {
            if (index == 0) continue;
            if (std.mem.eql(u8, entry.path, self.files.entries[index - 1].path)) {
                try self.report(diag.E038_NPKG_DUPLICATE_ENTRY, entry.path, .{}, "duplicate files entry \"{s}\"", .{entry.path});
            }
        }
    }
};

/// FILES.toml を解析して検証する。TOML 構文エラーは E020/E021、スキーマ
/// 違反は E019/E022/E023/E029/E035/E038/E040 を diagnostics へ記録する。
/// 検証エラーがあれば `error.InvalidFiles`。
pub fn parse(allocator: Allocator, source: []const u8, diagnostics: *diag.List) !Files {
    var files = switch (try toml.parse(allocator, source)) {
        .ok => |document| Files{ .document = document, .entries = &.{} },
        .err => |syntax| {
            const code = if (std.mem.indexOf(u8, syntax.message, "UTF-8") != null) diag.E021_INVALID_UTF8 else diag.E020_INVALID_TOML;
            try diagnostics.add(code, .err, syntax.message, "FILES.toml", syntax.position);
            return error.InvalidFiles;
        },
    };
    errdefer files.document.deinit();
    const arena = files.document.arena.allocator();

    var validator = Validator{ .arena = arena, .diagnostics = diagnostics, .files = &files };
    const prior_errors = diagnostics.errorCount();
    try validator.validateRoot();
    if (diagnostics.errorCount() > prior_errors) return error.InvalidFiles;
    return files;
}
