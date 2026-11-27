//! 配信セキュリティ（§4.2・§6.4）の適合性テスト。
//!
//! 実ネットワークは使わず、`Sandbox` が URL → 固定応答の表を返す。D-01〜D-08
//! の入力は nako-registry `fixtures/v1/conformance.md` の配信セキュリティ表に
//! 従う。`abc` の SHA-256 は `ba7816bf...15ad`。

const std = @import("std");
const testing = std.testing;
const download = @import("v1_download.zig");
const index = @import("v1_index.zig");
const types = @import("v1_types.zig");

const Allocator = std.mem.Allocator;

const abc_sha256 = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const babc_sha256 = "sha256:bb7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

const base_url = "https://cdn.example.invalid/artifacts";
const central_url = "https://cdn.example.invalid/artifacts/demo.npkg";
const external_url = "https://repo.example.invalid/demo.npkg";

const d_config_json =
    \\{
    \\  "schema_version": 1,
    \\  "registry_id": "test-registry",
    \\  "api_base_url": "https://api.example.invalid/v1",
    \\  "artifact_base_url": "https://cdn.example.invalid/artifacts",
    \\  "allowed_external_hosts": ["repo.example.invalid"]
    \\}
;

const sample_config_json =
    \\{
    \\  "schema_version": 1,
    \\  "registry_id": "nako-official",
    \\  "api_base_url": "https://api.registry.nako.example/v1",
    \\  "artifact_base_url": "https://cdn.registry.nako.example/artifacts",
    \\  "allowed_external_hosts": ["github.com", "objects.githubusercontent.com"]
    \\}
;

const sample_package_json =
    \\{
    \\  "schema_version": 1,
    \\  "id": "@soramikan/http",
    \\  "scope_id": "01936d2a-8c4f-7b12-9a01-3e4f5a6b7c8d",
    \\  "updated_at": "2026-11-27T13:30:00Z",
    \\  "deprecated": null,
    \\  "versions": [{
    \\    "version": "1.2.0",
    \\    "published_at": "2026-11-27T13:30:00Z",
    \\    "yanked": false,
    \\    "license": "MIT",
    \\    "capabilities": ["net", "native"],
    \\    "engines": {"lnako": ">=0.3.0 <1.0.0"},
    \\    "exports_global_commands": true,
    \\    "global_commands": ["HTTP取得"],
    \\    "features": {"default": ["tls"]},
    \\    "dependencies": [],
    \\    "provenance": {"verified": true},
    \\    "artifacts": [
    \\      {"kind": "universal", "runtimes": ["lnako", "cnako", "wnako"], "target": null,
    \\       "hosting": "registry",
    \\       "url": "https://cdn.registry.nako.example/artifacts/soramikan/http/1.2.0/universal.npkg",
    \\       "sha256": "sha256:1111111111111111111111111111111111111111111111111111111111111111", "size": 1},
    \\      {"kind": "esm", "runtimes": ["cnako", "wnako"], "target": null,
    \\       "hosting": "registry",
    \\       "url": "https://cdn.registry.nako.example/artifacts/soramikan/http/1.2.0/esm-cnako+wnako.npkg",
    \\       "sha256": "sha256:2222222222222222222222222222222222222222222222222222222222222222", "size": 1},
    \\      {"kind": "native-source", "runtimes": ["lnako"], "target": {"abi_version": 1},
    \\       "hosting": "registry",
    \\       "url": "https://cdn.registry.nako.example/artifacts/soramikan/http/1.2.0/native-source.npkg",
    \\       "sha256": "sha256:3333333333333333333333333333333333333333333333333333333333333333", "size": 1},
    \\      {"kind": "native-prebuilt", "runtimes": ["lnako"],
    \\       "target": {"target_triple": "x86_64-linux-gnu", "abi_version": 1, "glibc_min": "2.31"},
    \\       "hosting": "registry",
    \\       "url": "https://cdn.registry.nako.example/artifacts/soramikan/http/1.2.0/native.npkg",
    \\       "sha256": "sha256:4444444444444444444444444444444444444444444444444444444444444444", "size": 1}
    \\    ]
    \\  }]
    \\}
;

const Route = struct {
    url: []const u8,
    status: u16 = 200,
    location: ?[]const u8 = null,
    body: []const u8 = "",
};

