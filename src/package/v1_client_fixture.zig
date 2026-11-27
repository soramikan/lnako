//! ローカル固定 fixture の取得 transport（実ネットワークなし）。
//!
//! v1 クライアントの取得・検証 pipeline は、レジストリへ接続せずに
//! 「URL → 固定レスポンス」を返す transport を注入して試験する。この
//! モジュールはその transport のローカル実装で、ディレクトリツリー上の
//! ファイルを URL に写像する。
//!
//! ツリー規約:
//! - `GET <origin>/index/v1/...` は `<root>/index/v1/...` を最優先で読む
//!   （§4 の index ツリーをそのまま置ける）。
//! - それ以外は `<root>/urls/<host>/<path>` を読む。非既定ポートは
//!   `<root>/urls/<host>/_port-<port>/<path>`。
//! - `<path>.status` があれば、1 行目を HTTP status、3xx では 2 行目を
//!   `Location` として使う。これで redirect（D-07）や固定エラーを表せる。
//!
//! 安全規則:
//! - URL は HTTPS のみ。userinfo・query・fragment を拒否する。
//! - ルートと途中のディレクトリ・最終ファイルはすべて no-follow で開き、
//!   symlink と通常ファイル以外を拒否する。
//! - パス成分は `.`/`..`・空・`\`・制御文字・`:` を拒否する。
//! - index と artifact で別々のサイズ上限を適用し、stat と実読取りの両方で
//!   検査する。

const std = @import("std");

const Allocator = std.mem.Allocator;

/// fixture 応答。`body` と `location` は `get` に渡した allocator が所有する。
pub const Response = struct {
    status: u16 = 200,
    location: ?[]const u8 = null,
    body: []const u8 = "",
};

pub const Error = error{
    InvalidUrl,
    InsecureScheme,
    FixtureNotFound,
    SymlinkEncountered,
    NotRegularFile,
    TooLarge,
    InvalidStatusFile,
    OutOfMemory,
};

pub const Limits = struct {
    /// `index/v1/**` の 1 ファイル上限。
    max_index_bytes: usize = 16 * 1024 * 1024,
    /// artifact など index 以外の 1 ファイル上限（§3.2 の圧縮後 25 MiB）。
    max_artifact_bytes: usize = 25 * 1024 * 1024,
    /// `.status` ファイルの上限。
    max_status_bytes: usize = 4096,
};

