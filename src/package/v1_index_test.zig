//! Sparse Index JSON（§4）の解析・検証テスト。
//!
//! 標準サンプルは nako-registry `fixtures/v1/requirements/config.json` と
//! `package.json`（基点 af868c6）の内容をそのまま埋め込む。負のケースは
//! 最小の有効な index JSON を文字列置換して作る。

const std = @import("std");
const testing = std.testing;
const index = @import("v1_index.zig");
const types = @import("v1_types.zig");

const sample_config_json =
    \\{
    \\  "schema_version": 1,
    \\  "registry_id": "nako-official",
    \\  "api_base_url": "https://api.registry.nako.example/v1",
    \\  "artifact_base_url": "https://cdn.registry.nako.example/artifacts",
    \\  "allowed_external_hosts": [
    \\    "github.com",
    \\    "objects.githubusercontent.com"
    \\  ]
    \\}
;

const sample_package_json =
    \\{
    \\  "schema_version": 1,
    \\  "id": "@soramikan/http",
    \\  "scope_id": "01936d2a-8c4f-7b12-9a01-3e4f5a6b7c8d",
    \\  "updated_at": "2026-11-27T13:30:00Z",
    \\  "deprecated": null,
    \\  "versions": [
    \\    {
    \\      "version": "1.2.0",
    \\      "published_at": "2026-11-27T13:30:00Z",
    \\      "yanked": false,
    \\      "yank_reason": null,
    \\      "license": "MIT",
    \\      "capabilities": ["net", "native"],
    \\      "engines": {
    \\        "lnako": ">=0.3.0 <1.0.0",
    \\        "cnako": ">=3.6.0",
    \\        "wnako": ">=3.6.0"
    \\      },
    \\      "exports_global_commands": true,
    \\      "global_commands": ["HTTP取得"],
    \\      "features": {
    \\        "default": ["tls"],
    \\        "tls": [],
    \\        "http3": ["tls"]
    \\      },
    \\      "dependencies": [
    \\        {
    \\          "id": "@std/json",
    \\          "req": "^1.0.0",
    \\          "features": [],
    \\          "default_features": true,
    \\          "optional": false,
    \\          "runtimes": ["lnako", "cnako", "wnako"]
    \\        },
    \\        {
    \\          "id": "@std/tls",
    \\          "req": "^1.0.0",
    \\          "features": [],
    \\          "default_features": true,
    \\          "optional": false,
    \\          "runtimes": ["lnako"]
    \\        }
    \\      ],
    \\      "provenance": {
    \\        "verified": true,
    \\        "provider": "github-actions",
    \\        "repository": "https://github.com/soramikan/nako-http",
    \\        "repository_id": "123456789",
    \\        "commit_sha": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
    \\        "workflow_ref": ".github/workflows/release.yml@refs/tags/v1.2.0",
    \\        "run_id": "9876543210"
    \\      },
    \\      "artifacts": [
    \\        {
    \\          "kind": "universal",
    \\          "runtimes": ["lnako", "cnako", "wnako"],
    \\          "target": null,
    \\          "hosting": "registry",
    \\          "url": "https://cdn.registry.nako.example/artifacts/soramikan/http/1.2.0/soramikan__http-1.2.0-universal.npkg",
    \\          "sha256": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
    \\          "size": 14280
    \\        },
    \\        {
    \\          "kind": "esm",
    \\          "runtimes": ["cnako", "wnako"],
    \\          "target": null,
    \\          "hosting": "registry",
    \\          "url": "https://cdn.registry.nako.example/artifacts/soramikan/http/1.2.0/soramikan__http-1.2.0-esm-cnako+wnako.npkg",
    \\          "sha256": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
    \\          "size": 28410
    \\        },
    \\        {
    \\          "kind": "native-source",
    \\          "runtimes": ["lnako"],
    \\          "target": {
    \\            "abi_version": 1
    \\          },
    \\          "hosting": "registry",
    \\          "url": "https://cdn.registry.nako.example/artifacts/soramikan/http/1.2.0/soramikan__http-1.2.0-native-source.npkg",
    \\          "sha256": "sha256:3333333333333333333333333333333333333333333333333333333333333333",
    \\          "size": 52100
    \\        },
    \\        {
    \\          "kind": "native-prebuilt",
    \\          "runtimes": ["lnako"],
    \\          "target": {
    \\            "target_triple": "x86_64-linux-gnu",
    \\            "abi_version": 1,
    \\            "glibc_min": "2.31"
    \\          },
    \\          "hosting": "registry",
    \\          "url": "https://cdn.registry.nako.example/artifacts/soramikan/http/1.2.0/soramikan__http-1.2.0-native-x86_64-linux-gnu-abi1.npkg",
    \\          "sha256": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
    \\          "size": 495120
    \\        }
    \\      ],
    \\      "advisories": []
    \\    }
    \\  ]
    \\}