/// URL → 固定応答の sandbox。要求された URL を順に記録する。
const Sandbox = struct {
    routes: []const Route,
    requests: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Sandbox, allocator: Allocator) void {
        for (self.requests.items) |url| allocator.free(url);
        self.requests.deinit(allocator);
    }

    fn fetch(context: ?*anyopaque, allocator: Allocator, url: []const u8) anyerror!download.Response {
        const self: *Sandbox = @ptrCast(@alignCast(context.?));
        const recorded = try allocator.dupe(u8, url);
        errdefer allocator.free(recorded);
        try self.requests.append(allocator, recorded);

        for (self.routes) |route| {
            if (!std.mem.eql(u8, route.url, url)) continue;
            return .{
                .status = route.status,
                .location = if (route.location) |location| try allocator.dupe(u8, location) else null,
                .body = try allocator.dupe(u8, route.body),
            };
        }
        return error.NotFound;
    }

    fn fetcher(self: *Sandbox) download.Fetcher {
        return .{ .context = self, .function = Sandbox.fetch };
    }
};

fn universal(url: []const u8, hosting: @TypeOf(@as(types.Artifact, undefined).hosting)) types.Artifact {
    return .{
        .kind = .universal,
        .runtimes = &.{ .lnako, .cnako, .wnako },
        .sha256 = abc_sha256,
        .url = url,
        .size = 3,
        .hosting = hosting,
    };
}

fn loadConfig(allocator: Allocator, text: []const u8) !index.Config {
    return index.parseConfig(allocator, text);
}

