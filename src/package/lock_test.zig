const std = @import("std");
const lock = @import("lock.zig");
const resolver = @import("resolver.zig");
const semver = @import("semver.zig");
const diag = @import("diagnostics.zig");

const T = std.testing;
const Version = resolver.Version;

const sqlite_id = "pkg:10000000000000000000000000000000";
const req_id = "pkg:20000000000000000000000000000000";
const sqlite_name = "sqlite";
const req_name = "req";

const sqlite_source = lock.Source{ .kind = .registry, .url = "https://registry.example.com/pkg/sqlite" };
const req_source = lock.Source{ .kind = .registry, .url = "https://registry.example.com/pkg/req" };

const sqlite_source_artifact = lock.Artifact{
    .key = "source",
    .kind = "source",
    .type = "tar.gz",
    .sha256 = "sha256:1111111111111111111111111111111111111111111111111111111111111111",
    .url = "https://registry.example.com/pkg/sqlite/v1.2.3/source.tar.gz",
};
const sqlite_native_artifact = lock.Artifact{
    .key = "native",
    .kind = "native",
    .type = ".npkg",
    .sha256 = "sha256:2222222222222222222222222222222222222222222222222222222222222222",
    .url = "https://registry.example.com/pkg/sqlite/v1.2.3/native.npkg",
};
const req_source_artifact = lock.Artifact{
    .key = "source",
    .kind = "source",
    .type = "tar.gz",
    .sha256 = "sha256:3333333333333333333333333333333333333333333333333333333333333333",
    .url = "https://registry.example.com/pkg/req/v2.0.1/source.tar.gz",
};

const FixtureEntry = struct {
    id: []const u8,
    name: []const u8,
    public_id: ?[]const u8 = null,
    source: ?lock.Source = null,
    resolved_from: ?lock.Source = null,
    artifacts: []const lock.Artifact = &.{},
    npm_instances: []const lock.NpmInstance = &.{},
};

const Fixtures = struct {
    entries: []const FixtureEntry,

    fn get(context: *anyopaque, gpa: std.mem.Allocator, id: []const u8, version: []const u8) anyerror!?lock.PackageDetails {
        _ = gpa;
        _ = version;
        const self: *const Fixtures = @ptrCast(@alignCast(@constCast(context)));
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.id, id)) {
                return .{
                    .public_id = entry.public_id orelse entry.id,
                    .name = entry.name,
                    .source = entry.source,
                    .resolved_from = entry.resolved_from,
                    .artifacts = entry.artifacts,
                    .npm_instances = entry.npm_instances,
                };
            }
        }
        return null;
    }

    fn details(self: *const Fixtures) lock.DetailsSource {
        return .{ .context = @ptrCast(@constCast(self)), .getFn = get };
    }
};

const default_fixtures = Fixtures{ .entries = &.{
    .{ .id = sqlite_id, .name = sqlite_name, .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{ sqlite_source_artifact, sqlite_native_artifact } },
    .{ .id = req_id, .name = req_name, .source = req_source, .resolved_from = req_source, .artifacts = &.{req_source_artifact} },
} };

fn node(id: []const u8, version: []const u8, dependencies: []const resolver.PackageId, features: []const []const u8) !resolver.PackageNode {
    return .{
        .id = .{ .pkg = id },
        .version = try Version.parse(version),
        .features = features,
        .implementation = .source,
        .prefer_native = false,
        .dependencies = dependencies,
    };
}

fn sampleInput() lock.Input {
    return .{
        .manifest_sha256 = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .profile = "default",
        .features = &.{ "default", "http" },
        .target = .{ .os = "macos", .cpu = "aarch64", .abi = "gnu" },
    };
}

const default_profile = lock.NamedProfile{
    .name = "default",
    .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu", .compat_js = false },
};

fn sampleLock(gpa: std.mem.Allocator) !lock.Lock {
    const nodes = [_]resolver.PackageNode{
        try node(sqlite_id, "1.2.3", &.{.{ .pkg = req_id }}, &.{"default"}),
        try node(req_id, "2.0.1", &.{}, &.{ "default", "http" }),
    };
    return lock.build(gpa, sampleInput(), &.{default_profile}, &nodes, default_fixtures.details());
}

fn validateLock(lock_value: *const lock.Lock) !void {
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(lock_value, &diagnostics);
    if (diagnostics.hasErrors()) {
        var rendered: std.Io.Writer.Allocating = .init(T.allocator);
        defer rendered.deinit();
        try diagnostics.render(&rendered.writer, "nako.lock");
        std.debug.print("{s}", .{rendered.written()});
    }
    try T.expect(!diagnostics.hasErrors());
}

// ---------------------------------------------------------------------------
// シリアライズ・解析
// ---------------------------------------------------------------------------

test "同一モデルは同一バイト列へ決定的にシリアライズする" {
    var first = try sampleLock(T.allocator);
    defer first.deinit();
    var second = try sampleLock(T.allocator);
    defer second.deinit();

    const first_bytes = try lock.toBytes(&first, T.allocator);
    defer T.allocator.free(first_bytes);
    const second_bytes = try lock.toBytes(&second, T.allocator);
    defer T.allocator.free(second_bytes);

    try T.expectEqualStrings(first_bytes, second_bytes);
}

test "serializeとparseを往復してもバイト列が不変である" {
    var original = try sampleLock(T.allocator);
    defer original.deinit();
    const bytes = try lock.toBytes(&original, T.allocator);
    defer T.allocator.free(bytes);

    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    var parsed = try lock.parse(T.allocator, bytes, &diagnostics);
    defer parsed.deinit();
    try T.expect(!diagnostics.hasErrors());

    const again = try lock.toBytes(&parsed, T.allocator);
    defer T.allocator.free(again);
    try T.expectEqualStrings(bytes, again);
}

test "sample lockは意味検証を通過する" {
    var value = try sampleLock(T.allocator);
    defer value.deinit();
    try validateLock(&value);
}

test "ルートの未知フィールドをE022で拒否する" {
    const text =
        \\{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": { "manifestSha256": "sha256:aa", "profile": "default", "features": [], "target": { "os": "macos", "cpu": "aarch64", "abi": "gnu" } },
        \\  "packages": {},
        \\  "unknown": true
        \\}
    ;
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try T.expectError(error.InvalidLock, lock.parse(T.allocator, text, &diagnostics));
    try T.expect(diagnostics.find(diag.E022_UNKNOWN_FIELD) != null);
}

test "必須フィールド欠落をE019で拒否する" {
    const text =
        \\{
        \\  "schemaVersion": 1,
        \\  "input": { "manifestSha256": "sha256:aa", "profile": "default", "features": [], "target": { "os": "macos", "cpu": "aarch64", "abi": "gnu" } },
        \\  "packages": {}
        \\}
    ;
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try T.expectError(error.InvalidLock, lock.parse(T.allocator, text, &diagnostics));
    try T.expect(diagnostics.find(diag.E019_REQUIRED_FIELD_MISSING) != null);
}

// ---------------------------------------------------------------------------
// 意味検証の診断
// ---------------------------------------------------------------------------

fn parseValid(text: []const u8) !lock.Lock {
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    return lock.parse(T.allocator, text, &diagnostics);
}

test "未知schemaをE002で拒否する" {
    var value = try parseValid(
        \\{
        \\  "schemaVersion": 999,
        \\  "resolverVersion": 1,
        \\  "input": { "manifestSha256": "sha256:aa", "profile": "default", "features": [], "target": { "os": "macos", "cpu": "aarch64", "abi": "gnu" } },
        \\  "packages": {}
        \\}
    );
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E002_UNKNOWN_LOCK_SCHEMA) != null);
}

test "未知profileをE030で拒否する" {
    var value = try parseValid(
        \\{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": { "manifestSha256": "sha256:aa", "profile": "release", "features": [], "target": { "os": "macos", "cpu": "aarch64", "abi": "gnu" } },
        \\  "packages": {},
        \\  "profiles": { "default": { "os": "macos", "cpu": "aarch64", "abi": "gnu" } }
        \\}
    );
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E030_UNKNOWN_PROFILE) != null);
}

test "未知runtimeをE014で拒否する" {
    var value = try parseValid(
        \\{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": { "manifestSha256": "sha256:aa", "profile": "default", "features": [], "target": { "os": "macos", "cpu": "aarch64", "abi": "gnu" } },
        \\  "packages": {},
        \\  "profiles": { "default": { "runtime": "browser", "os": "macos", "cpu": "aarch64", "abi": "gnu" } }
        \\}
    );
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E014_INVALID_PROFILE) != null);
}

const package_with_artifact =
    \\    "pkg:10000000000000000000000000000000": {
    \\      "id": "pkg:10000000000000000000000000000000",
    \\      "name": "test",
    \\      "version": "1.0.0",
    \\      "source": { "type": "registry", "url": "https://registry.example.com/pkg/test" },
    \\      "resolvedFrom": { "type": "registry", "url": "https://registry.example.com/pkg/test" },
    \\      "dependencies": [],
    \\      "features": ["default"],
    \\      "artifacts": {
    \\        "native": { "kind": "native", "type": ".npkg", "sha256": "sha256:00", "url": "https://ex/native.npkg" }
    \\      }
    \\    }
;

fn lockWithPackages(packages: []const u8, profiles: []const u8) ![]u8 {
    return std.fmt.allocPrint(T.allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": {{ "manifestSha256": "sha256:aa", "profile": "default", "features": ["default"], "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }} }},
        \\  "packages": {{
        \\{s}
        \\  }},
        \\  "profiles": {{ "default": {{ {s} }} }}
        \\}}
    , .{ packages, profiles });
}

test "artifact無しをE008で拒否する" {
    const text = try lockWithPackages(
        \\    "pkg:10000000000000000000000000000000": {
        \\      "id": "pkg:10000000000000000000000000000000",
        \\      "name": "test",
        \\      "version": "1.0.0",
        \\      "dependencies": [],
        \\      "features": ["default"]
        \\    }
    , "\"os\": \"macos\", \"cpu\": \"aarch64\", \"abi\": \"gnu\"");
    defer T.allocator.free(text);
    var value = try parseValid(text);
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E008_MISSING_ARTIFACT) != null);
}

