//! 配信元の検証と `.npkg` 取得（nako-registry `docs/specification.md` §4.2・§6.4）。
//!
//! 実運用のネットワーク実装はこのモジュールに置かない。呼び出し側が
//! `Fetcher`（ローカル fixture や sandbox のコールバック）を渡し、この
//! モジュールは次の順序だけを保証する。
//!
//! 1. 取得前に URL を検査する（HTTPS、中央は同一オリジン + 基底パス配下、
//!    外部は `allowed_external_hosts` と一致）。
//! 2. redirect は既定で拒否する。`max_redirects` を増やした場合も、各転送先を
//!    取得前に 1. と同じ規則で検査し、許可外のホストへは要求を送らない。
//! 3. 応答本文の SHA-256 を計算し、index の `sha256` と、指定があれば
//!    `nako.lock` に記録された SHA-256 の双方と一致した場合だけ本文を返す。
//!    不一致なら本文を返さず、展開へ進めない。
//!
//! 応答本文と `Location` は `Fetcher` が渡された allocator で確保し、所有権を
//! このモジュールへ移す契約とする（成功時は `Result` が本文を所有する）。

const std = @import("std");
const index = @import("v1_index.zig");
const types = @import("v1_types.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    /// URL として解析できない、userinfo を含む、ホストがない。
    InvalidUrl,
    /// HTTPS でない（D-05）。
    InsecureScheme,
    /// 中央配信で別オリジン、または外部配信で許可外ホスト（D-03・D-07）。
    ForeignHost,
    /// 中央配信の基底パス配下でない（D-03）。
    OutsideBasePath,
    /// `max_redirects == 0` で redirect が返った（D-07 の既定動作）。
    RedirectNotAllowed,
    /// 許可した回数を超えて redirect した。
    TooManyRedirects,
    /// redirect 応答に `Location` がない。
    MissingLocation,
    /// `Location` を安全に解決できない。
    InvalidLocation,
    /// 取得コールバックが失敗した、または 200/3xx 以外が返った。
    FetchFailed,
    /// `max_bytes` を超えた。
    TooLarge,
    /// 実バイト列のハッシュが index と一致しない（D-04）。
    HashMismatch,
    /// 実バイト列のハッシュが lock と一致しない（D-06）。
    LockHashMismatch,
    /// `Artifact.sha256` が `sha256:` + 64 桁の形式でない。
    InvalidHash,
    /// lock のハッシュが `sha256:` + 64 桁の形式でない。
    InvalidLockHash,
    OutOfMemory,
};

/// fixture コールバックが返す 1 応答。`body` と `location` は `allocator` で
/// 確保し、所有権を呼び出し元（このモジュール）へ移す。
pub const Response = struct {
    status: u16 = 200,
    location: ?[]const u8 = null,
    body: []const u8 = "",
};

pub const FetchFn = *const fn (
    context: ?*anyopaque,
    allocator: Allocator,
    url: []const u8,
) anyerror!Response;

/// 取得コールバック。実ネットワークを使わず、ローカル fixture を返す
/// sandbox 実装を差し込むための境界。
pub const Fetcher = struct {
    context: ?*anyopaque = null,
    function: FetchFn,

    pub fn fetch(self: Fetcher, allocator: Allocator, url: []const u8) anyerror!Response {
        return self.function(self.context, allocator, url);
    }
};

pub const Options = struct {
    /// 許可する redirect 回数。0（既定）は redirect を一切追跡しない。
    max_redirects: u8 = 0,
    /// 応答本文の上限。0 は上限なし。
    max_bytes: usize = 64 * 1024 * 1024,
    /// `nako.lock` に記録された選択済みアーティファクトの SHA-256。
    lock_sha256: ?[]const u8 = null,
};

pub const Request = struct {
    config: *const index.Config,
    artifact: types.Artifact,
    options: Options = .{},
};

pub const Result = struct {
    /// 取得した実バイト列。呼び出し側が `deinit` で解放する。
    bytes: []u8,
    sha256: [32]u8,
    /// 最終的に 200 を返した URL（redirect 解決後）。
    final_url: []u8,
    /// 追跡した redirect 回数。
    redirects: u8,

    pub fn sha256Hex(self: *const Result) [64]u8 {
        return std.fmt.bytesToHex(self.sha256, .lower);
    }

    pub fn deinit(self: *Result, allocator: Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.final_url);
        self.* = undefined;
    }
};