/// ルートを pin した fixture transport。呼び出し中は root handle が有効。
pub const Source = struct {
    io: std.Io,
    root: std.Io.Dir,
    limits: Limits = .{},

    /// `root_abs` を no-follow で開く。ルート自体が symlink なら拒否する。
    pub fn open(io: std.Io, root_abs: []const u8, limits: Limits) !Source {
        const stat = std.Io.Dir.cwd().statFile(io, root_abs, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.FixtureNotFound,
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkEncountered;
        if (stat.kind != .directory) return error.NotRegularFile;
        const dir = try std.Io.Dir.cwd().openDir(io, root_abs, .{
            .iterate = false,
            .follow_symlinks = false,
        });
        return .{ .io = io, .root = dir, .limits = limits };
    }

    pub fn deinit(self: *Source) void {
        self.root.close(self.io);
        self.* = undefined;
    }

    /// URL に対応する固定応答を返す。見つからなければ `FixtureNotFound`。
    pub fn get(self: *Source, allocator: Allocator, url: []const u8) !Response {
        var parsed = try parseHttpsUrl(allocator, url);
        defer parsed.deinit(allocator);

        const index_like = std.mem.startsWith(u8, parsed.path, "index/v1/");
        const max_bytes = if (index_like) self.limits.max_index_bytes else self.limits.max_artifact_bytes;

        // 1) §4 index ツリーの慣例。2) URL ツリー。
        var candidates: std.ArrayList([]u8) = .empty;
        defer {
            for (candidates.items) |item| allocator.free(item);
            candidates.deinit(allocator);
        }
        if (index_like) {
            try candidates.append(allocator, try allocator.dupe(u8, parsed.path));
        }
        if (parsed.port) |port| {
            try candidates.append(allocator, try std.fmt.allocPrint(allocator, "urls/{s}/_port-{d}/{s}", .{ parsed.host, port, parsed.path }));
        } else {
            try candidates.append(allocator, try std.fmt.allocPrint(allocator, "urls/{s}/{s}", .{ parsed.host, parsed.path }));
        }

        for (candidates.items) |rel| {
            const maybe_file = self.openFileRel(rel) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            const file = maybe_file orelse continue;
            defer file.close(self.io);

            const status_rel = try std.fmt.allocPrint(allocator, "{s}.status", .{rel});
            defer allocator.free(status_rel);
            const status_bytes = self.readOptional(allocator, status_rel, self.limits.max_status_bytes) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            var status: u16 = 200;
            var location: ?[]const u8 = null;
            if (status_bytes) |bytes| {
                defer allocator.free(bytes);
                const parsed_status = try parseStatusFile(allocator, bytes);
                status = parsed_status.status;
                location = parsed_status.location;
            }

            if (status >= 300 and status <= 399) {
                if (location == null) return error.InvalidStatusFile;
                return .{ .status = status, .location = location.?, .body = "" };
            }
            const body = try readOpenFileAlloc(self.io, allocator, file, max_bytes);
            return .{ .status = status, .location = location, .body = body };
        }
        return error.FixtureNotFound;
    }

    /// 取得 callback 用の薄いアダプタ。`Source` の寿命は呼び出し側が保つ。
    pub fn fetchCallback(context: ?*anyopaque, allocator: Allocator, url: []const u8) anyerror!Response {
        const self: *Source = @ptrCast(@alignCast(context orelse return error.FixtureNotFound));
        return self.get(allocator, url);
    }

    fn readOptional(self: *Source, allocator: Allocator, rel: []const u8, max_bytes: usize) !?[]u8 {
        const file = (try self.openFileRel(rel)) orelse return error.FileNotFound;
        defer file.close(self.io);
        return try readOpenFileAlloc(self.io, allocator, file, max_bytes);
    }

    /// 相対 path を 1 成分ずつ no-follow でたどり、最終ファイルを開く。
    /// 不存在は `error.FileNotFound`、最終が通常ファイルでなければ
    /// `NotRegularFile`、symlink は `SymlinkEncountered`。
    fn openFileRel(self: *Source, rel: []const u8) !?std.Io.File {
        var current = self.root;
        var owns = false;
        defer if (owns) current.close(self.io);

        var parts = std.mem.splitScalar(u8, rel, '/');
        while (parts.next()) |part| {
            if (!validComponent(part)) return error.InvalidUrl;
            if (parts.peek() == null) {
                const file = current.openFile(self.io, part, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => return null,
                    else => return err,
                };
                const stat = file.stat(self.io) catch |err| {
                    file.close(self.io);
                    return err;
                };
                if (stat.kind == .sym_link) {
                    file.close(self.io);
                    return error.SymlinkEncountered;
                }
                if (stat.kind != .file) {
                    file.close(self.io);
                    return error.NotRegularFile;
                }
                return file;
            }
            const next = current.openDir(self.io, part, .{
                .iterate = false,
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.FileNotFound => return null,
                // no-follow の openDir は symlink 先が dir でも NotDir を
                // 返す環境があるため、entry を no-follow stat して区別する。
                error.NotDir, error.SymLinkLoop => {
                    const entry = current.statFile(self.io, part, .{ .follow_symlinks = false }) catch |stat_err| switch (stat_err) {
                        error.FileNotFound => return null,
                        else => return stat_err,
                    };
                    if (entry.kind == .sym_link) return error.SymlinkEncountered;
                    return error.NotRegularFile;
                },
                else => return err,
            };
            if (owns) current.close(self.io);
            current = next;
            owns = true;
        }
        return null;
    }
};

const ParsedUrl = struct {
    host: []u8,
    port: ?u16,
    /// 先頭 `/` を除いたパス。
    path: []u8,

    fn deinit(self: *ParsedUrl, allocator: Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
        self.* = undefined;
    }
};

fn parseHttpsUrl(allocator: Allocator, url: []const u8) Error!ParsedUrl {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InsecureScheme;
    if (uri.user != null or uri.password != null) return error.InvalidUrl;
    if (uri.query != null or uri.fragment != null) return error.InvalidUrl;
    const host_component = uri.host orelse return error.InvalidUrl;
    var scratch: [1024]u8 = undefined;
    const host_raw = host_component.toRaw(&scratch) catch return error.InvalidUrl;
    if (!validHost(host_raw)) return error.InvalidUrl;

    var path_buffer: [8192]u8 = undefined;
    const raw_path = uri.path.toRaw(&path_buffer) catch return error.InvalidUrl;
    if (raw_path.len == 0 or raw_path[0] != '/') return error.InvalidUrl;
    const trimmed = raw_path[1..];
    if (!validRelativePath(trimmed)) return error.InvalidUrl;

    var lower = try allocator.alloc(u8, host_raw.len);
    errdefer allocator.free(lower);
    for (host_raw, 0..) |byte, index| lower[index] = std.ascii.toLower(byte);

    return .{
        .host = lower,
        .port = if (uri.port) |port| if (port == 443) null else port else null,
        .path = try allocator.dupe(u8, trimmed),
    };
}

fn validHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    var previous_dot = false;
    for (host) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.';
        if (!ok) return false;
        if (byte == '.' and previous_dot) return false;
        previous_dot = byte == '.';
    }
    return host[0] != '.' and host[host.len - 1] != '.';
}