test "source artifactは選択native実装のcontainerとして扱う" {
    const text = try lockWithPackages(
        \\    "pkg:10000000000000000000000000000000": {
        \\      "id": "pkg:10000000000000000000000000000000",
        \\      "name": "source-lib",
        \\      "version": "1.0.0",
        \\      "implementation": "native",
        \\      "source": { "type": "path", "path": "lib", "mutable": true },
        \\      "dependencies": [],
        \\      "features": [],
        \\      "artifacts": { "source": { "kind": "source" } }
        \\    }
    , "\"os\": \"macos\", \"cpu\": \"aarch64\", \"abi\": \"gnu\"");
    defer T.allocator.free(text);
    var value = try parseValid(text);
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E008_MISSING_ARTIFACT) == null);
}

test "registry source artifactはnative implementationの欠落を許容しない" {
    const text = try lockWithPackages(
        \\    "pkg:10000000000000000000000000000000": {
        \\      "id": "pkg:10000000000000000000000000000000",
        \\      "name": "registry-lib",
        \\      "version": "1.0.0",
        \\      "implementation": "native",
        \\      "source": { "type": "registry", "url": "https://registry.example.com/registry-lib" },
        \\      "dependencies": [],
        \\      "features": [],
        \\      "artifacts": { "source": { "kind": "source" } }
        \\    }
    , "\"runtime\": \"lnako\", \"os\": \"macos\", \"cpu\": \"aarch64\", \"abi\": \"gnu\"");
    defer T.allocator.free(text);
    var value = try parseValid(text);
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E008_MISSING_ARTIFACT) != null);
}

test "source ESM実装の正規表記を受理し通常profileではE006で拒否する" {
    const text = try lockWithPackages(
        \\    "pkg:10000000000000000000000000000000": {
        \\      "id": "pkg:10000000000000000000000000000000",
        \\      "name": "source-esm",
        \\      "version": "1.0.0",
        \\      "implementation": "ESM",
        \\      "source": { "type": "path", "path": "lib", "mutable": true },
        \\      "dependencies": [],
        \\      "features": [],
        \\      "artifacts": { "source": { "kind": "source" } }
        \\    }
    , "\"runtime\": \"lnako\", \"os\": \"macos\", \"cpu\": \"aarch64\", \"abi\": \"gnu\", \"compat-js\": false");
    defer T.allocator.free(text);
    var value = try parseValid(text);
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E006_JS_IN_NORMAL_MODE) != null);
    try T.expect(diagnostics.find(diag.E029_INVALID_VALUE) == null);

    // 明示的 --compat-js はprofile宣言より優先してESM sourceを許容する。
    value.input.target.compat_js = true;
    var compat_diagnostics = diag.List.init(T.allocator);
    defer compat_diagnostics.deinit();
    try lock.validate(&value, &compat_diagnostics);
    try T.expect(compat_diagnostics.find(diag.E006_JS_IN_NORMAL_MODE) == null);
    try T.expect(compat_diagnostics.find(diag.E008_MISSING_ARTIFACT) == null);
}

test "未知artifact kindをE007で拒否する" {
    const text = try lockWithPackages(
        \\    "pkg:10000000000000000000000000000000": {
        \\      "id": "pkg:10000000000000000000000000000000",
        \\      "name": "test",
        \\      "version": "1.0.0",
        \\      "dependencies": [],
        \\      "features": ["default"],
        \\      "artifacts": { "native": { "kind": "wasm", "type": ".npkg", "sha256": "sha256:00", "url": "https://ex/wasm" } }
        \\    }
    , "\"os\": \"macos\", \"cpu\": \"aarch64\", \"abi\": \"gnu\"");
    defer T.allocator.free(text);
    var value = try parseValid(text);
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E007_UNKNOWN_ARTIFACT_KIND) != null);
}

test "通常lnako profileのESMをE006で拒否する" {
    const text =
        \\{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": { "manifestSha256": "sha256:aa", "profile": "default", "features": [], "target": { "os": "linux", "cpu": "x86_64", "abi": "gnu" } },
        \\  "packages": {
        \\    "pkg:10000000000000000000000000000000": {
        \\      "id": "pkg:10000000000000000000000000000000",
        \\      "name": "esm-only",
        \\      "version": "1.0.0",
        \\      "dependencies": [],
        \\      "features": ["default"],
        \\      "artifacts": { "esm": { "kind": "ESM", "type": "npm-tarball", "sha256": "sha256:00", "url": "https://ex/index.mjs" } }
        \\    }
        \\  },
        \\  "profiles": { "default": { "runtime": "lnako", "os": "linux", "cpu": "x86_64", "abi": "gnu", "compat-js": false } }
        \\}
    ;
    var value = try parseValid(text);
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E006_JS_IN_NORMAL_MODE) != null);
}

test "cnako profileのESMは許容する" {
    const text =
        \\{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": { "manifestSha256": "sha256:aa", "profile": "default", "features": [], "target": { "os": "linux", "cpu": "x86_64", "abi": "gnu" } },
        \\  "packages": {
        \\    "pkg:10000000000000000000000000000000": {
        \\      "id": "pkg:10000000000000000000000000000000",
        \\      "name": "esm-only",
        \\      "version": "1.0.0",
        \\      "dependencies": [],
        \\      "features": ["default"],
        \\      "artifacts": { "esm": { "kind": "ESM", "type": "npm-tarball", "sha256": "sha256:00", "url": "https://ex/index.mjs" } }
        \\    }
        \\  },
        \\  "profiles": { "default": { "runtime": "cnako", "os": "linux", "cpu": "x86_64", "abi": "gnu" } }
        \\}
    ;
    var value = try parseValid(text);
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(!diagnostics.hasErrors());
}

test "欠落した依存先をE013で拒否する" {
    const text = try lockWithPackages(
        \\    "pkg:10000000000000000000000000000000": {
        \\      "id": "pkg:10000000000000000000000000000000",
        \\      "name": "test",
        \\      "version": "1.0.0",
        \\      "dependencies": ["pkg:99999999999999999999999999999999"],
        \\      "features": ["default"],
        \\      "artifacts": { "native": { "kind": "native", "type": ".npkg", "sha256": "sha256:00", "url": "https://ex/native.npkg" } }
        \\    }
    , "\"os\": \"macos\", \"cpu\": \"aarch64\", \"abi\": \"gnu\"");
    defer T.allocator.free(text);
    var value = try parseValid(text);
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E013_MISSING_PACKAGE) != null);
}

// ---------------------------------------------------------------------------
// 鮮度判定
// ---------------------------------------------------------------------------

test "manifest/profile/features/target変更を鮮度判定で検出する" {
    var value = try sampleLock(T.allocator);
    defer value.deinit();

    try T.expectEqual(lock.Freshness.fresh, lock.checkFreshness(&value, sampleInput()));

    var manifest_changed = sampleInput();
    manifest_changed.manifest_sha256 = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try T.expectEqual(lock.Freshness.stale_manifest, lock.checkFreshness(&value, manifest_changed));

    var profile_changed = sampleInput();
    profile_changed.profile = "release";
    try T.expectEqual(lock.Freshness.stale_profile, lock.checkFreshness(&value, profile_changed));

    var features_changed = sampleInput();
    features_changed.features = &.{"default"};
    try T.expectEqual(lock.Freshness.stale_features, lock.checkFreshness(&value, features_changed));

    var target_changed = sampleInput();
    target_changed.target = .{ .os = "linux", .cpu = "x86_64", .abi = "gnu" };
    try T.expectEqual(lock.Freshness.stale_target, lock.checkFreshness(&value, target_changed));

    try T.expectEqual(lock.Freshness.missing, lock.checkFreshness(null, sampleInput()));
}

test "runtime・engines version の変更は stale_target として検出する" {
    // 解決 runtime・engines 照合 version は lock の鮮度鍵。`--runtime`
    // 切替やコンパイラ更新は package 選択を変え得るため、記録と異なる
    // 入力は stale として再解決する。これらを記録しない旧 lock は
    // null ≠ 値で stale となり、再生成で記録付き lock へ移行する。
    const nodes = [_]resolver.PackageNode{
        try node(sqlite_id, "1.2.3", &.{.{ .pkg = req_id }}, &.{"default"}),
        try node(req_id, "2.0.1", &.{}, &.{ "default", "http" }),
    };
    var versioned = sampleInput();
    versioned.runtime = "lnako";
    versioned.nako_version = "3.7.24";
    versioned.lnako_version = "0.2.2";
    var value = try lock.build(T.allocator, versioned, &.{default_profile}, &nodes, default_fixtures.details());
    defer value.deinit();

    try T.expectEqual(lock.Freshness.fresh, lock.checkFreshness(&value, versioned));

    var runtime_changed = versioned;
    runtime_changed.runtime = "cnako";
    try T.expectEqual(lock.Freshness.stale_target, lock.checkFreshness(&value, runtime_changed));

    var version_changed = versioned;
    version_changed.lnako_version = "9.9.9";
    try T.expectEqual(lock.Freshness.stale_target, lock.checkFreshness(&value, version_changed));

    // 記録を持たない入力（version 未供給の呼出し側）も不一致。
    try T.expectEqual(lock.Freshness.stale_target, lock.checkFreshness(&value, sampleInput()));

    // 逆に runtime/version を記録しない旧 lock は、記録付きの入力で
    // stale となり再生成される（同一の旧入力では fresh のまま）。
    var legacy = try sampleLock(T.allocator);
    defer legacy.deinit();
    try T.expectEqual(lock.Freshness.fresh, lock.checkFreshness(&legacy, sampleInput()));
    try T.expectEqual(lock.Freshness.stale_target, lock.checkFreshness(&legacy, versioned));

    // serialize/parse でも runtime・version が保存・復元される。
    const bytes = try lock.toBytes(&value, T.allocator);
    defer T.allocator.free(bytes);
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    var parsed = try lock.parse(T.allocator, bytes, &diagnostics);
    defer parsed.deinit();
    try T.expectEqualStrings("lnako", parsed.input.runtime.?);
    try T.expectEqualStrings("3.7.24", parsed.input.nako_version.?);
    try T.expectEqualStrings("0.2.2", parsed.input.lnako_version.?);
}