;

const minimal_package_json =
    \\{
    \\  "schema_version": 1,
    \\  "id": "@acme/demo",
    \\  "scope_id": "sc01",
    \\  "updated_at": "2026-11-27T13:30:00Z",
    \\  "versions": [
    \\    {
    \\      "version": "1.0.0",
    \\      "published_at": "2026-11-27T13:30:00Z",
    \\      "yanked": false,
    \\      "license": "MIT",
    \\      "capabilities": ["pure-nako"],
    \\      "engines": {"lnako": ">=0.3.0 <1.0.0"},
    \\      "exports_global_commands": false,
    \\      "global_commands": [],
    \\      "features": {"default": []},
    \\      "dependencies": [],
    \\      "provenance": {"verified": true},
    \\      "artifacts": [
    \\        {
    \\          "kind": "universal",
    \\          "runtimes": ["lnako", "cnako", "wnako"],
    \\          "target": null,
    \\          "hosting": "registry",
    \\          "url": "https://cdn.example.invalid/artifacts/demo.npkg",
    \\          "sha256": "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    \\          "size": 3
    \\        }
    \\      ]
    \\    }
    \\  ]
    \\}
;

const native_source_json =
    \\{
    \\  "schema_version": 1,
    \\  "id": "@acme/native",
    \\  "scope_id": "sc02",
    \\  "updated_at": "2026-11-27T13:30:00Z",
    \\  "versions": [{
    \\    "version": "1.0.0",
    \\    "published_at": "2026-11-27T13:30:00Z",
    \\    "yanked": false,
    \\    "license": "MIT",
    \\    "capabilities": ["native"],
    \\    "engines": {},
    \\    "exports_global_commands": false,
    \\    "global_commands": [],
    \\    "features": {},
    \\    "dependencies": [],
    \\    "provenance": {"verified": true},
    \\    "artifacts": [{
    \\      "kind": "native-source",
    \\      "runtimes": ["lnako"],
    \\      "target": {"abi_version": 1},
    \\      "hosting": "registry",
    \\      "url": "https://cdn.example.invalid/artifacts/native.npkg",
    \\      "sha256": "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    \\      "size": 3
    \\    }]
    \\  }]
    \\}
;

const native_prebuilt_gnu_json =
    \\{
    \\  "schema_version": 1,
    \\  "id": "@acme/native",
    \\  "scope_id": "sc02",
    \\  "updated_at": "2026-11-27T13:30:00Z",
    \\  "versions": [{
    \\    "version": "1.0.0",
    \\    "published_at": "2026-11-27T13:30:00Z",
    \\    "yanked": false,
    \\    "license": "MIT",
    \\    "capabilities": ["native"],
    \\    "engines": {},
    \\    "exports_global_commands": false,
    \\    "global_commands": [],
    \\    "features": {},
    \\    "dependencies": [],
    \\    "provenance": {"verified": true},
    \\    "artifacts": [{
    \\      "kind": "native-prebuilt",
    \\      "runtimes": ["lnako"],
    \\      "target": {"target_triple": "x86_64-linux-gnu", "abi_version": 1, "glibc_min": "2.31"},
    \\      "hosting": "registry",
    \\      "url": "https://cdn.example.invalid/artifacts/native.npkg",
    \\      "sha256": "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    \\      "size": 3
    \\    }]
    \\  }]
    \\}
;

