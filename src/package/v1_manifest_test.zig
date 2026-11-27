const std = @import("std");
const manifest_mod = @import("v1_manifest.zig");
const semver = @import("semver.zig");
const v1 = @import("v1_types.zig");

const Manifest = manifest_mod.Manifest;
const Mode = manifest_mod.Mode;

const sample =
    \\schema_version = 1
    \\
    \\[package]
    \\id = "@soramikan/http"
    \\version = "1.2.0"
    \\description = "マルチランタイム対応のHTTPクライアントライブラリ"
    \\license = "MIT"
    \\repository = "https://github.com/soramikan/nako-http"
    \\homepage = "https://soramikan.github.io/nako-http"
    \\readme = "README.md"
    \\keywords = ["http", "network", "クライアント"]
    \\capabilities = ["net", "native"]
    \\
    \\[package.engines]
    \\lnako = ">=0.3.0 <1.0.0"
    \\cnako = ">=3.6.0"
    \\wnako = ">=3.6.0"
    \\
    \\[exports]
    \\"." = { entry = "src/main.nako3", binding = "scoped" }
    \\"./client" = { entry = "src/client.nako3", binding = "scoped" }
    \\"./dsl" = { entry = "src/dsl.nako3", binding = "global" }
    \\
    \\[features]
    \\default = ["tls"]
    \\tls = []
    \\http3 = ["tls"]
    \\
    \\[artifacts.universal]
    \\include = ["src/**/*.nako3", "LICENSE", "README.md"]
    \\
    \\[artifacts.esm]
    \\runtimes = ["cnako", "wnako"]
    \\entry = "dist/esm/index.js"
    \\include = ["dist/esm/**/*"]
    \\
    \\[artifacts.native]
    \\abi_version = 1
    \\source_include = ["native/build.zig", "native/src/**/*"]
    \\prebuilt_lib_name = "nako_http"
    \\
    \\[dependencies]
    \\"@std/json" = "^1.0.0"
    \\"@other/json" = { version = "^2.1.0", alias = "fast_json", features = ["simd"] }
    \\"@nako/legacy-dsl" = { version = "^0.5.0", allow_global_commands = true }
    \\
    \\[runtime-dependencies.lnako]
    \\"@std/tls" = "^1.0.0"
    \\
    \\[dev-dependencies]
    \\"@std/test" = "^1.0.0"
    \\
    \\[profiles.default]
    \\runtime = "lnako"
    \\
    \\[profiles.web]
    \\runtime = "wnako"
    \\
;

fn parseOk(source: []const u8, mode: Mode) !Manifest {
    return manifest_mod.parse(std.testing.allocator, source, mode);
}

fn expectParseError(source: []const u8, mode: Mode, expected: anyerror) !void {
    try std.testing.expectError(expected, manifest_mod.parse(std.testing.allocator, source, mode));
}

test "M-01 schema_version = 1.0（浮動小数）を拒否する" {
    const source =
        \\schema_version = 1.0
        \\[package]
        \\
    ;
    try expectParseError(source, .local, error.SchemaVersionNotInteger);
}

test "M-02 未知のトップレベルキーを拒否する" {
    const source =
        \\schema_version = 1
        \\legacy = true
        \\[package]
        \\
    ;
    try expectParseError(source, .local, error.UnknownTopLevelKey);
}

test "M-03 featureの循環参照を拒否する" {
    const source =
        \\schema_version = 1
        \\[package]
        \\
        \\[features]
        \\default = ["tls"]
        \\tls = ["http3"]
        \\http3 = ["tls"]
        \\
    ;
    try expectParseError(source, .local, error.InvalidFeatureCycle);
}

test "M-04 binding省略時はscopedとして受理する" {
    const source =
        \\schema_version = 1
        \\[package]
        \\
        \\[exports]
        \\"." = { entry = "src/main.nako3" }
        \\
    ;
    var manifest = try parseOk(source, .local);
    defer manifest.deinit();
    const entry = manifest.findExport(".").?;
    try std.testing.expectEqual(manifest_mod.Binding.scoped, entry.binding);
    try std.testing.expect(!manifest.exportsGlobalCommands());
}

test "M-05 空のpackageはローカルで受理しpackでID等の欠落を拒否する" {
    const source =
        \\schema_version = 1
        \\[package]
        \\
    ;
    var local = try parseOk(source, .local);
    defer local.deinit();
    try std.testing.expect(local.package.id == null);
    try expectParseError(source, .pack, error.MissingPackageId);
}