test "compatJs も target 鮮度鍵として stale_target を検出する" {
    // `run`/`build --compat-js` は ESM 実装の可否を変えるため target の
    // 鮮度鍵。compat 実行で作った lock は非 compat 入力へ stale となり、
    // serialize/parse でも保存・復元される。非 compat lock は compatJs
    // を書かず、欠落は false と同等に扱う。
    const nodes = [_]resolver.PackageNode{
        try node(sqlite_id, "1.2.3", &.{.{ .pkg = req_id }}, &.{"default"}),
        try node(req_id, "2.0.1", &.{}, &.{ "default", "http" }),
    };
    var compat = sampleInput();
    compat.target.compat_js = true;
    var value = try lock.build(T.allocator, compat, &.{default_profile}, &nodes, default_fixtures.details());
    defer value.deinit();

    try T.expectEqual(lock.Freshness.fresh, lock.checkFreshness(&value, compat));
    // compat-js なしの入力は不一致（target 不一致 → stale_target）。
    try T.expectEqual(lock.Freshness.stale_target, lock.checkFreshness(&value, sampleInput()));

    // serialize/parse で compatJs が保存・復元される。
    const bytes = try lock.toBytes(&value, T.allocator);
    defer T.allocator.free(bytes);
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    var parsed = try lock.parse(T.allocator, bytes, &diagnostics);
    defer parsed.deinit();
    try T.expect(parsed.input.target.compat_js);

    // 非 compat lock は compatJs を書かず、旧 lock の欠落は false と
    // 同等に扱われて fresh のまま。
    var plain = try sampleLock(T.allocator);
    defer plain.deinit();
    const plain_bytes = try lock.toBytes(&plain, T.allocator);
    defer T.allocator.free(plain_bytes);
    try T.expect(std.mem.indexOf(u8, plain_bytes, "compatJs") == null);
    try T.expectEqual(lock.Freshness.fresh, lock.checkFreshness(&plain, sampleInput()));
}

test "optimize も target 鮮度鍵として stale_target を検出する" {
    // `build -O3` は optimize-gated artifact の選択を変えるため target
    // の鮮度鍵。O3 で作った lock は O0 の入力へ stale となり、
    // serialize/parse でも保存・復元される。O0 の lock は optimize を
    // 書かず、旧 lock の欠落は O0 と同等に扱う。
    const nodes = [_]resolver.PackageNode{
        try node(sqlite_id, "1.2.3", &.{.{ .pkg = req_id }}, &.{"default"}),
        try node(req_id, "2.0.1", &.{}, &.{ "default", "http" }),
    };
    var optimized = sampleInput();
    optimized.target.optimize = "O3";
    var value = try lock.build(T.allocator, optimized, &.{default_profile}, &nodes, default_fixtures.details());
    defer value.deinit();

    try T.expectEqual(lock.Freshness.fresh, lock.checkFreshness(&value, optimized));
    // 既定 O0 の入力は不一致（target 不一致 → stale_target）。
    try T.expectEqual(lock.Freshness.stale_target, lock.checkFreshness(&value, sampleInput()));

    // serialize/parse で optimize が保存・復元される。
    const bytes = try lock.toBytes(&value, T.allocator);
    defer T.allocator.free(bytes);
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    var parsed = try lock.parse(T.allocator, bytes, &diagnostics);
    defer parsed.deinit();
    try T.expectEqualStrings("O3", parsed.input.target.optimize);

    // O0 の lock は optimize を書かず、旧 lock の欠落は O0 と同等に
    // 扱われて fresh のまま。
    var plain = try sampleLock(T.allocator);
    defer plain.deinit();
    const plain_bytes = try lock.toBytes(&plain, T.allocator);
    defer T.allocator.free(plain_bytes);
    try T.expect(std.mem.indexOf(u8, plain_bytes, "\"optimize\"") == null);
    try T.expectEqual(lock.Freshness.fresh, lock.checkFreshness(&plain, sampleInput()));
}

test "input.target.optimize の既知外の値は拒否する" {
    // schema の enum と同じ既知集合に限定する。未知値を記録した lock を
    // 黙って読むと optimize-gated artifact の選択条件が曖昧になる。
    const text =
        \\{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": { "manifestSha256": "sha256:aa", "profile": "default", "features": [], "target": { "os": "macos", "cpu": "aarch64", "abi": "gnu", "optimize": "Ofast" } },
        \\  "packages": {}
        \\}
    ;
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try T.expectError(error.InvalidLock, lock.parse(T.allocator, text, &diagnostics));
    try T.expect(diagnostics.find(diag.E029_INVALID_VALUE) != null);
}

test "compatJs の非 bool 値は型エラーで拒否する" {
    // `"compatJs": "true"` のような非 bool 値を黙って false へ落とすと、
    // compat 用に作られた lock が非 compat 入力へ fresh と誤判定される。
    const text =
        \\{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": { "manifestSha256": "sha256:aa", "profile": "default", "features": [], "target": { "os": "macos", "cpu": "aarch64", "abi": "gnu", "compatJs": "true" } },
        \\  "packages": {}
        \\}
    ;
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try T.expectError(error.InvalidLock, lock.parse(T.allocator, text, &diagnostics));
    try T.expect(diagnostics.find(diag.E023_INVALID_TYPE) != null);
}

test "features順序と重複は鮮度に影響しない" {
    var value = try sampleLock(T.allocator);
    defer value.deinit();
    var reordered = sampleInput();
    reordered.features = &.{ "http", "default" };
    try T.expectEqual(lock.Freshness.fresh, lock.checkFreshness(&value, reordered));
}

test "--lockedは陳腐化したlockを無変更で失敗させる" {
    var value = try sampleLock(T.allocator);
    defer value.deinit();

    try lock.requireFresh(&value, sampleInput());
    try T.expectError(error.LockedNotSatisfied, lock.requireFresh(null, sampleInput()));

    var changed = sampleInput();
    changed.manifest_sha256 = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    try T.expectError(error.LockedNotSatisfied, lock.requireFresh(&value, changed));
}

// ---------------------------------------------------------------------------
// 既存版優先・部分更新
// ---------------------------------------------------------------------------

const ResolverFixture = struct {
    const Ver = struct {
        version: []const u8,
        has_source: bool = true,
    };
    const Pkg = struct {
        name: []const u8,
        versions: []const Ver,
    };

    pkgs: []const Pkg,
    locked: ?*const lock.LockedIndex = null,

    fn find(self: *const ResolverFixture, name: []const u8) ?*const Pkg {
        for (self.pkgs) |*pkg| {
            if (std.mem.eql(u8, pkg.name, name)) return pkg;
        }
        return null;
    }

    fn listVersions(context: *anyopaque, gpa: std.mem.Allocator, id: resolver.PackageId) anyerror![]const Version {
        const self: *const ResolverFixture = @ptrCast(@alignCast(@constCast(context)));
        const name = switch (id) {
            .pkg => |value| value,
            .npm => |value| value.name,
        };
        const pkg = self.find(name) orelse return error.PackageNotFound;
        const out = try gpa.alloc(Version, pkg.versions.len);
        for (pkg.versions, 0..) |ver, index| out[index] = try Version.parse(ver.version);
        return out;
    }

    fn versionMeta(context: *anyopaque, gpa: std.mem.Allocator, id: resolver.PackageId, version: Version) anyerror!resolver.VersionMeta {
        _ = gpa;
        const self: *const ResolverFixture = @ptrCast(@alignCast(@constCast(context)));
        const name = switch (id) {
            .pkg => |value| value,
            .npm => |value| value.name,
        };
        const pkg = self.find(name) orelse return error.PackageNotFound;
        for (pkg.versions) |ver| {
            const parsed = try Version.parse(ver.version);
            if (Version.cmp(parsed, version) == .eq) {
                return .{ .has_source = ver.has_source, .has_native = false, .has_esm = false };
            }
        }
        return error.PackageNotFound;
    }

    fn lockedVersion(context: *anyopaque, id: resolver.PackageId) ?Version {
        const self: *const ResolverFixture = @ptrCast(@alignCast(@constCast(context)));
        const index = self.locked orelse return null;
        return index.get(id);
    }

    fn source(self: *const ResolverFixture) resolver.Provider {
        return .{
            .ptr = @ptrCast(@constCast(self)),
            .vtable = &.{
                .listVersions = listVersions,
                .versionMeta = versionMeta,
                .lockedVersion = lockedVersion,
            },
        };
    }
};

fn packageDependency(gpa: std.mem.Allocator, name: []const u8, range: []const u8) !resolver.Dependency {
    const parsed = try semver.Range.parse(gpa, range);
    return .{
        .id = .{ .pkg = name },
        .constraint = try resolver.rangeFromSemver(gpa, parsed),
        .name = name,
        .semver_range = parsed,
    };
}

fn resolvedVersion(resolution: *const resolver.Resolution, name: []const u8) ?Version {
    switch (resolution.result) {
        .resolved => |nodes| {
            for (nodes) |package| {
                switch (package.id) {
                    .pkg => |pkg_name| {
                        if (std.mem.eql(u8, pkg_name, name)) return package.version;
                    },
                    .npm => {},
                }
            }
        },
        else => {},
    }
    return null;
}