const native_prebuilt_macos_json =
    \\{
    \\  "schema_version": 1,
    \\  "id": "@acme/native",
    \\  "scope_id": "sc02",
    \\  "updated_at": "2026-11-27T13:30:00Z",
    \\  "versions": [{
    \\    "version": "1.0.0",
    \\    "published_at": "2026-11-27T13:30:00Z",
    \\    "yanked": false,
    \\    "license": "MIT",
    \\    "capabilities": ["native"],
    \\    "engines": {},
    \\    "exports_global_commands": false,
    \\    "global_commands": [],
    \\    "features": {},
    \\    "dependencies": [],
    \\    "provenance": {"verified": true},
    \\    "artifacts": [{
    \\      "kind": "native-prebuilt",
    \\      "runtimes": ["lnako"],
    \\      "target": {"target_triple": "aarch64-macos-none", "abi_version": 1},
    \\      "hosting": "registry",
    \\      "url": "https://cdn.example.invalid/artifacts/native.npkg",
    \\      "sha256": "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    \\      "size": 3
    \\    }]
    \\  }]
    \\}
;

test "§4.2 標準 sample config.json を所有型へ解析する" {
    var config = try index.parseConfig(testing.allocator, sample_config_json);
    defer config.deinit();

    try testing.expectEqual(@as(u32, 1), config.schema_version);
    try testing.expectEqualStrings("nako-official", config.registry_id);
    try testing.expectEqualStrings("https://api.registry.nako.example/v1", config.api_base_url);
    try testing.expectEqualStrings("https://cdn.registry.nako.example/artifacts", config.artifact_base_url);
    try testing.expectEqual(@as(usize, 2), config.allowed_external_hosts.len);
    try testing.expect(config.allowsExternalHost("github.com"));
    try testing.expect(config.allowsExternalHost("GITHUB.COM"));
    try testing.expect(!config.allowsExternalHost("example.invalid"));
}

test "§4.3 標準 sample package.json を所有型へ解析する" {
    var package = try index.parsePackage(testing.allocator, sample_package_json);
    defer package.deinit();

    try testing.expectEqualStrings("@soramikan/http", package.id);
    try testing.expectEqualStrings("01936d2a-8c4f-7b12-9a01-3e4f5a6b7c8d", package.scope_id);
    try testing.expectEqualStrings("2026-11-27T13:30:00Z", package.updated_at);
    try testing.expect(package.deprecated == null);
    try testing.expectEqual(@as(usize, 1), package.versions.len);

    const release = package.findRelease("1.2.0") orelse return error.TestExpectedRelease;
    try testing.expect(package.findRelease("1.2.1") == null);
    try testing.expectEqualStrings("1.2.0", release.version);
    try testing.expectEqualStrings("2026-11-27T13:30:00Z", release.published_at);
    try testing.expect(!release.yanked);
    try testing.expect(release.yank_reason == null);
    try testing.expectEqualStrings("MIT", release.license);
    try testing.expectEqual(@as(usize, 2), release.capabilities.len);
    try testing.expectEqualStrings("net", release.capabilities[0]);
    try testing.expectEqualStrings("native", release.capabilities[1]);
    try testing.expect(release.exports_global_commands);
    try testing.expectEqual(@as(usize, 1), release.global_commands.len);
    try testing.expectEqualStrings("HTTP取得", release.global_commands[0]);

    try testing.expectEqual(@as(usize, 3), release.engines.len);
    try testing.expectEqual(@as(usize, 3), release.features.len);
    var saw_default = false;
    for (release.features) |feature| {
        if (std.mem.eql(u8, feature.name, "default")) {
            saw_default = true;
            try testing.expectEqual(@as(usize, 1), feature.enables.len);
            try testing.expectEqualStrings("tls", feature.enables[0]);
        }
    }
    try testing.expect(saw_default);

    try testing.expectEqual(@as(usize, 2), release.dependencies.len);
    const json_dep = release.dependencies[0];
    try testing.expectEqualStrings("@std/json", json_dep.id);
    try testing.expectEqualStrings("^1.0.0", json_dep.req);
    try testing.expect(json_dep.alias == null);
    try testing.expect(json_dep.default_features);
    try testing.expect(!json_dep.optional);
    try testing.expectEqual(@as(usize, 3), json_dep.runtimes.len);
    try testing.expect(!json_dep.allow_global_commands);
    try testing.expectEqualStrings("@std/tls", release.dependencies[1].id);

    const provenance = release.provenance orelse return error.TestExpectedProvenance;
    try testing.expect(provenance.verified);
    try testing.expectEqualStrings("github-actions", provenance.provider.?);
    try testing.expectEqualStrings("123456789", provenance.repository_id.?);

    try testing.expectEqual(@as(usize, 4), release.artifacts.len);
    try testing.expectEqual(types.Kind.universal, release.artifacts[0].kind);
    try testing.expectEqual(@as(usize, 3), release.artifacts[0].runtimes.len);
    try testing.expect(release.artifacts[0].target_triple == null);
    try testing.expectEqual(types.Kind.esm, release.artifacts[1].kind);
    try testing.expectEqual(types.Kind.@"native-source", release.artifacts[2].kind);
    try testing.expectEqual(@as(u32, 1), release.artifacts[2].abi_version.?);
    try testing.expect(release.artifacts[2].target_triple == null);
    try testing.expectEqual(types.Kind.@"native-prebuilt", release.artifacts[3].kind);
    try testing.expectEqualStrings("x86_64-linux-gnu", release.artifacts[3].target_triple.?);
    try testing.expectEqual(@as(u32, 1), release.artifacts[3].abi_version.?);
    try testing.expectEqualStrings("2.31", release.artifacts[3].glibc_min.?);
    try testing.expectEqual(@as(u64, 495120), release.artifacts[3].size);
}