test "M-06 旧manifestは新形式を案内するLegacyManifestで拒否する" {
    const old =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\schema-version = 1
        \\
    ;
    try expectParseError(old, .local, error.LegacyManifest);
    // 案内文が新形式の作成を含む。
    try std.testing.expect(std.mem.indexOf(u8, manifest_mod.diagnostic(error.LegacyManifest).?, "schema_version = 1") != null);
    // トップレベル旧キーも同様に識別する。
    const old_top =
        \\schema-version = 1
        \\[package]
        \\name = "demo"
        \\
    ;
    try expectParseError(old_top, .pack, error.LegacyManifest);
}

test "M-07 空のengine範囲はwildcardとして受理する" {
    const source =
        \\schema_version = 1
        \\[package]
        \\[package.engines]
        \\lnako = ""
        \\
    ;
    var manifest = try parseOk(source, .local);
    defer manifest.deinit();
    const engine = manifest.findEngine(.lnako).?;
    try std.testing.expectEqualStrings("", engine.req);
    var range = try v1.parseRange(std.testing.allocator, engine.req);
    defer range.deinit(std.testing.allocator);
    try std.testing.expect(range.satisfies(try semver.Version.parse("9.9.9")));
}

test "#8 engineと依存のv1範囲はnode-semverのwildcardを受理する" {
    const source =
        \\schema_version = 1
        \\[package]
        \\[package.engines]
        \\lnako = "1.x.5"
        \\[dependencies]
        \\"@example/http" = "*.1"
        \\"@example/alpha" = "*.*.*-alpha"
        \\"@example/prefix" = "^=1.2.3"
        \\"@example/hyphen" = "1.2.3 - 2.0.0"
        \\
    ;
    var manifest = try parseOk(source, .local);
    defer manifest.deinit();
    try std.testing.expectEqualStrings("1.x.5", manifest.findEngine(.lnako).?.req);
    try std.testing.expectEqualStrings("*.1", manifest.findDependency("@example/http").?.req);
    try std.testing.expectEqualStrings("*.*.*-alpha", manifest.findDependency("@example/alpha").?.req);
    try std.testing.expectEqualStrings("^=1.2.3", manifest.findDependency("@example/prefix").?.req);
    try std.testing.expectEqualStrings("1.2.3 - 2.0.0", manifest.findDependency("@example/hyphen").?.req);

    var range = try v1.parseRange(std.testing.allocator, manifest.findEngine(.lnako).?.req);
    defer range.deinit(std.testing.allocator);
    try std.testing.expect(range.satisfies(try semver.Version.parse("1.9.9")));
    try std.testing.expect(!range.satisfies(try semver.Version.parse("2.0.0")));

    var prefix_range = try v1.parseRange(std.testing.allocator, manifest.findDependency("@example/prefix").?.req);
    defer prefix_range.deinit(std.testing.allocator);
    try std.testing.expect(prefix_range.satisfies(try semver.Version.parse("1.9.9")));
    try std.testing.expect(!prefix_range.satisfies(try semver.Version.parse("2.0.0")));

    var hyphen_range = try v1.parseRange(std.testing.allocator, manifest.findDependency("@example/hyphen").?.req);
    defer hyphen_range.deinit(std.testing.allocator);
    try std.testing.expect(hyphen_range.satisfies(try semver.Version.parse("2.0.0")));
    try std.testing.expect(!hyphen_range.satisfies(try semver.Version.parse("2.0.1")));

    try expectParseError(
        "schema_version = 1\n[package]\n[dependencies]\n\"@example/bad\" = \"1.2.3 - 2.0.0 >=1\"\n",
        .local,
        error.InvalidRange,
    );
}

test "M-08 package内の任意の説明欄を受理し解決結果を変えない" {
    const source =
        \\schema_version = 1
        \\[package]
        \\id = "@example/demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\release_notes = "初版"
        \\
        \\[dependencies]
        \\"@std/json" = "^1.0.0"
        \\
    ;
    var manifest = try parseOk(source, .pack);
    defer manifest.deinit();
    try std.testing.expectEqualStrings("@example/demo", manifest.package.id.?);
    try std.testing.expectEqualStrings("^1.0.0", manifest.findDependency("@std/json").?.req);
}