test "既存lock版を優先しupdate指定対象だけ固定を解除する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const scope = arena.allocator();
    const fixture = ResolverFixture{ .pkgs = &.{
        .{ .name = "a", .versions = &.{ .{ .version = "1.0.0" }, .{ .version = "1.1.0" } } },
    } };
    const fixtures = Fixtures{ .entries = &.{
        .{ .id = "a", .name = "a", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
    } };

    const root_deps = [_]resolver.Dependency{try packageDependency(scope, "a", "^1.0.0")};

    const existing_nodes = [_]resolver.PackageNode{try node("a", "1.0.0", &.{}, &.{"default"})};
    var existing = try lock.build(scope, sampleInput(), &.{}, &existing_nodes, fixtures.details());
    defer existing.deinit();

    var keep_index = try lock.buildLockedIndex(scope, &existing, "default", &.{});
    defer keep_index.deinit();
    var keeping = ResolverFixture{ .pkgs = fixture.pkgs, .locked = &keep_index };
    const keep_provider = keeping.source();
    var keep_resolution = try resolver.resolve(scope, keep_provider, &root_deps, .{});
    defer keep_resolution.deinit();
    try T.expect(Version.cmp(resolvedVersion(&keep_resolution, "a").?, try Version.parse("1.0.0")) == .eq);

    var update_index = try lock.buildLockedIndex(scope, &existing, "default", &.{"a"});
    defer update_index.deinit();
    try T.expect(update_index.isUnlocked("a"));
    try T.expectEqual(@as(?Version, null), update_index.get(.{ .pkg = "a" }));

    var updating = ResolverFixture{ .pkgs = fixture.pkgs, .locked = &update_index };
    const update_provider = updating.source();
    var update_resolution = try resolver.resolve(scope, update_provider, &root_deps, .{});
    defer update_resolution.deinit();
    try T.expect(Version.cmp(resolvedVersion(&update_resolution, "a").?, try Version.parse("1.1.0")) == .eq);
}

test "差分は直接・間接・追加・削除の理由を説明する" {
    const scope = T.allocator;
    var previous = try sampleLock(scope);
    defer previous.deinit();

    // req の版を上げ、newdep を追加し、sqlite を更新対象にする。
    const nodes = [_]resolver.PackageNode{
        try node(sqlite_id, "1.2.4", &.{ .{ .pkg = req_id }, .{ .pkg = "pkg:30000000000000000000000000000000" } }, &.{"default"}),
        try node(req_id, "2.0.2", &.{}, &.{ "default", "http" }),
        try node("pkg:30000000000000000000000000000000", "0.1.0", &.{}, &.{"default"}),
    };
    const extra = FixtureEntry{ .id = "pkg:30000000000000000000000000000000", .name = "newdep", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} };
    const fixtures = Fixtures{ .entries = &.{ default_fixtures.entries[0], default_fixtures.entries[1], extra } };
    var next = try lock.build(scope, sampleInput(), &.{default_profile}, &nodes, fixtures.details());
    defer next.deinit();

    var report = try lock.diff(scope, &previous, &next, "default", &.{"sqlite"});
    defer report.deinit();

    const sqlite_change = report.find(sqlite_id).?;
    try T.expectEqual(lock.ChangeReason.updated_direct, sqlite_change.reason);
    try T.expectEqualStrings("1.2.3", sqlite_change.from_version.?);
    try T.expectEqualStrings("1.2.4", sqlite_change.to_version.?);

    const req_change = report.find(req_id).?;
    try T.expectEqual(lock.ChangeReason.updated_indirect, req_change.reason);
    try T.expect(req_change.caused_by.len >= 1);
    try T.expectEqualStrings(sqlite_id, req_change.caused_by[0]);

    const added_change = report.find("pkg:30000000000000000000000000000000").?;
    try T.expectEqual(lock.ChangeReason.added, added_change.reason);
}

test "削除されたpackageを差分で説明する" {
    const scope = T.allocator;
    var previous = try sampleLock(scope);
    defer previous.deinit();

    const nodes = [_]resolver.PackageNode{try node(sqlite_id, "1.2.3", &.{}, &.{"default"})};
    const fixtures = Fixtures{ .entries = &.{default_fixtures.entries[0]} };
    var next = try lock.build(scope, sampleInput(), &.{default_profile}, &nodes, fixtures.details());
    defer next.deinit();

    var report = try lock.diff(scope, &previous, &next, "default", &.{});
    defer report.deinit();
    const removed = report.find(req_id).?;
    try T.expectEqual(lock.ChangeReason.removed, removed.reason);
}

// ---------------------------------------------------------------------------
// 複数 profile
// ---------------------------------------------------------------------------

test "複数profileを一つのlockに集約し排他的な版差を許す" {
    const scope = T.allocator;
    const lnako_profile = lock.NamedProfile{
        .name = "lnako-aarch64",
        .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu", .compat_js = false },
    };
    const cnako_profile = lock.NamedProfile{
        .name = "cnako-x86_64",
        .record = .{ .runtime = "cnako", .os = "linux", .cpu = "x86_64", .abi = "gnu" },
    };

    const lnako_nodes = [_]resolver.PackageNode{try node(sqlite_id, "1.2.3", &.{}, &.{"default"})};
    const cnako_nodes = [_]resolver.PackageNode{try node(sqlite_id, "1.2.4", &.{}, &.{"default"})};

    const fixtures = Fixtures{ .entries = &.{
        .{ .id = sqlite_id, .name = sqlite_name, .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
    } };

    var input = sampleInput();
    input.profile = "lnako-aarch64";
    var value = try lock.buildMulti(scope, input, &.{ lnako_profile, cnako_profile }, &.{
        .{ .profile = "lnako-aarch64", .nodes = &lnako_nodes },
        .{ .profile = "cnako-x86_64", .nodes = &cnako_nodes },
    }, fixtures.details());
    defer value.deinit();

    try T.expectEqual(@as(usize, 2), value.profile_packages.len);
    try T.expectEqualStrings("1.2.3", value.packagesForProfile("lnako-aarch64").?[0].version);
    try T.expectEqualStrings("1.2.4", value.packagesForProfile("cnako-x86_64").?[0].version);
    try T.expect(lock.sharedArtifactMismatch(&value) == null);

    const bytes = try lock.toBytes(&value, scope);
    defer scope.free(bytes);
    try T.expect(std.mem.indexOf(u8, bytes, "\"profilePackages\"") != null);
}

test "同一id/版のsource artifact hash不一致を検出する" {
    const mismatch_artifact = lock.Artifact{
        .key = "source",
        .kind = "source",
        .type = "tar.gz",
        .sha256 = "sha256:9999999999999999999999999999999999999999999999999999999999999999",
        .url = "https://registry.example.com/pkg/sqlite/v1.2.3/source.tar.gz",
    };
    const consistent_entries = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.2.3", .source = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
    };
    const mismatched_entries = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.2.3", .source = sqlite_source, .artifacts = &.{mismatch_artifact} },
    };
    const consistent_packages = [_]lock.ProfilePackages{
        .{ .profile = "lnako", .packages = &consistent_entries },
        .{ .profile = "cnako", .packages = &consistent_entries },
    };
    const mismatched_packages = [_]lock.ProfilePackages{
        .{ .profile = "lnako", .packages = &consistent_entries },
        .{ .profile = "cnako", .packages = &mismatched_entries },
    };

    var consistent = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &consistent_entries,
        .profile_packages = &consistent_packages,
    };
    defer consistent.deinit();
    try T.expect(lock.sharedArtifactMismatch(&consistent) == null);

    var mismatched = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &consistent_entries,
        .profile_packages = &mismatched_packages,
    };
    defer mismatched.deinit();
    const found = lock.sharedArtifactMismatch(&mismatched).?;
    try T.expectEqualStrings(sqlite_id, found.id);
    try T.expectEqualStrings("1.2.3", found.version);
}

test "未知profileのprofilePackagesをE030で拒否する" {
    const text =
        \\{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": { "manifestSha256": "sha256:aa", "profile": "default", "features": [], "target": { "os": "macos", "cpu": "aarch64", "abi": "gnu" } },
        \\  "packages": {},
        \\  "profiles": { "default": { "os": "macos", "cpu": "aarch64", "abi": "gnu" } },
        \\  "profilePackages": { "ghost": {} }
        \\}
    ;
    var value = try parseValid(text);
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E030_UNKNOWN_PROFILE) != null);
}

// ---------------------------------------------------------------------------
// hash
// ---------------------------------------------------------------------------

test "lockのsha256は同一入力で一致する" {
    var first = try sampleLock(T.allocator);
    defer first.deinit();
    var second = try sampleLock(T.allocator);
    defer second.deinit();

    const first_hash = try lock.sha256Hex(&first, T.allocator);
    defer T.allocator.free(first_hash);
    const second_hash = try lock.sha256Hex(&second, T.allocator);
    defer T.allocator.free(second_hash);
    try T.expectEqualStrings(first_hash, second_hash);
    try T.expectEqual(@as(usize, 64), first_hash.len);
}

test "選択された実装をlockへ記録し往復で保持する" {
    const nodes = [_]resolver.PackageNode{
        .{ .id = .{ .pkg = sqlite_id }, .version = try Version.parse("1.2.3"), .features = &.{"default"}, .implementation = .source, .prefer_native = false, .dependencies = &.{} },
        .{ .id = .{ .pkg = req_id }, .version = try Version.parse("2.0.1"), .features = &.{"default"}, .implementation = .native, .prefer_native = true, .dependencies = &.{} },
    };
    var value = try lock.build(T.allocator, sampleInput(), &.{default_profile}, &nodes, default_fixtures.details());
    defer value.deinit();
    try T.expectEqualStrings("source", value.packageById(sqlite_id).?.implementation.?);
    try T.expectEqualStrings("native", value.packageById(req_id).?.implementation.?);

    const bytes = try lock.toBytes(&value, T.allocator);
    defer T.allocator.free(bytes);
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    var parsed = try lock.parse(T.allocator, bytes, &diagnostics);
    defer parsed.deinit();
    try T.expectEqualStrings("native", parsed.packageById(req_id).?.implementation.?);
}

test "resolverVersion不一致は鮮度判定で検出する" {
    var value = try sampleLock(T.allocator);
    defer value.deinit();
    value.resolver_version = 2;
    try T.expectEqual(lock.Freshness.stale_resolver, lock.checkFreshness(&value, sampleInput()));
}

test "pathソースはimmutableを既定としてlockへ記録する" {
    const local_id = "pkg:50000000000000000000000000000000";
    const local_source = lock.Source{ .kind = .path, .path = "../local" };
    const fixtures = Fixtures{ .entries = &.{
        .{ .id = local_id, .name = "local", .source = local_source, .resolved_from = local_source, .artifacts = &.{sqlite_source_artifact} },
    } };
    const nodes = [_]resolver.PackageNode{try node(local_id, "0.1.0", &.{}, &.{"default"})};
    var value = try lock.build(T.allocator, sampleInput(), &.{default_profile}, &nodes, fixtures.details());
    defer value.deinit();
    const bytes = try lock.toBytes(&value, T.allocator);
    defer T.allocator.free(bytes);
    try T.expect(std.mem.indexOf(u8, bytes, "\"mutable\": false") != null);
}

