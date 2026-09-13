const std = @import("std");

/// 診断コード。`docs/package-system/SPECIFICATION.md` 第8節と対応する。
pub const E001_UNKNOWN_MANIFEST_SCHEMA = "E001_UNKNOWN_MANIFEST_SCHEMA";
pub const E003_CONFLICTING_VERSIONS = "E003_CONFLICTING_VERSIONS";
pub const E004_DEPENDENCY_CYCLE = "E004_DEPENDENCY_CYCLE";
pub const E006_JS_IN_NORMAL_MODE = "E006_JS_IN_NORMAL_MODE";
pub const E011_DUPLICATE_EXPORT = "E011_DUPLICATE_EXPORT";
pub const E012_ALIAS_COLLISION = "E012_ALIAS_COLLISION";
pub const E014_INVALID_PROFILE = "E014_INVALID_PROFILE";
pub const E019_REQUIRED_FIELD_MISSING = "E019_REQUIRED_FIELD_MISSING";
pub const E020_INVALID_TOML = "E020_INVALID_TOML";
pub const E021_INVALID_UTF8 = "E021_INVALID_UTF8";
pub const E022_UNKNOWN_FIELD = "E022_UNKNOWN_FIELD";
pub const E023_INVALID_TYPE = "E023_INVALID_TYPE";
pub const E024_INVALID_SEMVER = "E024_INVALID_SEMVER";
pub const E025_INVALID_RANGE = "E025_INVALID_RANGE";
pub const E026_INVALID_MARKER = "E026_INVALID_MARKER";
pub const E027_FEATURE_CYCLE = "E027_FEATURE_CYCLE";
pub const E028_UNKNOWN_FEATURE = "E028_UNKNOWN_FEATURE";
pub const E029_INVALID_VALUE = "E029_INVALID_VALUE";
pub const E030_UNKNOWN_PROFILE = "E030_UNKNOWN_PROFILE";

pub const Severity = enum {
    err,
    warning,
};

/// `nako.toml` 内の位置。`line`/`column` は1始まり、`offset` は0始まり。
/// `column`/`offset` は文字数ではなくバイト単位で数える。
pub const Position = struct {
    line: usize = 0,
    column: usize = 0,
    offset: usize = 0,
};

pub const Diagnostic = struct {
    code: []const u8,
    severity: Severity,
    /// Listが所有する文字列。
    message: []const u8,
    /// `dependencies.pkg.foo.version` のようなフィールドパス。Listが所有する。
    path: []const u8,
    position: Position = .{},
};

pub const List = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) List {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *List) void {
        for (self.items.items) |item| {
            self.allocator.free(item.message);
            self.allocator.free(item.path);
        }
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// `message`/`path` は本Listが複製して所有する。
    pub fn add(self: *List, code: []const u8, severity: Severity, message: []const u8, path: []const u8, position: Position) !void {
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.items.append(self.allocator, .{
            .code = code,
            .severity = severity,
            .message = owned_message,
            .path = owned_path,
            .position = position,
        });
    }

    pub fn addFmt(self: *List, code: []const u8, severity: Severity, path: []const u8, position: Position, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(message);
        try self.add(code, severity, message, path, position);
    }

    pub fn hasErrors(self: *const List) bool {
        for (self.items.items) |item| {
            if (item.severity == .err) return true;
        }
        return false;
    }

    pub fn errorCount(self: *const List) usize {
        var count: usize = 0;
        for (self.items.items) |item| {
            if (item.severity == .err) count += 1;
        }
        return count;
    }

    pub fn find(self: *const List, code: []const u8) ?*const Diagnostic {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.code, code)) return item;
        }
        return null;
    }

    /// `path:line:column: severity code: message` 形式で書き出す。
    pub fn render(self: *const List, writer: *std.Io.Writer, source_name: []const u8) !void {
        for (self.items.items) |item| {
            const severity_text = switch (item.severity) {
                .err => "error",
                .warning => "warning",
            };
            if (item.position.line > 0) {
                try writer.print("{s}:{d}:{d}: {s} {s}: {s}", .{ source_name, item.position.line, item.position.column, severity_text, item.code, item.message });
            } else {
                try writer.print("{s}: {s} {s}: {s}", .{ source_name, severity_text, item.code, item.message });
            }
            if (item.path.len > 0) try writer.print(" [{s}]", .{item.path});
            try writer.writeByte('\n');
        }
    }
};

test "診断を追加して位置とコードを保持する" {
    var list = List.init(std.testing.allocator);
    defer list.deinit();

    try list.add(E019_REQUIRED_FIELD_MISSING, .err, "missing required field \"package\"", "nako.toml", .{ .line = 1, .column = 1, .offset = 0 });
    try list.addFmt(E014_INVALID_PROFILE, .err, "profiles.default", .{ .line = 8, .column = 5, .offset = 120 }, "profile \"default\" has invalid os: {s}", .{"freebsd"});

    try std.testing.expect(list.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), list.errorCount());
    const found = list.find(E014_INVALID_PROFILE).?;
    try std.testing.expectEqual(@as(usize, 8), found.position.line);
    try std.testing.expect(std.mem.indexOf(u8, found.message, "freebsd") != null);
}