test "§4.3 enginesとdependenciesはnode-semverのwildcardを受理する" {
    const engine_text = try mutate(
        testing.allocator,
        sample_package_json,
        "\"lnako\": \">=0.3.0 <1.0.0\"",
        "\"lnako\": \"1.x.5\"",
    );
    defer testing.allocator.free(engine_text);
    const text = try mutate(
        testing.allocator,
        engine_text,
        "\"req\": \"^1.0.0\"",
        "\"req\": \"*.1\"",
    );
    defer testing.allocator.free(text);

    var package = try index.parsePackage(testing.allocator, text);
    defer package.deinit();
    const release = package.findRelease("1.2.0") orelse return error.TestExpectedRelease;
    try testing.expectEqualStrings("1.x.5", release.engines[0].range);
    try testing.expectEqualStrings("*.1", release.dependencies[0].req);

    try expectPackageErrorIn(
        sample_package_json,
        "\"lnako\": \">=0.3.0 <1.0.0\"",
        "\"lnako\": \"1.x.5.6\"",
        error.InvalidField,
    );
}

test "§4.2 config.json の必須項目と型を検査する" {
    try expectConfigError("\"schema_version\": 1", "\"schema_version\": 1.0", error.UnsupportedSchemaVersion);
    try expectConfigError("\"registry_id\": \"nako-official\",", "", error.MissingField);
    try expectConfigError("\"registry_id\": \"nako-official\"", "\"registry_id\": \"\"", error.InvalidField);
    try expectConfigError(
        "https://cdn.registry.nako.example/artifacts",
        "http://cdn.registry.nako.example/artifacts",
        error.InvalidField,
    );
    try expectConfigError(
        "\"github.com\",",
        "\"github.com:443\",",
        error.InvalidField,
    );
    try expectConfigError(
        "\"objects.githubusercontent.com\"",
        "\"*.githubusercontent.com\"",
        error.InvalidField,
    );
    try expectConfigError(
        "\"allowed_external_hosts\": [",
        "\"allowed_external_hosts\": 1, \"ignored\": [",
        error.InvalidField,
    );
    try expectConfigError(
        "\"api_base_url\": \"https://api.registry.nako.example/v1\"",
        "\"api_base_url\": \"not a uri\"",
        error.InvalidField,
    );

    // schema は追加プロパティを許す。
    {
        const text = try mutate(testing.allocator, sample_config_json, "\"schema_version\": 1,", "\"schema_version\": 1, \"future\": true,");
        defer testing.allocator.free(text);
        var config = try index.parseConfig(testing.allocator, text);
        config.deinit();
    }

    try expectConfigError("\"schema_version\": 1,", "", error.MissingField);
    try expectConfigError("{\n  \"schema_version\"", "[]\n  \"schema_version\"", error.InvalidJson);
    try expectConfigTextError("[]", error.InvalidField);
    try expectConfigTextError(
        "{\"schema_version\":1,\"schema_version\":1,\"registry_id\":\"x\",\"api_base_url\":\"https://a.invalid/v1\",\"artifact_base_url\":\"https://b.invalid/artifacts\",\"allowed_external_hosts\":[]}",
        error.InvalidJson,
    );
}