test "npmInstancesのpeer依存順序を正規化して決定化する" {
    const npm_instances = [_]lock.NpmInstance{
        .{ .key = "chalk@5.0.0", .name = "chalk", .version = "5.0.0", .peer_dependencies = &.{
            .{ .name = "zlib", .requirement = "^1.0.0" },
            .{ .name = "ansi", .requirement = "^2.0.0" },
        } },
    };
    const fixtures = Fixtures{ .entries = &.{
        .{ .id = sqlite_id, .name = sqlite_name, .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact}, .npm_instances = &npm_instances },
    } };
    const nodes = [_]resolver.PackageNode{try node(sqlite_id, "1.2.3", &.{}, &.{"default"})};
    var value = try lock.build(T.allocator, sampleInput(), &.{default_profile}, &nodes, fixtures.details());
    defer value.deinit();
    const bytes = try lock.toBytes(&value, T.allocator);
    defer T.allocator.free(bytes);
    const ansi = std.mem.indexOf(u8, bytes, "\"ansi\"").?;
    const zlib = std.mem.indexOf(u8, bytes, "\"zlib\"").?;
    try T.expect(ansi < zlib);

    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    var parsed = try lock.parse(T.allocator, bytes, &diagnostics);
    defer parsed.deinit();
    const again = try lock.toBytes(&parsed, T.allocator);
    defer T.allocator.free(again);
    try T.expectEqualStrings(bytes, again);
}

test "featuresの重複を無視して鮮度比較する" {
    var value = try sampleLock(T.allocator);
    defer value.deinit();
    value.input.features = &.{ "default", "default", "http" };
    try T.expectEqual(lock.Freshness.fresh, lock.checkFreshness(&value, sampleInput()));
}

test "validateはprofile間source hash不一致をE009で検出する" {
    const mismatch_artifact = lock.Artifact{
        .key = "source",
        .kind = "source",
        .type = "tar.gz",
        .sha256 = "sha256:9999999999999999999999999999999999999999999999999999999999999999",
        .url = "https://registry.example.com/pkg/sqlite/v1.2.3/source.tar.gz",
    };
    const entries = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.2.3", .source = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
    };
    const mismatched = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.2.3", .source = sqlite_source, .artifacts = &.{mismatch_artifact} },
    };
    const profile_packages = [_]lock.ProfilePackages{
        .{ .profile = "default", .packages = &entries },
        .{ .profile = "alt", .packages = &mismatched },
    };
    const profiles = [_]lock.NamedProfile{
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
        .{ .name = "alt", .record = .{ .runtime = "lnako", .os = "linux", .cpu = "x86_64", .abi = "gnu" } },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &entries,
        .profiles = &profiles,
        .profile_packages = &profile_packages,
    };
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E009_HASH_MISMATCH) != null);
}

test "validateはpackagesとprofilePackagesの不一致をE029で検出する" {
    const selected = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.0.0", .source = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
    };
    const divergent = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.0.1", .source = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
    };
    const profile_packages = [_]lock.ProfilePackages{.{ .profile = "default", .packages = &divergent }};
    const profiles = [_]lock.NamedProfile{
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &selected,
        .profiles = &profiles,
        .profile_packages = &profile_packages,
    };
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E029_INVALID_VALUE) != null);
}

test "source種別ごとの必須フィールド欠落をE019で拒否する" {
    const text = try lockWithPackages(
        \\    "pkg:10000000000000000000000000000000": {
        \\      "id": "pkg:10000000000000000000000000000000",
        \\      "name": "test",
        \\      "version": "1.0.0",
        \\      "source": { "type": "registry" },
        \\      "dependencies": [],
        \\      "artifacts": { "native": { "kind": "native", "type": ".npkg", "sha256": "sha256:00", "url": "https://ex/native.npkg" } }
        \\    }
    , "\"os\": \"macos\", \"cpu\": \"aarch64\", \"abi\": \"gnu\"");
    defer T.allocator.free(text);
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try T.expectError(error.InvalidLock, lock.parse(T.allocator, text, &diagnostics));
    try T.expect(diagnostics.find(diag.E019_REQUIRED_FIELD_MISSING) != null);
}

test "未知のsourceフィールドをE022で拒否する" {
    const text = try lockWithPackages(
        \\    "pkg:10000000000000000000000000000000": {
        \\      "id": "pkg:10000000000000000000000000000000",
        \\      "name": "test",
        \\      "version": "1.0.0",
        \\      "source": { "type": "registry", "url": "https://ex/pkg", "extra": true },
        \\      "dependencies": [],
        \\      "artifacts": { "native": { "kind": "native", "type": ".npkg", "sha256": "sha256:00", "url": "https://ex/native.npkg" } }
        \\    }
    , "\"os\": \"macos\", \"cpu\": \"aarch64\", \"abi\": \"gnu\"");
    defer T.allocator.free(text);
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try T.expectError(error.InvalidLock, lock.parse(T.allocator, text, &diagnostics));
    try T.expect(diagnostics.find(diag.E022_UNKNOWN_FIELD) != null);
}

test "implementationの未知値をE029で拒否する" {
    const text = try lockWithPackages(
        \\    "pkg:10000000000000000000000000000000": {
        \\      "id": "pkg:10000000000000000000000000000000",
        \\      "name": "test",
        \\      "version": "1.0.0",
        \\      "dependencies": [],
        \\      "implementation": "jit",
        \\      "artifacts": { "native": { "kind": "native", "type": ".npkg", "sha256": "sha256:00", "url": "https://ex/native.npkg" } }
        \\    }
    , "\"os\": \"macos\", \"cpu\": \"aarch64\", \"abi\": \"gnu\"");
    defer T.allocator.free(text);
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try T.expectError(error.InvalidLock, lock.parse(T.allocator, text, &diagnostics));
    try T.expect(diagnostics.find(diag.E029_INVALID_VALUE) != null);
}

test "既存版優先はpublic idとpackage名の両方で引ける" {
    const lib_source = lock.Source{ .kind = .registry, .url = "https://registry.example.com/pkg/lib" };
    const fixtures = Fixtures{ .entries = &.{
        .{ .id = "lib", .public_id = "pkg:60000000000000000000000000000000", .name = "lib", .source = lib_source, .resolved_from = lib_source, .artifacts = &.{sqlite_source_artifact} },
    } };
    const nodes = [_]resolver.PackageNode{try node("lib", "1.0.0", &.{}, &.{"default"})};
    var existing = try lock.build(T.allocator, sampleInput(), &.{default_profile}, &nodes, fixtures.details());
    defer existing.deinit();

    var index = try lock.buildLockedIndex(T.allocator, &existing, "default", &.{});
    defer index.deinit();
    try T.expect(index.get(.{ .pkg = "pkg:60000000000000000000000000000000" }) != null);
    try T.expect(index.get(.{ .pkg = "lib" }) != null);
}