test "要件サンプルをpackとして受理し型付き取得が一致する" {
    var manifest = try parseOk(sample, .pack);
    defer manifest.deinit();

    try std.testing.expectEqual(Mode.pack, manifest.mode);
    try std.testing.expect(manifest.hasPackageIdentity());
    try std.testing.expectEqualStrings("@soramikan/http", manifest.package.id.?);
    try std.testing.expectEqualStrings("1.2.0", manifest.package.version.?);
    try std.testing.expectEqualStrings("MIT", manifest.package.license.?);
    try std.testing.expectEqualStrings("README.md", manifest.package.readme.?);
    try std.testing.expectEqual(@as(usize, 3), manifest.package.keywords.len);
    try std.testing.expectEqual(@as(usize, 2), manifest.package.capabilities.len);
    try std.testing.expectEqual(manifest_mod.Capability.net, manifest.package.capabilities[0]);
    try std.testing.expectEqualStrings(">=0.3.0 <1.0.0", manifest.findEngine(.lnako).?.req);

    try std.testing.expectEqual(@as(usize, 3), manifest.exports.len);
    try std.testing.expectEqualStrings("src/main.nako3", manifest.findExport(".").?.entry);
    try std.testing.expectEqual(manifest_mod.Binding.global, manifest.findExport("./dsl").?.binding);
    try std.testing.expect(manifest.exportsGlobalCommands());

    try std.testing.expectEqual(@as(usize, 3), manifest.features.len);
    try std.testing.expectEqualStrings("tls", manifest.findFeature("default").?.enables[0]);
    try std.testing.expectEqual(@as(usize, 0), manifest.findFeature("tls").?.enables.len);
    try std.testing.expectEqualStrings("tls", manifest.findFeature("http3").?.enables[0]);

    try std.testing.expectEqual(@as(usize, 3), manifest.dependencies.len);
    try std.testing.expectEqualStrings("^1.0.0", manifest.findDependency("@std/json").?.req);
    const other = manifest.findDependency("@other/json").?;
    try std.testing.expectEqualStrings("fast_json", other.alias.?);
    try std.testing.expectEqualStrings("simd", other.features[0]);
    try std.testing.expect(manifest.findDependency("@nako/legacy-dsl").?.allow_global_commands);
    // 予約 scope は依存 ID として構文上受理する（ID-04）。
    try std.testing.expect(manifest.findDependency("@std/json") != null);

    try std.testing.expectEqualStrings("fast_json", manifest_mod.localName(other));
    try std.testing.expectEqualStrings("json", manifest_mod.localName(manifest.findDependency("@std/json").?));

    try std.testing.expectEqual(@as(usize, 1), manifest.runtimeDependencies(.lnako).len);
    try std.testing.expectEqualStrings("^1.0.0", manifest.findRuntimeDependency(.lnako, "@std/tls").?.req);
    try std.testing.expectEqual(@as(usize, 0), manifest.runtimeDependencies(.cnako).len);
    try std.testing.expectEqualStrings("^1.0.0", manifest.findDevDependency("@std/test").?.req);

    try std.testing.expectEqual(manifest_mod.Runtime.lnako, manifest.findProfile("default").?.runtime);
    try std.testing.expectEqual(manifest_mod.Runtime.wnako, manifest.findProfile("web").?.runtime);

    try std.testing.expectEqual(@as(usize, 3), manifest.artifacts.universal.?.include.len);
    try std.testing.expectEqual(@as(usize, 2), manifest.artifacts.esm.?.runtimes.len);
    try std.testing.expectEqual(@as(u32, 1), manifest.artifacts.native.?.abi_version);
    try std.testing.expectEqualStrings("nako_http", manifest.artifacts.native.?.prebuilt_lib_name.?);
}

test "公開バージョンは数値幅非依存でmanifestに受理される" {
    const source = "schema_version = 1\n[package]\nversion = \"9007199254740992.0.0-rc.1\"\n";
    var manifest = try parseOk(source, .local);
    defer manifest.deinit();
    try std.testing.expectEqualStrings("9007199254740992.0.0-rc.1", manifest.package.version.?);
}