fn validRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (!validComponent(part)) return false;
    }
    return true;
}

fn validComponent(part: []const u8) bool {
    if (part.len == 0) return false;
    if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |byte| {
        if (byte == '\\' or byte == ':' or byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn readOpenFileAlloc(io: std.Io, allocator: Allocator, file: std.Io.File, max_bytes: usize) ![]u8 {
    const stat = try file.stat(io);
    if (stat.size > max_bytes) return error.TooLarge;
    // `allocRemaining(.limited(n))` は n ちょうどでも超過として扱うため、
    // 仕様の「上限以下を受理」に合わせて 1 バイト余分に読んでから判定する。
    const ceiling = if (max_bytes == std.math.maxInt(usize)) max_bytes else max_bytes + 1;
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = reader.interface.allocRemaining(allocator, .limited(ceiling)) catch |err| switch (err) {
        error.StreamTooLong => return error.TooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    if (bytes.len > max_bytes) {
        allocator.free(bytes);
        return error.TooLarge;
    }
    return bytes;
}

const ParsedStatus = struct { status: u16, location: ?[]const u8 = null };

fn parseStatusFile(allocator: Allocator, bytes: []const u8) Error!ParsedStatus {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const first = std.mem.trim(u8, lines.next() orelse return error.InvalidStatusFile, " \t\r");
    const status = std.fmt.parseInt(u16, first, 10) catch return error.InvalidStatusFile;
    if (status < 100 or status > 599) return error.InvalidStatusFile;
    var location: ?[]const u8 = null;
    if (status >= 300 and status <= 399) {
        const second_raw = lines.next() orelse return error.InvalidStatusFile;
        const second = std.mem.trim(u8, second_raw, " \t\r");
        if (second.len == 0) return error.InvalidStatusFile;
        const uri = std.Uri.parse(second) catch return error.InvalidStatusFile;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidStatusFile;
        location = try allocator.dupe(u8, second);
    }
    return .{ .status = status, .location = location };
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const testing = std.testing;

fn writeFixture(dir: std.Io.Dir, io: std.Io, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

test "index ツリーと URL ツリーから固定応答を返す" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    try writeFixture(temporary.dir, io, "index/v1/config.json", "{\"schema_version\":1}");
    try writeFixture(temporary.dir, io, "urls/cdn.example.invalid/artifacts/demo.npkg", "abc");

    var source = try Source.open(io, root, .{});
    defer source.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const config = try source.get(a, "https://cdn.example.invalid/index/v1/config.json");
    try testing.expectEqual(@as(u16, 200), config.status);
    try testing.expectEqualStrings("{\"schema_version\":1}", config.body);

    const artifact = try source.get(a, "https://CDN.example.invalid/artifacts/demo.npkg");
    try testing.expectEqualStrings("abc", artifact.body);
}

test "status ファイルで redirect を表現し、本文を読まない" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    try writeFixture(temporary.dir, io, "urls/cdn.example.invalid/artifacts/demo.npkg", "abc");
    try writeFixture(temporary.dir, io, "urls/cdn.example.invalid/artifacts/demo.npkg.status", "302\nhttps://other.example.invalid/demo.npkg\n");

    var source = try Source.open(io, root, .{});
    defer source.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const response = try source.get(arena.allocator(), "https://cdn.example.invalid/artifacts/demo.npkg");
    try testing.expectEqual(@as(u16, 302), response.status);
    try testing.expectEqualStrings("https://other.example.invalid/demo.npkg", response.location.?);
    try testing.expectEqualStrings("", response.body);
}

test "HTTPS・ホスト・パス・サイズの規則を拒否する" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try writeFixture(temporary.dir, io, "urls/cdn.example.invalid/artifacts/big.npkg", "12345");
    try writeFixture(temporary.dir, io, "urls/cdn.example.invalid/artifacts/ok.npkg", "ok");

    var source = try Source.open(io, root, .{ .max_artifact_bytes = 4 });
    defer source.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.InsecureScheme, source.get(a, "http://cdn.example.invalid/artifacts/ok.npkg"));
    try testing.expectError(error.InvalidUrl, source.get(a, "https://user@cdn.example.invalid/artifacts/ok.npkg"));
    try testing.expectError(error.InvalidUrl, source.get(a, "https://cdn.example.invalid/artifacts/ok.npkg?x=1"));
    try testing.expectError(error.InvalidUrl, source.get(a, "https://cdn.example.invalid/artifacts/../ok.npkg"));
    try testing.expectError(error.InvalidUrl, source.get(a, "https://cdn.example.invalid/artifacts%2f..%2fok.npkg"));
    try testing.expectError(error.FixtureNotFound, source.get(a, "https://cdn.example.invalid/artifacts/missing.npkg"));
    try testing.expectError(error.TooLarge, source.get(a, "https://cdn.example.invalid/artifacts/big.npkg"));
}

test "symlink のルート・途中ディレクトリ・ファイルを拒否する" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    try writeFixture(temporary.dir, io, "outside/artifacts/ok.npkg", "ok");
    try writeFixture(temporary.dir, io, "urls/cdn.example.invalid/real/ok.npkg", "ok");
    try temporary.dir.symLink(io, "../../outside", "urls/cdn.example.invalid/linked", .{ .is_directory = true });
    try temporary.dir.symLink(io, "real/ok.npkg", "urls/cdn.example.invalid/artifacts", .{ .is_directory = true });
    try temporary.dir.symLink(io, root, "root-link", .{ .is_directory = true });

    var source = try Source.open(io, root, .{});
    defer source.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.SymlinkEncountered, source.get(a, "https://cdn.example.invalid/artifacts/ok.npkg"));
    try testing.expectError(error.SymlinkEncountered, source.get(a, "https://cdn.example.invalid/linked/artifacts/ok.npkg"));

    const link_root = try std.fs.path.join(testing.allocator, &.{ root, "root-link" });
    defer testing.allocator.free(link_root);
    try testing.expectError(error.SymlinkEncountered, Source.open(io, link_root, .{}));
}