/// アーティファクトを取得し、§4.2 の配信元検査と §6.4 のハッシュ照合を
/// 行う。成功時だけ本文を返す（失敗時は展開に進めない）。
pub fn fetch(allocator: Allocator, fetcher: Fetcher, request: Request) Error!Result {
    if (!types.validHash(request.artifact.sha256)) return error.InvalidHash;
    if (request.options.lock_sha256) |lock_hash| {
        if (!types.validHash(lock_hash)) return error.InvalidLockHash;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var current_url: []const u8 = try arena.allocator().dupe(u8, request.artifact.url);
    var redirects: u8 = 0;

    while (true) {
        try checkSource(request.config, request.artifact, current_url);

        const response = fetcher.fetch(allocator, current_url) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FetchFailed,
        };
        var keep_body = false;
        defer if (!keep_body) allocator.free(@constCast(response.body));
        defer if (response.location) |location| allocator.free(@constCast(location));

        switch (response.status) {
            200 => {
                if (request.options.max_bytes != 0 and response.body.len > request.options.max_bytes) {
                    return error.TooLarge;
                }
                const digest = sha256(response.body);
                if (!hashMatches(request.artifact.sha256, digest)) return error.HashMismatch;
                if (request.options.lock_sha256) |lock_hash| {
                    if (!hashMatches(lock_hash, digest)) return error.LockHashMismatch;
                }
                const final_url = try allocator.dupe(u8, current_url);
                keep_body = true;
                return .{
                    .bytes = @constCast(response.body),
                    .sha256 = digest,
                    .final_url = final_url,
                    .redirects = redirects,
                };
            },
            301, 302, 303, 307, 308 => {
                if (request.options.max_redirects == 0) return error.RedirectNotAllowed;
                if (redirects >= request.options.max_redirects) return error.TooManyRedirects;
                const location = response.location orelse return error.MissingLocation;
                current_url = resolveLocation(arena.allocator(), current_url, location) catch
                    return error.InvalidLocation;
                redirects += 1;
            },
            else => return error.FetchFailed,
        }
    }
}

/// §4.2 の配信元検査だけを行う。取得前の各 hop に適用する。
pub fn checkSource(
    config: *const index.Config,
    artifact: types.Artifact,
    url: []const u8,
) Error!void {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (uri.user != null or uri.password != null) return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InsecureScheme;
    const host = hostText(uri) orelse return error.InvalidUrl;
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '%') != null) return error.InvalidUrl;

    switch (artifact.hosting) {
        .registry => {
            const base = std.Uri.parse(config.artifact_base_url) catch return error.InvalidUrl;
            if (!std.ascii.eqlIgnoreCase(base.scheme, "https")) return error.InvalidUrl;
            const base_host = hostText(base) orelse return error.InvalidUrl;
            if (!std.ascii.eqlIgnoreCase(host, base_host)) return error.ForeignHost;
            if (effectivePort(uri) != effectivePort(base)) return error.ForeignHost;
            if (!pathUnderBase(componentText(base.path), componentText(uri.path))) {
                return error.OutsideBasePath;
            }
        },
        .external => {
            if (!config.allowsExternalHost(host)) return error.ForeignHost;
        },
    }
}

fn pathUnderBase(base_path_raw: []const u8, url_path: []const u8) bool {
    if (url_path.len == 0 or url_path[0] != '/') return false;
    const base_path = std.mem.trimEnd(u8, base_path_raw, "/");
    if (base_path.len == 0) return true;
    if (!std.mem.startsWith(u8, url_path, base_path)) return false;
    if (url_path.len == base_path.len) return false;
    if (url_path[base_path.len] != '/') return false;

    var segments = std.mem.splitScalar(u8, url_path[base_path.len + 1 ..], '/');
    var saw_segment = false;
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        // パーセントエンコードされた `.` `/` による基底パス脱出を避ける。
        if (std.mem.indexOfScalar(u8, segment, '%') != null) return false;
        if (std.mem.indexOfScalar(u8, segment, '\\') != null) return false;
        saw_segment = true;
    }
    return saw_segment;
}

fn hostText(uri: std.Uri) ?[]const u8 {
    const host = uri.host orelse return null;
    return componentText(host);
}

fn componentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw, .percent_encoded => |text| text,
    };
}

fn effectivePort(uri: std.Uri) u16 {
    if (uri.port) |port| return port;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return 0;
}

fn resolveLocation(allocator: Allocator, base_url: []const u8, location: []const u8) ![]const u8 {
    if (location.len == 0) return error.InvalidLocation;
    for (location) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') return error.InvalidLocation;
    }
    if (hasScheme(location)) return allocator.dupe(u8, location);

    const base = std.Uri.parse(base_url) catch return error.InvalidLocation;
    const origin = originOf(base_url) orelse return error.InvalidLocation;

    if (std.mem.startsWith(u8, location, "//")) {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ base.scheme, location });
    }
    if (location[0] == '/') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, location });
    }
    if (location[0] == '#') return error.InvalidLocation;
    if (location[0] == '?') {
        const base_path = componentText(base.path);
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ origin, base_path, location });
    }
    const base_path = componentText(base.path);
    const slash = std.mem.lastIndexOfScalar(u8, base_path, '/') orelse 0;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ origin, base_path[0 .. slash + 1], location });
}

fn hasScheme(text: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return false;
    if (colon == 0) return false;
    if (!std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..colon]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return false;
    }
    for (text[0..colon]) |byte| {
        if (byte == '/' or byte == '?' or byte == '#') return false;
    }
    return true;
}

fn originOf(url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const authority_start = scheme_end + 3;
    if (authority_start >= url.len) return null;
    var end = url.len;
    for (url[authority_start..], authority_start..) |byte, position| {
        if (byte == '/' or byte == '?' or byte == '#') {
            end = position;
            break;
        }
    }
    if (end == authority_start) return null;
    return url[0..end];
}

/// 実バイト列の SHA-256。
pub fn sha256(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn hashMatches(expected: []const u8, digest: [32]u8) bool {
    const actual = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, expected[7..], &actual);
}

test {
    _ = @import("v1_download_test.zig");
}