test "§4.3 package.json の共通項目を検査する" {
    try expectPackageError("\"schema_version\": 1", "\"schema_version\": 1.0", error.UnsupportedSchemaVersion);
    try expectPackageError("\"id\": \"@acme/demo\"", "\"id\": \"acme/demo\"", error.InvalidField);
    try expectPackageError("\"id\": \"@acme/demo\"", "\"id\": \"@Acme/demo\"", error.InvalidField);
    try expectPackageError("\"scope_id\": \"sc01\",", "", error.MissingField);
    try expectPackageError("\"updated_at\": \"2026-11-27T13:30:00Z\"", "\"updated_at\": \"2026-11-27 13:30:00\"", error.InvalidField);
    try expectPackageError("\"version\": \"1.0.0\"", "\"version\": \"01.0.0\"", error.InvalidField);
    try expectPackageError("\"version\": \"1.0.0\"", "\"version\": \"1.0.0+build\"", error.InvalidField);
    try expectPackageError("\"yanked\": false,", "\"yanked\": true,", error.MissingField);
    try expectPackageError(
        "\"yanked\": false,",
        "\"yanked\": true, \"yank_reason\": \"  \",",
        error.InvalidField,
    );
    try expectPackageError(
        "\"exports_global_commands\": false,\n      \"global_commands\": []",
        "\"exports_global_commands\": false,\n      \"global_commands\": [\"取得\"]",
        error.InvalidField,
    );
    try expectPackageError("\"provenance\": {\"verified\": true},", "", error.MissingField);
    try expectPackageError("\"provenance\": {\"verified\": true}", "\"provenance\": {}", error.MissingField);
    try expectPackageError("\"provenance\": {\"verified\": true}", "\"provenance\": {\"verified\": \"yes\"}", error.InvalidField);
    try expectPackageError(
        "\"sha256\": \"sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"",
        "\"sha256\": \"sha256:BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD\"",
        error.InvalidField,
    );
    try expectPackageError(
        "https://cdn.example.invalid/artifacts/demo.npkg",
        "http://cdn.example.invalid/artifacts/demo.npkg",
        error.InvalidField,
    );
    try expectPackageError("\"size\": 3", "\"size\": -1", error.InvalidField);
    try expectPackageError("\"size\": 3", "\"size\": 3.0", error.InvalidField);
    try expectPackageError("\"engines\": {\"lnako\": \">=0.3.0 <1.0.0\"}", "\"engines\": {\"nako\": \">=0.3.0\"}", error.InvalidField);
    try expectPackageError("\"engines\": {\"lnako\": \">=0.3.0 <1.0.0\"}", "\"engines\": {\"lnako\": \"1.2.3.4\"}", error.InvalidField);
    try expectPackageError(
        "\"dependencies\": []",
        "\"dependencies\": [{\"id\": \"@std/json\", \"req\": \"1.2.3.4\"}]",
        error.InvalidField,
    );
    try expectPackageError(
        "\"dependencies\": []",
        "\"dependencies\": [{\"id\": \"std/json\", \"req\": \"^1.0.0\"}]",
        error.InvalidField,
    );
    try expectPackageError(
        "\"features\": {\"default\": []}",
        "\"features\": {\"default\": 1}",
        error.InvalidField,
    );
    try expectPackageError("\"capabilities\": [\"pure-nako\"]", "\"capabilities\": [\"unknown\"]", error.InvalidField);

    // versions が空でも schema 上は有効。
    {
        const empty = "{\"schema_version\":1,\"id\":\"@acme/demo\",\"scope_id\":\"sc01\",\"updated_at\":\"2026-11-27T13:30:00Z\",\"versions\":[]}";
        var package = try index.parsePackage(testing.allocator, empty);
        package.deinit();
    }

    // 公開スキーマは数値幅を制限しない。node-semver の MAX_SAFE_INTEGER を
    // 超える版も index の公開型としては受理する。
    {
        const text = try mutate(
            testing.allocator,
            minimal_package_json,
            "\"version\": \"1.0.0\"",
            "\"version\": \"9007199254740992.0.0-rc.1\"",
        );
        defer testing.allocator.free(text);
        var package = try index.parsePackage(testing.allocator, text);
        defer package.deinit();
        try testing.expectEqualStrings("9007199254740992.0.0-rc.1", package.versions[0].version);
    }

    // 追加プロパティは許す。
    {
        const text = try mutate(testing.allocator, minimal_package_json, "\"schema_version\": 1,", "\"schema_version\": 1, \"future\": {\"x\": 1},");
        defer testing.allocator.free(text);
        var package = try index.parsePackage(testing.allocator, text);
        package.deinit();
    }

    // 同じ version の重複は拒否する。
    {
        const duplicate = "{\"schema_version\":1,\"id\":\"@acme/demo\",\"scope_id\":\"sc01\",\"updated_at\":\"2026-11-27T13:30:00Z\",\"versions\":[" ++
            "{\"version\":\"1.0.0\",\"published_at\":\"2026-11-27T13:30:00Z\",\"yanked\":false,\"license\":\"MIT\",\"capabilities\":[\"pure-nako\"],\"engines\":{},\"exports_global_commands\":false,\"global_commands\":[],\"features\":{},\"dependencies\":[],\"provenance\":{\"verified\":true},\"artifacts\":[{\"kind\":\"universal\",\"runtimes\":[\"lnako\",\"cnako\",\"wnako\"],\"target\":null,\"hosting\":\"registry\",\"url\":\"https://cdn.example.invalid/a.npkg\",\"sha256\":\"sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\",\"size\":3}]}," ++
            "{\"version\":\"1.0.0\",\"published_at\":\"2026-11-27T13:30:00Z\",\"yanked\":false,\"license\":\"MIT\",\"capabilities\":[\"pure-nako\"],\"engines\":{},\"exports_global_commands\":false,\"global_commands\":[],\"features\":{},\"dependencies\":[],\"provenance\":{\"verified\":true},\"artifacts\":[{\"kind\":\"universal\",\"runtimes\":[\"lnako\",\"cnako\",\"wnako\"],\"target\":null,\"hosting\":\"registry\",\"url\":\"https://cdn.example.invalid/a.npkg\",\"sha256\":\"sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\",\"size\":3}]}]}";
        try expectPackageTextError(duplicate, error.DuplicateVersion);
    }
}