test "profile指定で該当グラフの既存版を優先固定する" {
    const macos_entries = [_]lock.PackageEntry{
        .{ .id = "a", .name = "a", .version = "1.0.0", .artifacts = &.{sqlite_source_artifact} },
    };
    const linux_entries = [_]lock.PackageEntry{
        .{ .id = "a", .name = "a", .version = "1.1.0", .artifacts = &.{sqlite_source_artifact} },
    };
    const profile_packages = [_]lock.ProfilePackages{
        .{ .profile = "macos", .packages = &macos_entries },
        .{ .profile = "linux", .packages = &linux_entries },
    };
    const profiles = [_]lock.NamedProfile{
        .{ .name = "macos", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
        .{ .name = "linux", .record = .{ .runtime = "lnako", .os = "linux", .cpu = "x86_64", .abi = "gnu" } },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &macos_entries,
        .profiles = &profiles,
        .profile_packages = &profile_packages,
    };
    defer value.deinit();

    var macos_index = try lock.buildLockedIndex(T.allocator, &value, "macos", &.{});
    defer macos_index.deinit();
    try T.expect(Version.cmp(macos_index.get(.{ .pkg = "a" }).?, try Version.parse("1.0.0")) == .eq);

    var linux_index = try lock.buildLockedIndex(T.allocator, &value, "linux", &.{});
    defer linux_index.deinit();
    try T.expect(Version.cmp(linux_index.get(.{ .pkg = "a" }).?, try Version.parse("1.1.0")) == .eq);
}

const versioned_a = lock.Artifact{
    .key = "source",
    .kind = "source",
    .type = "tar.gz",
    .sha256 = "sha256:aaaa000000000000000000000000000000000000000000000000000000000000",
    .url = "https://registry.example.com/pkg/sqlite/v1.2.3/source.tar.gz",
};
const versioned_b = lock.Artifact{
    .key = "source",
    .kind = "source",
    .type = "tar.gz",
    .sha256 = "sha256:bbbb000000000000000000000000000000000000000000000000000000000000",
    .url = "https://registry.example.com/pkg/sqlite/v1.2.4/source.tar.gz",
};

const VersionedFixtures = struct {
    fn get(_: *anyopaque, gpa: std.mem.Allocator, id: []const u8, version: []const u8) anyerror!?lock.PackageDetails {
        _ = gpa;
        const source = lock.Source{ .kind = .registry, .url = "https://registry.example.com/pkg/sqlite" };
        if (std.mem.eql(u8, version, "1.2.3")) {
            return .{ .public_id = id, .name = sqlite_name, .source = source, .resolved_from = source, .artifacts = &.{versioned_a} };
        }
        if (std.mem.eql(u8, version, "1.2.4")) {
            return .{ .public_id = id, .name = sqlite_name, .source = source, .resolved_from = source, .artifacts = &.{versioned_b} };
        }
        return null;
    }
};

test "排他的profileの版ごとに異なるartifactを記録する" {
    const lnako_profile = lock.NamedProfile{
        .name = "lnako",
        .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" },
    };
    const cnako_profile = lock.NamedProfile{
        .name = "cnako",
        .record = .{ .runtime = "cnako", .os = "linux", .cpu = "x86_64", .abi = "gnu" },
    };
    const lnako_nodes = [_]resolver.PackageNode{try node(sqlite_id, "1.2.3", &.{}, &.{"default"})};
    const cnako_nodes = [_]resolver.PackageNode{try node(sqlite_id, "1.2.4", &.{}, &.{"default"})};
    var dummy: u8 = 0;
    const details = lock.DetailsSource{ .context = @ptrCast(&dummy), .getFn = VersionedFixtures.get };

    var input = sampleInput();
    input.profile = "lnako";
    var value = try lock.buildMulti(T.allocator, input, &.{ lnako_profile, cnako_profile }, &.{
        .{ .profile = "lnako", .nodes = &lnako_nodes },
        .{ .profile = "cnako", .nodes = &cnako_nodes },
    }, details);
    defer value.deinit();

    try T.expectEqualStrings(versioned_a.url.?, value.packagesForProfile("lnako").?[0].artifact("source").?.url.?);
    try T.expectEqualStrings(versioned_b.url.?, value.packagesForProfile("cnako").?[0].artifact("source").?.url.?);
}

test "UpdateReportは元lockの解放後も独立して使える" {
    const nodes = [_]resolver.PackageNode{
        try node(sqlite_id, "1.2.4", &.{.{ .pkg = req_id }}, &.{"default"}),
        try node(req_id, "2.0.2", &.{}, &.{ "default", "http" }),
    };
    var previous = try sampleLock(T.allocator);
    var next = try lock.build(T.allocator, sampleInput(), &.{default_profile}, &nodes, default_fixtures.details());

    var report = try lock.diff(T.allocator, &previous, &next, "default", &.{"sqlite"});
    previous.deinit();
    next.deinit();
    defer report.deinit();

    const change = report.find(sqlite_id).?;
    try T.expectEqualStrings(sqlite_name, change.name);
    try T.expectEqualStrings("1.2.3", change.from_version.?);
    var rendered: std.Io.Writer.Allocating = .init(T.allocator);
    defer rendered.deinit();
    try report.explain(&rendered.writer);
    try T.expect(rendered.written().len > 0);
}

test "version不変でもfeature統合の変化を差分で報告する" {
    var previous = try sampleLock(T.allocator);
    defer previous.deinit();
    const nodes = [_]resolver.PackageNode{
        try node(sqlite_id, "1.2.3", &.{.{ .pkg = req_id }}, &.{"default"}),
        try node(req_id, "2.0.1", &.{}, &.{"default"}),
    };
    var next = try lock.build(T.allocator, sampleInput(), &.{default_profile}, &nodes, default_fixtures.details());
    defer next.deinit();

    var report = try lock.diff(T.allocator, &previous, &next, "default", &.{});
    defer report.deinit();
    const change = report.find(req_id).?;
    try T.expectEqual(lock.ChangeReason.updated_indirect, change.reason);
    try T.expectEqualStrings("2.0.1", change.from_version.?);
    try T.expectEqualStrings("2.0.1", change.to_version.?);
}

test "buildMultiは主profileの欠落と重複を拒否する" {
    const profiles = [_]lock.NamedProfile{
        .{ .name = "macos", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
        .{ .name = "linux", .record = .{ .runtime = "lnako", .os = "linux", .cpu = "x86_64", .abi = "gnu" } },
    };
    const nodes = [_]resolver.PackageNode{try node(sqlite_id, "1.2.3", &.{}, &.{"default"})};
    var input = sampleInput();
    input.profile = "linux";

    try T.expectError(error.InvalidPrimaryProfile, lock.buildMulti(T.allocator, input, &profiles, &.{
        .{ .profile = "macos", .nodes = &nodes },
    }, default_fixtures.details()));

    try T.expectError(error.InvalidPrimaryProfile, lock.buildMulti(T.allocator, input, &profiles, &.{
        .{ .profile = "macos", .nodes = &nodes },
        .{ .profile = "linux", .nodes = &nodes },
        .{ .profile = "linux", .nodes = &nodes },
    }, default_fixtures.details()));
}

test "buildMultiはprofile集合の不一致を拒否する" {
    const profiles = [_]lock.NamedProfile{
        .{ .name = "lnako", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
        .{ .name = "cnako", .record = .{ .runtime = "cnako", .os = "linux", .cpu = "x86_64", .abi = "gnu" } },
    };
    const nodes = [_]resolver.PackageNode{try node(sqlite_id, "1.2.3", &.{}, &.{"default"})};
    var input = sampleInput();
    input.profile = "lnako";

    // 他 profile の欠落。
    try T.expectError(error.InvalidProfileSet, lock.buildMulti(T.allocator, input, &profiles, &.{
        .{ .profile = "lnako", .nodes = &nodes },
    }, default_fixtures.details()));
    // 他 profile の重複。
    try T.expectError(error.InvalidProfileSet, lock.buildMulti(T.allocator, input, &profiles, &.{
        .{ .profile = "lnako", .nodes = &nodes },
        .{ .profile = "cnako", .nodes = &nodes },
        .{ .profile = "cnako", .nodes = &nodes },
    }, default_fixtures.details()));
    // profiles に無い名前。
    try T.expectError(error.InvalidProfileSet, lock.buildMulti(T.allocator, input, &profiles, &.{
        .{ .profile = "lnako", .nodes = &nodes },
        .{ .profile = "other", .nodes = &nodes },
    }, default_fixtures.details()));
}

test "validateはprofileとprofilePackagesの重複をE029で拒否する" {
    const entries = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.0.0", .artifacts = &.{sqlite_source_artifact} },
    };
    const duplicate_profiles = [_]lock.NamedProfile{
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
    };
    const duplicate_packages = [_]lock.ProfilePackages{
        .{ .profile = "default", .packages = &entries },
        .{ .profile = "default", .packages = &entries },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &entries,
        .profiles = &duplicate_profiles,
        .profile_packages = &duplicate_packages,
    };
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E029_INVALID_VALUE) != null);
}

test "間接更新の原因は未変更の中間packageを越えて辿る" {
    const a_id = "pkg:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const b_id = "pkg:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const c_id = "pkg:cccccccccccccccccccccccccccccccc";
    const fixtures = Fixtures{ .entries = &.{
        .{ .id = a_id, .name = "a", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
        .{ .id = b_id, .name = "b", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
        .{ .id = c_id, .name = "c", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
    } };

    const prev_nodes = [_]resolver.PackageNode{
        try node(a_id, "1.0.0", &.{.{ .pkg = b_id }}, &.{"default"}),
        try node(b_id, "1.0.0", &.{.{ .pkg = c_id }}, &.{"default"}),
        try node(c_id, "1.0.0", &.{}, &.{"default"}),
    };
    const next_nodes = [_]resolver.PackageNode{
        try node(a_id, "1.1.0", &.{.{ .pkg = b_id }}, &.{"default"}),
        try node(b_id, "1.0.0", &.{.{ .pkg = c_id }}, &.{"default"}),
        try node(c_id, "2.0.0", &.{}, &.{"default"}),
    };

    var previous = try lock.build(T.allocator, sampleInput(), &.{default_profile}, &prev_nodes, fixtures.details());
    defer previous.deinit();
    var next = try lock.build(T.allocator, sampleInput(), &.{default_profile}, &next_nodes, fixtures.details());
    defer next.deinit();

    var report = try lock.diff(T.allocator, &previous, &next, "default", &.{"a"});
    defer report.deinit();

    try T.expectEqual(lock.ChangeReason.updated_direct, report.find(a_id).?.reason);
    try T.expectEqual(lock.ChangeReason.unchanged, report.find(b_id).?.reason);
    const c_change = report.find(c_id).?;
    try T.expectEqual(lock.ChangeReason.updated_indirect, c_change.reason);
    try T.expectEqual(@as(usize, 1), c_change.caused_by.len);
    try T.expectEqualStrings(a_id, c_change.caused_by[0]);
}

test "切れた旧依存経路を間接更新の原因に使わない" {
    const a_id = "pkg:a1000000000000000000000000000000";
    const b_id = "pkg:b1000000000000000000000000000000";
    const c_id = "pkg:c1000000000000000000000000000000";
    const d_id = "pkg:d1000000000000000000000000000000";
    const x_id = "pkg:e1000000000000000000000000000000";
    const fixtures = Fixtures{ .entries = &.{
        .{ .id = a_id, .name = "a", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
        .{ .id = b_id, .name = "b", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
        .{ .id = c_id, .name = "c", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
        .{ .id = d_id, .name = "d", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
        .{ .id = x_id, .name = "x", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
    } };

    // 旧: A -> B -> C / X -> B -> C
    // 新: A -> D / X -> B -> C（A->B は切れている）
    const prev_nodes = [_]resolver.PackageNode{
        try node(a_id, "1.0.0", &.{.{ .pkg = b_id }}, &.{"default"}),
        try node(x_id, "1.0.0", &.{.{ .pkg = b_id }}, &.{"default"}),
        try node(b_id, "1.0.0", &.{.{ .pkg = c_id }}, &.{"default"}),
        try node(c_id, "1.0.0", &.{}, &.{"default"}),
    };
    const next_nodes = [_]resolver.PackageNode{
        try node(a_id, "1.1.0", &.{.{ .pkg = d_id }}, &.{"default"}),
        try node(x_id, "1.0.0", &.{.{ .pkg = b_id }}, &.{"default"}),
        try node(b_id, "1.0.0", &.{.{ .pkg = c_id }}, &.{"default"}),
        try node(c_id, "2.0.0", &.{}, &.{"default"}),
        try node(d_id, "1.0.0", &.{}, &.{"default"}),
    };

    var previous = try lock.build(T.allocator, sampleInput(), &.{default_profile}, &prev_nodes, fixtures.details());
    defer previous.deinit();
    var next = try lock.build(T.allocator, sampleInput(), &.{default_profile}, &next_nodes, fixtures.details());
    defer next.deinit();

    var report = try lock.diff(T.allocator, &previous, &next, "default", &.{"a"});
    defer report.deinit();

    try T.expectEqual(lock.ChangeReason.updated_direct, report.find(a_id).?.reason);
    const c_change = report.find(c_id).?;
    try T.expectEqual(lock.ChangeReason.updated_indirect, c_change.reason);
    // 新グラフで C へ至る経路は X -> B -> C のみで、A は切れている。
    try T.expectEqual(@as(usize, 0), c_change.caused_by.len);
}

test "profilePackagesの欠落profileをE029で拒否する" {
    const entries = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.0.0", .artifacts = &.{sqlite_source_artifact} },
    };
    const profiles = [_]lock.NamedProfile{
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
        .{ .name = "windows", .record = .{ .runtime = "lnako", .os = "windows", .cpu = "x86_64", .abi = "msvc" } },
    };
    const profile_packages = [_]lock.ProfilePackages{
        .{ .profile = "default", .packages = &entries },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &entries,
        .profiles = &profiles,
        .profile_packages = &profile_packages,
    };
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E029_INVALID_VALUE) != null);
}

test "定義済みinput profileのprofilePackages欠落はE029のみ" {
    const default_entries = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.0.0", .artifacts = &.{sqlite_source_artifact} },
    };
    const windows_entries = [_]lock.PackageEntry{
        .{ .id = req_id, .name = req_name, .version = "2.0.1", .artifacts = &.{req_source_artifact} },
    };
    const profiles = [_]lock.NamedProfile{
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
        .{ .name = "windows", .record = .{ .runtime = "lnako", .os = "windows", .cpu = "x86_64", .abi = "msvc" } },
    };
    // input.profile = "default" は profiles に定義済みだが profilePackages に無い。
    const profile_packages = [_]lock.ProfilePackages{
        .{ .profile = "windows", .packages = &windows_entries },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &default_entries,
        .profiles = &profiles,
        .profile_packages = &profile_packages,
    };
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E029_INVALID_VALUE) != null);
    try T.expect(diagnostics.find(diag.E030_UNKNOWN_PROFILE) == null);
}

test "不正なprofile optimizeをE029で拒否する" {
    const entries = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.0.0", .artifacts = &.{sqlite_source_artifact} },
    };
    const profiles = [_]lock.NamedProfile{
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu", .optimize = "O9" } },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &entries,
        .profiles = &profiles,
    };
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E029_INVALID_VALUE) != null);
    try T.expect(diagnostics.find(diag.E014_INVALID_PROFILE) == null);
}

