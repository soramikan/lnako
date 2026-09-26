const std = @import("std");
const module_graph = @import("../semantic/module_graph.zig");
const token_mod = @import("../frontend/token.zig");

const magic = "LNAKOQJSBUNDLE1!";
const trailer_length = @sizeOf(u64) + magic.len;
const format_version: u32 = 3;
const minimum_supported_format_version: u32 = 2;
const maximum_payload_size: u64 = 512 * 1024 * 1024;

pub const SourceFile = struct {
    path: []const u8,
    source: []const u8,
};

pub const PackageImport = struct {
    importer: []const u8,
    specifier: []const u8,
    path: []const u8,
    canonical_id: []const u8,
    namespace: []const u8,
};

fn packMode(mode: token_mod.Mode) u8 {
    var packed_mode: u8 = 0;
    if (mode.dncl) packed_mode |= 1;
    if (mode.dncl2) packed_mode |= 2;
    if (mode.indent) packed_mode |= 4;
    return packed_mode;
}

fn unpackMode(packed_mode: u8) token_mod.Mode {
    return .{
        .dncl = packed_mode & 1 != 0,
        .dncl2 = packed_mode & 2 != 0,
        .indent = packed_mode & 4 != 0,
    };
}

pub const Package = struct {
    allocator: std.mem.Allocator,
    backing: []u8,
    entry_path: []const u8,
    files: []SourceFile,
    package_imports: []PackageImport = &.{},
    /// 生成時に `--dncl` 等で強制された構文モード。起動時の再コンパイルへ復元する。
    forced_mode: token_mod.Mode = .{},

    pub fn deinit(self: *Package) void {
        self.allocator.free(self.package_imports);
        self.allocator.free(self.files);
        self.allocator.free(self.backing);
        self.* = undefined;
    }

    pub fn sourceProvider(self: *Package) module_graph.SourceProvider {
        return .{ .context = self, .readFn = readSource };
    }

    pub fn packageResolver(self: *Package) module_graph.PackageResolver {
        return .{ .context = self, .resolveFn = resolvePackageImport };
    }

    fn resolvePackageImport(context: *anyopaque, allocator: std.mem.Allocator, importer: []const u8, specifier: []const u8) !module_graph.ResolvedPackageImport {
        const self: *Package = @ptrCast(@alignCast(context));
        for (self.package_imports) |item| {
            if (!std.mem.eql(u8, item.importer, importer) or !std.mem.eql(u8, item.specifier, specifier)) continue;
            const path = try allocator.dupe(u8, item.path);
            errdefer allocator.free(path);
            const canonical_id = try allocator.dupe(u8, item.canonical_id);
            errdefer allocator.free(canonical_id);
            const namespace = try allocator.dupe(u8, item.namespace);
            return .{ .path = path, .canonical_id = canonical_id, .namespace = namespace };
        }
        return error.PackageNotFound;
    }

    fn readSource(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *Package = @ptrCast(@alignCast(context));
        for (self.files) |file| if (std.mem.eql(u8, file.path, path)) return allocator.dupe(u8, file.source);
        return error.FileNotFound;
    }
};

pub fn createExecutable(allocator: std.mem.Allocator, executable: []const u8, entry_path: []const u8, files: []const SourceFile, forced_mode: token_mod.Mode) ![]u8 {
    return createExecutableWithImports(allocator, executable, entry_path, files, forced_mode, &.{});
}

pub fn createExecutableWithImports(
    allocator: std.mem.Allocator,
    executable: []const u8,
    entry_path: []const u8,
    files: []const SourceFile,
    forced_mode: token_mod.Mode,
    package_imports: []const PackageImport,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, executable);
    const payload_start = output.items.len;
    try appendInteger(&output, allocator, u32, format_version);
    try appendInteger(&output, allocator, u8, packMode(forced_mode));
    if (files.len > std.math.maxInt(u32)) return error.TooManyEmbeddedSources;
    try appendInteger(&output, allocator, u32, @intCast(files.len));
    try appendBytes(&output, allocator, entry_path);
    for (files) |file| {
        try appendBytes(&output, allocator, file.path);
        try appendBytes(&output, allocator, file.source);
    }
    if (package_imports.len > std.math.maxInt(u32)) return error.TooManyEmbeddedPackageImports;
    try appendInteger(&output, allocator, u32, @intCast(package_imports.len));
    for (package_imports) |item| {
        try appendBytes(&output, allocator, item.importer);
        try appendBytes(&output, allocator, item.specifier);
        try appendBytes(&output, allocator, item.path);
        try appendBytes(&output, allocator, item.canonical_id);
        try appendBytes(&output, allocator, item.namespace);
    }
    try appendInteger(&output, allocator, u64, @intCast(output.items.len - payload_start));
    try output.appendSlice(allocator, magic);
    return output.toOwnedSlice(allocator);
}

pub fn readExecutable(allocator: std.mem.Allocator, io: std.Io, executable_path: []const u8) !?Package {
    const file = try std.Io.Dir.cwd().openFile(io, executable_path, .{});
    defer file.close(io);
    const length = try file.length(io);
    if (length < trailer_length) return null;
    var trailer: [trailer_length]u8 = undefined;
    if (try file.readPositionalAll(io, &trailer, length - trailer.len) != trailer.len) return error.TruncatedEmbeddedTrailer;
    if (!std.mem.eql(u8, trailer[@sizeOf(u64)..], magic)) return null;
    const payload_length = std.mem.readInt(u64, trailer[0..@sizeOf(u64)], .little);
    if (payload_length > maximum_payload_size or payload_length > length - trailer.len) return error.InvalidEmbeddedPayloadLength;
    const payload = try allocator.alloc(u8, @intCast(payload_length));
    errdefer allocator.free(payload);
    if (try file.readPositionalAll(io, payload, length - trailer.len - payload_length) != payload.len) return error.TruncatedEmbeddedPayload;
    return @as(?Package, try parsePayload(allocator, payload));
}