test "pack必須欄と構文検証の個別error tag" {
    try expectParseError("schema_version = 1\n[package]\nid = \"@example/demo\"\nversion = \"1.0.0\"\n", .pack, error.MissingPackageLicense);
    try expectParseError("schema_version = 1\n[package]\nid = \"@example/demo\"\nlicense = \"MIT\"\n", .pack, error.MissingPackageVersion);
    try expectParseError("schema_version = 1\n[package]\nversion = \"1.0.0\"\nlicense = \"MIT\"\n", .pack, error.MissingPackageId);
    try expectParseError("schema_version = 1\n[package]\nid = \"example/demo\"\n", .local, error.InvalidPackageId);
    try expectParseError("schema_version = 1\n[package]\nversion = \"1.2.0+rev\"\n", .local, error.InvalidVersion);
    try expectParseError("schema_version = 1\n[package]\nlicense = \"NotALicense\"\n", .local, error.InvalidLicense);
    try expectParseError("schema_version = 1\n[package]\nreadme = \"../README.md\"\n", .local, error.InvalidPath);
    try expectParseError("schema_version = 1\n[package]\ncapabilities = [\"root\"]\n", .local, error.InvalidCapability);
    try expectParseError("schema_version = 1\n[package]\n[package.engines]\nnode = \">=1\"\n", .local, error.InvalidRuntime);
    try expectParseError("schema_version = 1\n[package]\n[package.engines]\nlnako = \">=\"\n", .local, error.InvalidRange);
    try expectParseError("schema_version = 2\n[package]\n", .local, error.UnsupportedSchemaVersion);
    try expectParseError("schema_version = 1\n", .local, error.MissingPackage);
    try expectParseError("schema_version = \"1\"\n[package]\n", .local, error.InvalidType);
}

test "exportsと依存の不正を個別に拒否する" {
    const bad_export =
        \\schema_version = 1
        \\[package]
        \\[exports]
        \\"client" = { entry = "src/client.nako3" }
        \\
    ;
    try expectParseError(bad_export, .local, error.InvalidExport);

    const bad_binding =
        \\schema_version = 1
        \\[package]
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "isolated" }
        \\
    ;
    try expectParseError(bad_binding, .local, error.InvalidBinding);

    const bad_dependency =
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\http = "^1.0.0"
        \\
    ;
    try expectParseError(bad_dependency, .local, error.InvalidDependency);

    const bad_range =
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@example/http" = ">="
        \\
    ;
    try expectParseError(bad_range, .local, error.InvalidRange);

    const bad_alias =
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@example/http" = { version = "^1.0.0", alias = "a/b" }
        \\
    ;
    try expectParseError(bad_alias, .local, error.InvalidAlias);
}

test "artifactsの必須欄とESMランタイムを検証する" {
    const missing_include =
        \\schema_version = 1
        \\[package]
        \\[artifacts.universal]
        \\
    ;
    try expectParseError(missing_include, .local, error.MissingArtifactField);

    const esm_lnako =
        \\schema_version = 1
        \\[package]
        \\[artifacts.esm]
        \\runtimes = ["lnako"]
        \\entry = "dist/index.js"
        \\include = ["dist/**"]
        \\
    ;
    try expectParseError(esm_lnako, .local, error.InvalidRuntime);

    const no_abi =
        \\schema_version = 1
        \\[package]
        \\[artifacts.native]
        \\source_include = ["native/**"]
        \\
    ;
    try expectParseError(no_abi, .local, error.MissingArtifactField);

    const zero_abi =
        \\schema_version = 1
        \\[package]
        \\[artifacts.native]
        \\abi_version = 0
        \\
    ;
    try expectParseError(zero_abi, .local, error.InvalidAbiVersion);
}

test "runtime-dependenciesとprofilesの不正を拒否する" {
    const bad_runtime =
        \\schema_version = 1
        \\[package]
        \\[runtime-dependencies.node]
        \\"@example/http" = "^1.0.0"
        \\
    ;
    try expectParseError(bad_runtime, .local, error.InvalidRuntime);

    const missing_runtime =
        \\schema_version = 1
        \\[package]
        \\[profiles.default]
        \\name = "default"
        \\
    ;
    try expectParseError(missing_runtime, .local, error.InvalidProfile);
}

test "feature循環は直接・間接の両方を拒否する" {
    const indirect =
        \\schema_version = 1
        \\[package]
        \\[features]
        \\a = ["b"]
        \\b = ["c"]
        \\c = ["a"]
        \\
    ;
    try expectParseError(indirect, .local, error.InvalidFeatureCycle);

    const self_cycle =
        \\schema_version = 1
        \\[package]
        \\[features]
        \\a = ["a"]
        \\
    ;
    try expectParseError(self_cycle, .local, error.InvalidFeatureCycle);

    const acyclic =
        \\schema_version = 1
        \\[package]
        \\[features]
        \\default = ["a", "b"]
        \\a = ["c"]
        \\b = []
        \\c = []
        \\
    ;
    var manifest = try parseOk(acyclic, .local);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 2), manifest.findFeature("default").?.enables.len);
}