test "選択実装に対応するartifactの欠落をE008で拒否する" {
    const source_only = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.0.0", .implementation = "native", .artifacts = &.{sqlite_source_artifact} },
    };
    const profiles = [_]lock.NamedProfile{
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &source_only,
        .profiles = &profiles,
    };
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E008_MISSING_ARTIFACT) != null);

    const matching = [_]lock.PackageEntry{
        .{ .id = sqlite_id, .name = sqlite_name, .version = "1.0.0", .implementation = "source", .artifacts = &.{sqlite_source_artifact} },
    };
    var ok_value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &matching,
        .profiles = &profiles,
    };
    defer ok_value.deinit();
    var ok_diagnostics = diag.List.init(T.allocator);
    defer ok_diagnostics.deinit();
    try lock.validate(&ok_value, &ok_diagnostics);
    try T.expect(ok_diagnostics.find(diag.E008_MISSING_ARTIFACT) == null);
}

test "buildPackagesはPublic IDの衝突を拒否する" {
    const shared_public = "pkg:90000000000000000000000000000000";
    const fixtures = Fixtures{ .entries = &.{
        .{ .id = "old", .public_id = shared_public, .name = "old", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
        .{ .id = "new", .public_id = shared_public, .name = "new", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
    } };
    const nodes = [_]resolver.PackageNode{
        try node("old", "1.0.0", &.{}, &.{"default"}),
        try node("new", "1.0.0", &.{}, &.{"default"}),
    };
    try T.expectError(error.DuplicatePublicId, lock.build(T.allocator, sampleInput(), &.{default_profile}, &nodes, fixtures.details()));
}

test "public idがresolver idと異なっても依存辺をpublic idへ張り替える" {
    const a_public = "pkg:70000000000000000000000000000000";
    const b_public = "pkg:80000000000000000000000000000000";
    const fixtures = Fixtures{ .entries = &.{
        .{ .id = "a", .public_id = a_public, .name = "a", .source = sqlite_source, .resolved_from = sqlite_source, .artifacts = &.{sqlite_source_artifact} },
        .{ .id = "b", .public_id = b_public, .name = "b", .source = req_source, .resolved_from = req_source, .artifacts = &.{req_source_artifact} },
    } };
    const nodes = [_]resolver.PackageNode{
        try node("a", "1.0.0", &.{.{ .pkg = "b" }}, &.{"default"}),
        try node("b", "1.0.0", &.{}, &.{"default"}),
    };
    var value = try lock.build(T.allocator, sampleInput(), &.{default_profile}, &nodes, fixtures.details());
    defer value.deinit();

    const entry = value.packageById(a_public).?;
    try T.expectEqual(@as(usize, 1), entry.dependencies.len);
    try T.expectEqualStrings(b_public, entry.dependencies[0]);
    try validateLock(&value);
}

test "profilePackagesに無いprofileへ他profileの版を流用しない" {
    const entries = [_]lock.PackageEntry{
        .{ .id = "a", .name = "a", .version = "1.0.0", .artifacts = &.{sqlite_source_artifact} },
    };
    const profiles = [_]lock.NamedProfile{
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
        .{ .name = "other", .record = .{ .runtime = "cnako", .os = "linux", .cpu = "x86_64", .abi = "gnu" } },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &entries,
        .profiles = &profiles,
    };
    defer value.deinit();
    var index = try lock.buildLockedIndex(T.allocator, &value, "other", &.{});
    defer index.deinit();
    try T.expectEqual(@as(?Version, null), index.get(.{ .pkg = "a" }));
}

test "不正なversionはvalidateでE024となり優先固定も失敗する" {
    const entries = [_]lock.PackageEntry{
        .{ .id = "a", .name = "a", .version = "not-semver", .artifacts = &.{sqlite_source_artifact} },
    };
    const profiles = [_]lock.NamedProfile{
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &entries,
        .profiles = &profiles,
    };
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E024_INVALID_SEMVER) != null);
    try T.expectError(error.InvalidLockVersion, lock.buildLockedIndex(T.allocator, &value, "default", &.{}));
}

test "lock input engine versionsはSemVerとして検証する" {
    const text =
        \\{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": {
        \\    "manifestSha256": "sha256:aa",
        \\    "profile": "default",
        \\    "features": [],
        \\    "target": { "os": "macos", "cpu": "aarch64", "abi": "gnu" },
        \\    "runtime": "lnako",
        \\    "nakoVersion": "invalid",
        \\    "cnakoVersion": "3.7",
        \\    "lnakoVersion": "not-semver"
        \\  },
        \\  "packages": {},
        \\  "profiles": {
        \\    "default": { "runtime": "lnako", "os": "macos", "cpu": "aarch64", "abi": "gnu" }
        \\  }
        \\}
    ;
    var value = try parseValid(text);
    defer value.deinit();
    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expectEqual(@as(usize, 3), diagnostics.errorCount());
    var invalid_fields: usize = 0;
    for (diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, diag.E024_INVALID_SEMVER) and
            (std.mem.eql(u8, item.path, "nako.lock.input.nakoVersion") or
                std.mem.eql(u8, item.path, "nako.lock.input.cnakoVersion") or
                std.mem.eql(u8, item.path, "nako.lock.input.lnakoVersion")))
        {
            invalid_fields += 1;
        }
    }
    try T.expectEqual(@as(usize, 3), invalid_fields);
}

fn multiProfileLock(scope: std.mem.Allocator, cnako_version: []const u8) !lock.Lock {
    const lnako_profile = lock.NamedProfile{
        .name = "lnako",
        .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" },
    };
    const cnako_profile = lock.NamedProfile{
        .name = "cnako",
        .record = .{ .runtime = "cnako", .os = "linux", .cpu = "x86_64", .abi = "gnu" },
    };
    const lnako_nodes = [_]resolver.PackageNode{try node(sqlite_id, "1.2.3", &.{}, &.{"default"})};
    const cnako_nodes = [_]resolver.PackageNode{try node(sqlite_id, cnako_version, &.{}, &.{"default"})};
    var input = sampleInput();
    input.profile = "lnako";
    return lock.buildMulti(scope, input, &.{ lnako_profile, cnako_profile }, &.{
        .{ .profile = "lnako", .nodes = &lnako_nodes },
        .{ .profile = "cnako", .nodes = &cnako_nodes },
    }, default_fixtures.details());
}

test "profile指定の差分は非選択グラフの変更も報告する" {
    var previous = try multiProfileLock(T.allocator, "1.2.3");
    defer previous.deinit();
    var next = try multiProfileLock(T.allocator, "1.2.4");
    defer next.deinit();

    var cnako_report = try lock.diff(T.allocator, &previous, &next, "cnako", &.{});
    defer cnako_report.deinit();
    try T.expectEqual(lock.ChangeReason.updated_indirect, cnako_report.find(sqlite_id).?.reason);

    var lnako_report = try lock.diff(T.allocator, &previous, &next, "lnako", &.{});
    defer lnako_report.deinit();
    try T.expectEqual(lock.ChangeReason.unchanged, lnako_report.find(sqlite_id).?.reason);
}

test "同一digestのhex/SRI表記を不一致としない" {
    const hex_artifact = lock.Artifact{
        .key = "source",
        .kind = "source",
        .type = "tar.gz",
        .sha256 = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        .url = "https://registry.example.com/pkg/empty/v1.0.0/source.tar.gz",
    };
    const sri_artifact = lock.Artifact{
        .key = "source",
        .kind = "source",
        .type = "tar.gz",
        .sha256 = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=",
        .url = "https://registry.example.com/pkg/empty/v1.0.0/source.tar.gz",
    };
    const entries = [_]lock.PackageEntry{
        .{ .id = "a", .name = "a", .version = "1.0.0", .artifacts = &.{hex_artifact} },
    };
    const other_entries = [_]lock.PackageEntry{
        .{ .id = "a", .name = "a", .version = "1.0.0", .artifacts = &.{sri_artifact} },
    };
    const profile_packages = [_]lock.ProfilePackages{
        .{ .profile = "default", .packages = &entries },
        .{ .profile = "alt", .packages = &other_entries },
    };
    const profiles = [_]lock.NamedProfile{
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
        .{ .name = "alt", .record = .{ .runtime = "cnako", .os = "linux", .cpu = "x86_64", .abi = "gnu" } },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &entries,
        .profiles = &profiles,
        .profile_packages = &profile_packages,
    };
    defer value.deinit();
    try T.expect(lock.sharedArtifactMismatch(&value) == null);

    var diagnostics = diag.List.init(T.allocator);
    defer diagnostics.deinit();
    try lock.validate(&value, &diagnostics);
    try T.expect(diagnostics.find(diag.E009_HASH_MISMATCH) == null);
}