test "§4.3 kind ごとの target 規則を検査する" {
    // 標準サンプルは native-source（abi のみ）と native-prebuilt（gnu）を通す。
    {
        var package = try index.parsePackage(testing.allocator, sample_package_json);
        package.deinit();
    }
    {
        var package = try index.parsePackage(testing.allocator, native_source_json);
        package.deinit();
    }
    {
        var package = try index.parsePackage(testing.allocator, native_prebuilt_gnu_json);
        package.deinit();
    }
    {
        var package = try index.parsePackage(testing.allocator, native_prebuilt_macos_json);
        package.deinit();
    }

    // universal は 3 ランタイムすべてが必要。
    try expectPackageError(
        "\"runtimes\": [\"lnako\", \"cnako\", \"wnako\"]",
        "\"runtimes\": [\"lnako\", \"cnako\"]",
        error.InvalidField,
    );
    // esm は lnako を含めない。
    try expectPackageError("\"kind\": \"universal\"", "\"kind\": \"esm\"", error.InvalidField);
    // native-source は abi_version が必須で、triple/glibc を持たない。
    try expectPackageErrorIn(native_source_json, "\"target\": {\"abi_version\": 1}", "\"target\": {}", error.MissingField);
    try expectPackageErrorIn(native_source_json, "\"target\": {\"abi_version\": 1}", "\"target\": {\"abi_version\": 1, \"glibc_min\": \"2.31\"}", error.InvalidField);
    // native-prebuilt は gnu で glibc_min 必須、それ以外では禁止。
    try expectPackageErrorIn(
        native_prebuilt_gnu_json,
        "\"target\": {\"target_triple\": \"x86_64-linux-gnu\", \"abi_version\": 1, \"glibc_min\": \"2.31\"}",
        "\"target\": {\"target_triple\": \"x86_64-linux-gnu\", \"abi_version\": 1}",
        error.MissingField,
    );
    try expectPackageErrorIn(
        native_prebuilt_macos_json,
        "\"target\": {\"target_triple\": \"aarch64-macos-none\", \"abi_version\": 1}",
        "\"target\": {\"target_triple\": \"aarch64-macos-none\", \"abi_version\": 1, \"glibc_min\": \"2.31\"}",
        error.InvalidField,
    );
    try expectPackageErrorIn(
        native_prebuilt_macos_json,
        "\"target_triple\": \"aarch64-macos-none\"",
        "\"target_triple\": \"aarch64-macos\"",
        error.InvalidField,
    );
    // universal / esm の target は null でなければならない。
    try expectPackageError("\"target\": null", "\"target\": {}", error.InvalidField);
    // native-prebuilt の runtimes は lnako のみ。
    try expectPackageErrorIn(
        native_prebuilt_gnu_json,
        "\"runtimes\": [\"lnako\"]",
        "\"runtimes\": [\"cnako\"]",
        error.InvalidField,
    );
}