test "D-01 中央配信の基底パス内で index と実バイト列が一致する" {
    var config = try loadConfig(testing.allocator, d_config_json);
    defer config.deinit();
    var sandbox: Sandbox = .{ .routes = &.{.{ .url = central_url, .body = "abc" }} };
    defer sandbox.deinit(testing.allocator);

    var result = try download.fetch(testing.allocator, sandbox.fetcher(), .{
        .config = &config,
        .artifact = universal(central_url, .registry),
        .options = .{ .lock_sha256 = abc_sha256 },
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("abc", result.bytes);
    try testing.expectEqualStrings(abc_sha256[7..], &result.sha256Hex());
    try testing.expectEqualStrings(central_url, result.final_url);
    try testing.expectEqual(@as(u8, 0), result.redirects);
    try expectRequests(&sandbox, &.{central_url});
}

test "D-02 許可外部ホストで index と実バイト列が一致する" {
    var config = try loadConfig(testing.allocator, d_config_json);
    defer config.deinit();
    var sandbox: Sandbox = .{ .routes = &.{.{ .url = external_url, .body = "abc" }} };
    defer sandbox.deinit(testing.allocator);

    var result = try download.fetch(testing.allocator, sandbox.fetcher(), .{
        .config = &config,
        .artifact = universal(external_url, .external),
        .options = .{ .lock_sha256 = abc_sha256 },
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("abc", result.bytes);
    try expectRequests(&sandbox, &.{external_url});
}

test "D-03 許可外ホストと基底パス外を取得前に拒否する" {
    var config = try loadConfig(testing.allocator, d_config_json);
    defer config.deinit();

    {
        var sandbox: Sandbox = .{ .routes = &.{} };
        defer sandbox.deinit(testing.allocator);
        const url = "https://other.example.invalid/demo.npkg";
        try expectFetchError(
            &sandbox,
            &config,
            universal(url, .external),
            .{},
            error.ForeignHost,
        );
        try testing.expectEqual(@as(usize, 0), sandbox.requests.items.len);
    }
    {
        var sandbox: Sandbox = .{ .routes = &.{} };
        defer sandbox.deinit(testing.allocator);
        const url = "https://cdn.example.invalid/artifacts-old/demo.npkg";
        try expectFetchError(
            &sandbox,
            &config,
            universal(url, .registry),
            .{},
            error.OutsideBasePath,
        );
        try testing.expectEqual(@as(usize, 0), sandbox.requests.items.len);
    }
    // 中央配信の URL を外部配信として申告しても許可外ホストになる。
    {
        var sandbox: Sandbox = .{ .routes = &.{} };
        defer sandbox.deinit(testing.allocator);
        try expectFetchError(
            &sandbox,
            &config,
            universal(central_url, .external),
            .{},
            error.ForeignHost,
        );
    }
}

test "D-04 index と実バイト列の不一致を検出し本文を返さない" {
    var config = try loadConfig(testing.allocator, d_config_json);
    defer config.deinit();
    var sandbox: Sandbox = .{ .routes = &.{.{ .url = central_url, .body = "abd" }} };
    defer sandbox.deinit(testing.allocator);

    try expectFetchError(
        &sandbox,
        &config,
        universal(central_url, .registry),
        .{},
        error.HashMismatch,
    );
    try expectRequests(&sandbox, &.{central_url});
}

test "D-05 HTTPS 以外を拒否する" {
    var config = try loadConfig(testing.allocator, d_config_json);
    defer config.deinit();
    var sandbox: Sandbox = .{ .routes = &.{} };
    defer sandbox.deinit(testing.allocator);

    try expectFetchError(
        &sandbox,
        &config,
        universal("http://repo.example.invalid/demo.npkg", .external),
        .{},
        error.InsecureScheme,
    );
    try testing.expectEqual(@as(usize, 0), sandbox.requests.items.len);
}

test "D-06 lock のハッシュ不一致を検出する" {
    var config = try loadConfig(testing.allocator, d_config_json);
    defer config.deinit();
    var sandbox: Sandbox = .{ .routes = &.{.{ .url = central_url, .body = "abc" }} };
    defer sandbox.deinit(testing.allocator);

    try expectFetchError(
        &sandbox,
        &config,
        universal(central_url, .registry),
        .{ .lock_sha256 = babc_sha256 },
        error.LockHashMismatch,
    );
    try expectRequests(&sandbox, &.{central_url});
}

test "D-07 許可外へのリダイレクトを取得前に拒否する" {
    var config = try loadConfig(testing.allocator, d_config_json);
    defer config.deinit();
    const redirect_url = "https://other.example.invalid/demo.npkg";
    var sandbox: Sandbox = .{ .routes = &.{.{
        .url = central_url,
        .status = 302,
        .location = redirect_url,
        .body = "",
    }} };
    defer sandbox.deinit(testing.allocator);

    // 既定は redirect を一切追跡しない。
    try expectFetchError(
        &sandbox,
        &config,
        universal(central_url, .registry),
        .{},
        error.RedirectNotAllowed,
    );
    try expectRequests(&sandbox, &.{central_url});

    // 明示的に許可しても、転送先を取得前に検査して要求しない。
    try expectFetchError(
        &sandbox,
        &config,
        universal(central_url, .registry),
        .{ .max_redirects = 2 },
        error.ForeignHost,
    );
    try expectRequests(&sandbox, &.{ central_url, central_url });
}

test "D-08 index の配信 URL だけが変わってもハッシュが同じなら受理する" {
    var config = try loadConfig(testing.allocator, d_config_json);
    defer config.deinit();
    const new_url = "https://cdn.example.invalid/artifacts/v2/demo.npkg";
    var sandbox: Sandbox = .{ .routes = &.{.{ .url = new_url, .body = "abc" }} };
    defer sandbox.deinit(testing.allocator);

    var result = try download.fetch(testing.allocator, sandbox.fetcher(), .{
        .config = &config,
        .artifact = universal(new_url, .registry),
        .options = .{ .lock_sha256 = abc_sha256 },
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("abc", result.bytes);
    try testing.expectEqualStrings(new_url, result.final_url);
    try expectRequests(&sandbox, &.{new_url});
}

test "§4.2 同一オリジン内の許可されたリダイレクトだけを追跡する" {
    var config = try loadConfig(testing.allocator, d_config_json);
    defer config.deinit();
    const target = "https://cdn.example.invalid/artifacts/v2/demo.npkg";
    var sandbox: Sandbox = .{ .routes = &.{
        .{ .url = central_url, .status = 307, .location = "/artifacts/v2/demo.npkg" },
        .{ .url = target, .body = "abc" },
    } };
    defer sandbox.deinit(testing.allocator);

    var result = try download.fetch(testing.allocator, sandbox.fetcher(), .{
        .config = &config,
        .artifact = universal(central_url, .registry),
        .options = .{ .max_redirects = 1 },
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("abc", result.bytes);
    try testing.expectEqualStrings(target, result.final_url);
    try testing.expectEqual(@as(u8, 1), result.redirects);
    try expectRequests(&sandbox, &.{ central_url, target });
}

test "リダイレクト回数・Location 不在・HTTP エラーを拒否する" {
    var config = try loadConfig(testing.allocator, d_config_json);
    defer config.deinit();

    {
        var sandbox: Sandbox = .{ .routes = &.{
            .{ .url = central_url, .status = 302, .location = "/artifacts/next.npkg" },
            .{ .url = "https://cdn.example.invalid/artifacts/next.npkg", .status = 302, .location = "/artifacts/demo.npkg" },
        } };
        defer sandbox.deinit(testing.allocator);
        try expectFetchError(
            &sandbox,
            &config,
            universal(central_url, .registry),
            .{ .max_redirects = 1 },
            error.TooManyRedirects,
        );
        try testing.expectEqual(@as(usize, 2), sandbox.requests.items.len);
    }
    {
        var sandbox: Sandbox = .{ .routes = &.{.{ .url = central_url, .status = 301 }} };
        defer sandbox.deinit(testing.allocator);
        try expectFetchError(
            &sandbox,
            &config,
            universal(central_url, .registry),
            .{ .max_redirects = 1 },
            error.MissingLocation,
        );
    }
    {
        var sandbox: Sandbox = .{ .routes = &.{.{ .url = central_url, .status = 404 }} };
        defer sandbox.deinit(testing.allocator);
        try expectFetchError(
            &sandbox,
            &config,
            universal(central_url, .registry),
            .{},
            error.FetchFailed,
        );
    }
}

test "取得上限・ハッシュ形式・基底パスの境界を検査する" {
    var config = try loadConfig(testing.allocator, d_config_json);
    defer config.deinit();

    {
        var sandbox: Sandbox = .{ .routes = &.{.{ .url = central_url, .body = "abc" }} };
        defer sandbox.deinit(testing.allocator);
        try expectFetchError(
            &sandbox,
            &config,
            universal(central_url, .registry),
            .{ .max_bytes = 2 },
            error.TooLarge,
        );
    }
    {
        var sandbox: Sandbox = .{ .routes = &.{} };
        defer sandbox.deinit(testing.allocator);
        var artifact = universal(central_url, .registry);
        artifact.sha256 = "sha256:short";
        try expectFetchError(&sandbox, &config, artifact, .{}, error.InvalidHash);
        try testing.expectEqual(@as(usize, 0), sandbox.requests.items.len);
    }
    {
        var sandbox: Sandbox = .{ .routes = &.{} };
        defer sandbox.deinit(testing.allocator);
        try expectFetchError(
            &sandbox,
            &config,
            universal(central_url, .registry),
            .{ .lock_sha256 = "sha256:XYZ" },
            error.InvalidLockHash,
        );
    }
    {
        var sandbox: Sandbox = .{ .routes = &.{} };
        defer sandbox.deinit(testing.allocator);
        try expectFetchError(
            &sandbox,
            &config,
            universal("https://cdn.example.invalid/artifactsX/demo.npkg", .registry),
            .{},
            error.OutsideBasePath,
        );
        try expectFetchError(
            &sandbox,
            &config,
            universal("https://cdn.example.invalid/artifacts/../secret.npkg", .registry),
            .{},
            error.OutsideBasePath,
        );
        try expectFetchError(
            &sandbox,
            &config,
            universal("https://cdn.example.invalid/artifacts/%2e%2e/secret.npkg", .registry),
            .{},
            error.OutsideBasePath,
        );
        try expectFetchError(
            &sandbox,
            &config,
            universal("https://cdn.example.invalid:8443/artifacts/demo.npkg", .registry),
            .{},
            error.ForeignHost,
        );
    }
    // 基底パス配下のクエリ付き URL は許可する。
    {
        const url = "https://cdn.example.invalid/artifacts/demo.npkg?signature=1";
        var sandbox: Sandbox = .{ .routes = &.{.{ .url = url, .body = "abc" }} };
        defer sandbox.deinit(testing.allocator);
        var result = try download.fetch(testing.allocator, sandbox.fetcher(), .{
            .config = &config,
            .artifact = universal(url, .registry),
        });
        result.deinit(testing.allocator);
    }
}

test "§4.2 標準 sample の全アーティファクト URL が配信元検査を通る" {
    var config = try loadConfig(testing.allocator, sample_config_json);
    defer config.deinit();
    var package = try index.parsePackage(testing.allocator, sample_package_json);
    defer package.deinit();

    const release = package.findRelease("1.2.0") orelse return error.TestExpectedRelease;
    try testing.expectEqual(@as(usize, 4), release.artifacts.len);
    for (release.artifacts) |artifact| {
        try download.checkSource(&config, artifact, artifact.url);
    }
    // 外部許可リストにないホストは拒否する。
    try testing.expectError(
        error.ForeignHost,
        download.checkSource(&config, release.artifacts[0], "https://evil.invalid/a.npkg"),
    );
}

fn expectFetchError(
    sandbox: *Sandbox,
    config: *const index.Config,
    artifact: types.Artifact,
    options: download.Options,
    expected: anyerror,
) !void {
    if (download.fetch(testing.allocator, sandbox.fetcher(), .{
        .config = config,
        .artifact = artifact,
        .options = options,
    })) |value| {
        var result = value;
        result.deinit(testing.allocator);
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(expected, err);
    }
}

fn expectRequests(sandbox: *const Sandbox, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, sandbox.requests.items.len);
    for (expected, sandbox.requests.items) |want, got| {
        try testing.expectEqualStrings(want, got);
    }
}
