const std = @import("std");

/// `nako.toml` 系ドキュメント（METADATA.toml・FILES.toml）を生成するための
/// 最小限のTOMLシリアライザ。基本文字列・整数・真偽値・配列・inline tableを
/// 対象とし、日時・浮動小数点・literal stringは対象外（emit側が生成しない）。
/// 出力は決定的であり、呼出し側がキー順を決める。
/// TOML基本文字列として `"..."` をエスケープして書き出す。
pub fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

/// bare key（`[A-Za-z0-9_-]+`）ならそのまま、不能ならquoted keyで書き出す。
/// パス等の `/` や `.` を含むキーは必ずquoteされる。
pub fn writeKey(writer: *std.Io.Writer, key: []const u8) !void {
    if (isBareKey(key)) {
        try writer.writeAll(key);
    } else {
        try writeString(writer, key);
    }
}

fn isBareKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |byte| {
        const ok = (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or byte == '_' or byte == '-';
        if (!ok) return false;
    }
    return true;
}

/// `key = "text"` 行を書き出す。
pub fn writeStringField(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try writeKey(writer, key);
    try writer.writeAll(" = ");
    try writeString(writer, value);
    try writer.writeByte('\n');
}

/// `key = N` 行を書き出す。
pub fn writeIntegerField(writer: *std.Io.Writer, key: []const u8, value: i64) !void {
    try writeKey(writer, key);
    try writer.print(" = {d}\n", .{value});
}

/// `key = true` 行を書き出す。
pub fn writeBoolField(writer: *std.Io.Writer, key: []const u8, value: bool) !void {
    try writeKey(writer, key);
    try writer.writeAll(if (value) " = true\n" else " = false\n");
}

/// `key = ["a", "b"]` 行を書き出す。
pub fn writeStringArrayField(writer: *std.Io.Writer, key: []const u8, items: []const []const u8) !void {
    try writeKey(writer, key);
    try writer.writeAll(" = [");
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        try writeString(writer, item);
    }
    try writer.writeAll("]\n");
}

/// `[section]` ヘッダ行を書き出す。
pub fn writeSectionHeader(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.writeByte('[');
    try writer.writeAll(name);
    try writer.writeAll("]\n");
}

/// `[[section]]` array-of-tablesヘッダ行を書き出す。
pub fn writeArraySectionHeader(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.writeAll("[[");
    try writer.writeAll(name);
    try writer.writeAll("]]\n");
}

/// inline table の `{ ` 開始と ` }` 終了は呼出し側が `writeAll` で書き、
/// 内部の `k = v` は `writeInlineStringField` 等を使う。
/// `first` は先頭要素かどうかで、カンマの有無を決める。
pub fn writeInlineStringField(writer: *std.Io.Writer, first: bool, key: []const u8, value: []const u8) !void {
    if (!first) try writer.writeAll(", ");
    try writeKey(writer, key);
    try writer.writeAll(" = ");
    try writeString(writer, value);
}

pub fn writeInlineIntegerField(writer: *std.Io.Writer, first: bool, key: []const u8, value: i64) !void {
    if (!first) try writer.writeAll(", ");
    try writeKey(writer, key);
    try writer.print(" = {d}", .{value});
}

pub fn writeInlineBoolField(writer: *std.Io.Writer, first: bool, key: []const u8, value: bool) !void {
    if (!first) try writer.writeAll(", ");
    try writeKey(writer, key);
    try writer.writeAll(if (value) " = true" else " = false");
}

pub fn writeInlineStringArrayField(writer: *std.Io.Writer, first: bool, key: []const u8, items: []const []const u8) !void {
    if (!first) try writer.writeAll(", ");
    try writeKey(writer, key);
    try writer.writeAll(" = [");
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        try writeString(writer, item);
    }
    try writer.writeByte(']');
}

test "文字列とキーをエスケープして書き出す" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    const writer = &buffer.writer;

    try writeString(writer, "abc\"\\\n日本語");
    try std.testing.expectEqualStrings("\"abc\\\"\\\\\\n日本語\"", buffer.written());

    buffer.clearRetainingCapacity();
    try writeKey(writer, "src/index.nako3");
    try std.testing.expectEqualStrings("\"src/index.nako3\"", buffer.written());

    buffer.clearRetainingCapacity();
    try writeKey(writer, "schema-version");
    try std.testing.expectEqualStrings("schema-version", buffer.written());
}

test "フィールド行とセクションヘッダを書き出す" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    const writer = &buffer.writer;

    try writeIntegerField(writer, "schemaVersion", 1);
    try writeBoolField(writer, "mutable", false);
    try writeStringArrayField(writer, "runtimes", &.{ "lnako", "cnako" });
    try writeSectionHeader(writer, "package");
    try writeStringField(writer, "name", "sqlite");
    try writeArraySectionHeader(writer, "exports");
    try writer.writeAll("path = { ");
    try writeInlineStringField(writer, true, "sha256", "sha256:ab");
    try writeInlineIntegerField(writer, false, "size", 12);
    try writer.writeAll(" }\n");
    try std.testing.expectEqualStrings(
        \\schemaVersion = 1
        \\mutable = false
        \\runtimes = ["lnako", "cnako"]
        \\[package]
        \\name = "sqlite"
        \\[[exports]]
        \\path = { sha256 = "sha256:ab", size = 12 }
        \\
    , buffer.written());
}