fn parsePayload(allocator: std.mem.Allocator, payload: []u8) !Package {
    var cursor: usize = 0;
    const version = try readInteger(u32, payload, &cursor);
    if (version < minimum_supported_format_version or version > format_version) return error.UnsupportedEmbeddedFormat;
    const forced_mode = unpackMode(try readInteger(u8, payload, &cursor));
    const file_count = try readInteger(u32, payload, &cursor);
    const entry_path = try readBytes(payload, &cursor);
    const files = try allocator.alloc(SourceFile, file_count);
    errdefer allocator.free(files);
    for (files) |*file| {
        file.path = try readBytes(payload, &cursor);
        file.source = try readBytes(payload, &cursor);
    }
    const package_imports = if (version >= 3) blk: {
        const count = try readInteger(u32, payload, &cursor);
        const imports = try allocator.alloc(PackageImport, count);
        errdefer allocator.free(imports);
        for (imports) |*item| {
            item.importer = try readBytes(payload, &cursor);
            item.specifier = try readBytes(payload, &cursor);
            item.path = try readBytes(payload, &cursor);
            item.canonical_id = try readBytes(payload, &cursor);
            item.namespace = try readBytes(payload, &cursor);
        }
        break :blk imports;
    } else try allocator.alloc(PackageImport, 0);
    errdefer allocator.free(package_imports);
    if (cursor != payload.len) return error.InvalidEmbeddedPayload;
    return .{ .allocator = allocator, .backing = payload, .entry_path = entry_path, .files = files, .package_imports = package_imports, .forced_mode = forced_mode };
}

fn appendBytes(output: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try appendInteger(output, allocator, u64, @intCast(bytes.len));
    try output.appendSlice(allocator, bytes);
}

fn appendInteger(output: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try output.appendSlice(allocator, &bytes);
}

fn readInteger(comptime T: type, payload: []const u8, cursor: *usize) !T {
    if (cursor.* > payload.len or payload.len - cursor.* < @sizeOf(T)) return error.TruncatedEmbeddedPayload;
    const result = std.mem.readInt(T, payload[cursor.*..][0..@sizeOf(T)], .little);
    cursor.* += @sizeOf(T);
    return result;
}

fn readBytes(payload: []const u8, cursor: *usize) ![]const u8 {
    const length = try readInteger(u64, payload, cursor);
    if (length > std.math.maxInt(usize) or cursor.* > payload.len or length > payload.len - cursor.*) return error.TruncatedEmbeddedPayload;
    const start = cursor.*;
    cursor.* += @intCast(length);
    return payload[start..cursor.*];
}

test "埋め込みpackage import resolver metadataを復元する" {
    const package_imports = [_]PackageImport{.{
        .importer = "/src/main.nako3",
        .specifier = "パッケージ:math",
        .path = "/packages/math/index.nako3",
        .canonical_id = "pkg:math-id/main",
        .namespace = "math",
    }};
    const executable = try createExecutableWithImports(std.testing.allocator, "EXE", "/src/main.nako3", &.{
        .{ .path = "/src/main.nako3", .source = "!「パッケージ:math」を取り込む\n" },
        .{ .path = "/packages/math/index.nako3", .source = "値=5\n" },
    }, .{}, &package_imports);
    defer std.testing.allocator.free(executable);
    const payload_length = std.mem.readInt(u64, executable[executable.len - trailer_length ..][0..@sizeOf(u64)], .little);
    const payload_start = executable.len - trailer_length - @as(usize, @intCast(payload_length));
    const backing = try std.testing.allocator.dupe(u8, executable[payload_start .. executable.len - trailer_length]);
    var package = try parsePayload(std.testing.allocator, backing);
    defer package.deinit();
    try std.testing.expectEqual(@as(usize, 1), package.package_imports.len);
    const resolved = try package.packageResolver().resolve(std.testing.allocator, "/src/main.nako3", "パッケージ:math");
    defer std.testing.allocator.free(resolved.path);
    defer std.testing.allocator.free(resolved.canonical_id);
    defer std.testing.allocator.free(resolved.namespace);
    try std.testing.expectEqualStrings("/packages/math/index.nako3", resolved.path);
    try std.testing.expectEqualStrings("pkg:math-id/main", resolved.canonical_id);
    try std.testing.expectEqualStrings("math", resolved.namespace);
}

test "QuickJS埋め込み実行形式を往復する" {
    const executable = try createExecutable(std.testing.allocator, "EXE", "/src/main.nako3", &.{
        .{ .path = "/src/main.nako3", .source = "!『p.mjs』を取り込む\n" },
        .{ .path = "/src/p.mjs", .source = "export default {}" },
    }, .{ .dncl2 = true });
    defer std.testing.allocator.free(executable);
    const payload_length = std.mem.readInt(u64, executable[executable.len - trailer_length ..][0..@sizeOf(u64)], .little);
    const payload_start = executable.len - trailer_length - @as(usize, @intCast(payload_length));
    const backing = try std.testing.allocator.dupe(u8, executable[payload_start .. executable.len - trailer_length]);
    var package = try parsePayload(std.testing.allocator, backing);
    defer package.deinit();
    try std.testing.expectEqualStrings("/src/main.nako3", package.entry_path);
    try std.testing.expectEqual(@as(usize, 2), package.files.len);
    try std.testing.expectEqualStrings("export default {}", package.files[1].source);
    try std.testing.expect(package.forced_mode.dncl2);
    try std.testing.expect(!package.forced_mode.dncl);
    try std.testing.expect(!package.forced_mode.indent);
}