test "32バイトへ復号しない不正SRIを未初期化比較に使わない" {
    // 44 文字で終端が '==' の Base64。復号結果は 31 バイトになりうる。
    const malformed = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";
    const entries = [_]lock.PackageEntry{
        .{ .id = "a", .name = "a", .version = "1.0.0", .artifacts = &.{lock.Artifact{ .key = "source", .kind = "source", .type = "tar.gz", .sha256 = malformed, .url = "https://ex/source.tar.gz" }} },
    };
    const other_entries = [_]lock.PackageEntry{
        .{ .id = "a", .name = "a", .version = "1.0.0", .artifacts = &.{lock.Artifact{ .key = "source", .kind = "source", .type = "tar.gz", .sha256 = malformed, .url = "https://ex/source.tar.gz" }} },
    };
    const profile_packages = [_]lock.ProfilePackages{
        .{ .profile = "default", .packages = &entries },
        .{ .profile = "alt", .packages = &other_entries },
    };
    const profiles = [_]lock.NamedProfile{
        .{ .name = "default", .record = .{ .runtime = "lnako", .os = "macos", .cpu = "aarch64", .abi = "gnu" } },
        .{ .name = "alt", .record = .{ .runtime = "cnako", .os = "linux", .cpu = "x86_64", .abi = "gnu" } },
    };
    var value = lock.Lock{
        .arena = std.heap.ArenaAllocator.init(T.allocator),
        .input = sampleInput(),
        .packages = &entries,
        .profiles = &profiles,
        .profile_packages = &profile_packages,
    };
    defer value.deinit();
    // 正規化不能でも生文字列が一致するため不一致とはしない。
    try T.expect(lock.sharedArtifactMismatch(&value) == null);
}

test "feature順序と重複を正規化して同一バイト列にする" {
    const nodes = [_]resolver.PackageNode{
        try node(sqlite_id, "1.2.3", &.{.{ .pkg = req_id }}, &.{"default"}),
        try node(req_id, "2.0.1", &.{}, &.{ "default", "http" }),
    };
    var input_a = sampleInput();
    input_a.features = &.{ "http", "default" };
    var input_b = sampleInput();
    input_b.features = &.{ "default", "default", "http" };

    var first = try lock.build(T.allocator, input_a, &.{default_profile}, &nodes, default_fixtures.details());
    defer first.deinit();
    var second = try lock.build(T.allocator, input_b, &.{default_profile}, &nodes, default_fixtures.details());
    defer second.deinit();

    const first_bytes = try lock.toBytes(&first, T.allocator);
    defer T.allocator.free(first_bytes);
    const second_bytes = try lock.toBytes(&second, T.allocator);
    defer T.allocator.free(second_bytes);
    try T.expectEqualStrings(first_bytes, second_bytes);
}

/// cwd から上方向に conformance lock fixture を持つリポジトリルートを探す。
fn openRepoRoot(io: std.Io) !std.Io.Dir {
    const probe = "tools/package-system/conformance/valid/lock/simple/nako.lock";
    var buffer: [256]u8 = undefined;
    var prefix: []const u8 = ".";
    for (0..8) |_| {
        var candidate = try std.Io.Dir.cwd().openDir(io, prefix, .{});
        if (candidate.openFile(io, probe, .{})) |file| {
            file.close(io);
            return candidate;
        } else |_| {
            candidate.close(io);
        }
        prefix = std.fmt.bufPrint(&buffer, "{s}/..", .{prefix}) catch return error.FileNotFound;
    }
    return error.FileNotFound;
}

test "lock適合fixtureをZig側でも検証する" {
    const allocator = T.allocator;
    var repo = try openRepoRoot(T.io);
    defer repo.close(T.io);
    const cases = [_]struct { path: []const u8, expected: ?[]const u8 }{
        .{ .path = "tools/package-system/conformance/valid/lock/simple/nako.lock", .expected = null },
        .{ .path = "tools/package-system/conformance/valid/lock/multi-profile/nako.lock", .expected = null },
        .{ .path = "tools/package-system/conformance/valid/lock/cnako-esm/nako.lock", .expected = null },
        .{ .path = "tools/package-system/conformance/valid/lock/npm-instances/nako.lock", .expected = null },
        .{ .path = "tools/package-system/conformance/valid/lock/central-migration/nako.lock", .expected = null },
        .{ .path = "tools/package-system/conformance/valid/lock/multi-profile-os/nako.lock", .expected = null },
        .{ .path = "tools/package-system/conformance/valid/lock/multi-profile-source-hash-encoding/nako.lock", .expected = null },
        .{ .path = "tools/package-system/conformance/invalid/lock/unknown-schema/nako.lock", .expected = diag.E002_UNKNOWN_LOCK_SCHEMA },
        .{ .path = "tools/package-system/conformance/invalid/lock/unknown-profile-source/nako.lock", .expected = diag.E030_UNKNOWN_PROFILE },
        .{ .path = "tools/package-system/conformance/invalid/lock/unknown-runtime/nako.lock", .expected = diag.E014_INVALID_PROFILE },
        .{ .path = "tools/package-system/conformance/invalid/lock/unknown-artifact-kind/nako.lock", .expected = diag.E007_UNKNOWN_ARTIFACT_KIND },
        .{ .path = "tools/package-system/conformance/invalid/lock/future-artifact/nako.lock", .expected = diag.E007_UNKNOWN_ARTIFACT_KIND },
        .{ .path = "tools/package-system/conformance/invalid/lock/missing-artifact/nako.lock", .expected = diag.E008_MISSING_ARTIFACT },
        .{ .path = "tools/package-system/conformance/invalid/lock/lnako-source-with-esm/nako.lock", .expected = diag.E006_JS_IN_NORMAL_MODE },
        .{ .path = "tools/package-system/conformance/invalid/lock/lnako-esm-no-compat-js/nako.lock", .expected = diag.E006_JS_IN_NORMAL_MODE },
        .{ .path = "tools/package-system/conformance/invalid/lock/multi-profile-esm-no-compat-js/nako.lock", .expected = diag.E006_JS_IN_NORMAL_MODE },
        .{ .path = "tools/package-system/conformance/invalid/lock/multi-profile-source-hash-mismatch/nako.lock", .expected = diag.E009_HASH_MISMATCH },
        .{ .path = "tools/package-system/conformance/invalid/lock/multi-profile-packages-mismatch/nako.lock", .expected = diag.E029_INVALID_VALUE },
        .{ .path = "tools/package-system/conformance/invalid/lock/multi-profile-unknown-profile/nako.lock", .expected = diag.E030_UNKNOWN_PROFILE },
        .{ .path = "tools/package-system/conformance/invalid/lock/invalid-semver-version/nako.lock", .expected = diag.E024_INVALID_SEMVER },
        .{ .path = "tools/package-system/conformance/invalid/lock/overflow-version/nako.lock", .expected = diag.E024_INVALID_SEMVER },
        .{ .path = "tools/package-system/conformance/invalid/lock/profile-target-mismatch/nako.lock", .expected = diag.E014_INVALID_PROFILE },
        .{ .path = "tools/package-system/conformance/invalid/lock/invalid-package-id/nako.lock", .expected = diag.E029_INVALID_VALUE },
        .{ .path = "tools/package-system/conformance/invalid/lock/unknown-target/nako.lock", .expected = diag.E014_INVALID_PROFILE },
        .{ .path = "tools/package-system/conformance/invalid/lock/unknown-profile-os/nako.lock", .expected = diag.E014_INVALID_PROFILE },
        .{ .path = "tools/package-system/conformance/invalid/lock/invalid-optimize/nako.lock", .expected = diag.E029_INVALID_VALUE },
        .{ .path = "tools/package-system/conformance/invalid/lock/profile-packages-incomplete/nako.lock", .expected = diag.E029_INVALID_VALUE },
        .{ .path = "tools/package-system/conformance/invalid/lock/missing-implementation-artifact/nako.lock", .expected = diag.E008_MISSING_ARTIFACT },
    };
    for (cases) |case| {
        const bytes = try repo.readFileAlloc(T.io, case.path, allocator, .limited(1 << 20));
        defer allocator.free(bytes);
        var diagnostics = diag.List.init(allocator);
        defer diagnostics.deinit();
        var value = lock.parse(allocator, bytes, &diagnostics) catch |err| {
            if (case.expected) |code| {
                if (diagnostics.find(code) != null) continue;
            }
            std.debug.print("{s}: unexpected parse error {s}, diagnostics:", .{ case.path, @errorName(err) });
            for (diagnostics.items.items) |item| std.debug.print(" {s}", .{item.code});
            std.debug.print("\n", .{});
            return error.TestUnexpectedResult;
        };
        defer value.deinit();
        try lock.validate(&value, &diagnostics);
        if (case.expected) |code| {
            if (diagnostics.find(code) == null) {
                std.debug.print("{s}: expected diagnostic {s}, got:", .{ case.path, code });
                for (diagnostics.items.items) |item| std.debug.print(" {s}", .{item.code});
                std.debug.print("\n", .{});
                return error.TestUnexpectedResult;
            }
        } else if (diagnostics.hasErrors()) {
            var rendered: std.Io.Writer.Allocating = .init(allocator);
            defer rendered.deinit();
            try diagnostics.render(&rendered.writer, case.path);
            std.debug.print("{s}", .{rendered.written()});
            return error.TestUnexpectedResult;
        }
    }
}