test "UTC RFC3339 の時刻だけを受理する" {
    try testing.expect(index.validUtcTimestamp("2026-11-27T13:30:00Z"));
    try testing.expect(index.validUtcTimestamp("2026-11-27t13:30:00z"));
    try testing.expect(index.validUtcTimestamp("2024-02-29T23:59:60Z"));
    try testing.expect(index.validUtcTimestamp("2026-11-27T13:30:00.125+00:00"));
    try testing.expect(!index.validUtcTimestamp("2026-02-29T13:30:00Z"));
    try testing.expect(!index.validUtcTimestamp("2026-11-27T13:30:00+09:00"));
    try testing.expect(!index.validUtcTimestamp("2026-11-27T13:30:00-00:00"));
    try testing.expect(!index.validUtcTimestamp("2026-11-27T24:00:00Z"));
    try testing.expect(!index.validUtcTimestamp("2026-11-27T13:30:00"));
    try testing.expect(!index.validUtcTimestamp("2026-11-27"));
}

test "ホスト名と HTTPS URL の構文を検査する" {
    try testing.expect(index.validHostname("github.com"));
    try testing.expect(index.validHostname("objects.githubusercontent.com"));
    try testing.expect(!index.validHostname("github.com:443"));
    try testing.expect(!index.validHostname("-github.com"));
    try testing.expect(!index.validHostname("github..com"));
    try testing.expect(!index.validHostname("*.github.com"));
    try testing.expect(index.validHttpsUrl("https://cdn.example.invalid/artifacts/demo.npkg"));
    try testing.expect(!index.validHttpsUrl("http://cdn.example.invalid/artifacts/demo.npkg"));
    try testing.expect(!index.validHttpsUrl("https:///artifacts/demo.npkg"));
    try testing.expect(!index.validHttpsUrl("https://user@cdn.example.invalid/demo.npkg"));
}

fn expectConfigTextError(text: []const u8, expected: anyerror) !void {
    if (index.parseConfig(testing.allocator, text)) |value| {
        var config = value;
        config.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(expected, err);
    }
}

fn expectPackageTextError(text: []const u8, expected: anyerror) !void {
    if (index.parsePackage(testing.allocator, text)) |value| {
        var package = value;
        package.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(expected, err);
    }
}

fn expectConfigError(needle: []const u8, replacement: []const u8, expected: anyerror) !void {
    const text = try mutate(testing.allocator, sample_config_json, needle, replacement);
    defer testing.allocator.free(text);
    if (index.parseConfig(testing.allocator, text)) |value| {
        var config = value;
        config.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(expected, err);
    }
}

fn expectPackageError(needle: []const u8, replacement: []const u8, expected: anyerror) !void {
    return expectPackageErrorIn(minimal_package_json, needle, replacement, expected);
}

fn expectPackageErrorIn(text: []const u8, needle: []const u8, replacement: []const u8, expected: anyerror) !void {
    const mutated = try mutate(testing.allocator, text, needle, replacement);
    defer testing.allocator.free(mutated);
    if (index.parsePackage(testing.allocator, mutated)) |value| {
        var package = value;
        package.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(expected, err);
    }
}

fn mutate(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, input, needle, replacement);
}
