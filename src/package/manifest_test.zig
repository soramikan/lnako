const std = @import("std");
const manifest_mod = @import("manifest.zig");
const semver = @import("semver.zig");
const diag = @import("diagnostics.zig");

const Manifest = manifest_mod.Manifest;
const parse = manifest_mod.parse;

fn parseOk(allocator: std.mem.Allocator, source: []const u8) !Manifest {
    var list = diag.List.init(allocator);
    defer list.deinit();
    return parse(allocator, source, &list);
}

fn parseErrCode(allocator: std.mem.Allocator, source: []const u8, code: []const u8) !void {
    var list = diag.List.init(allocator);
    defer list.deinit();
    try std.testing.expectError(error.InvalidManifest, parse(allocator, source, &list));
    try std.testing.expect(list.find(code) != null);
}

test "non-npkg export targets must stay in the canonical package-relative tree" {
    const allocator = std.testing.allocator;
    const invalid = [_]struct { field: []const u8, target: []const u8 }{
        .{ .field = "path", .target = "../sibling/file.nako3" },
        .{ .field = "native", .target = "/tmp/outside.dylib" },
        .{ .field = "esm", .target = "src/../outside.mjs" },
    };
    for (invalid) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\[package]
            \\name = "lib"
            \\version = "1.0.0"
            \\license = "MIT"
            \\
            \\[[exports]]
            \\name = "entry"
            \\{s} = "{s}"
            \\
        , .{ case.field, case.target });
        defer allocator.free(source);
        var manifest = try parseOk(allocator, source);
        defer manifest.deinit();
        try std.testing.expect(manifest_mod.hasUnsafeNonNpkgExportTargets(&manifest, false));
        try std.testing.expect(!manifest_mod.hasUnsafeNonNpkgExportTargets(&manifest, true));
    }

    var safe = try parseOk(allocator,
        \\[package]
        \\name = "lib"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "entry"
        \\path = "src/entry.nako3"
        \\
    );
    defer safe.deinit();
    try std.testing.expect(!manifest_mod.hasUnsafeNonNpkgExportTargets(&safe, false));
}

test "妥当なmanifestを解析する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "http-kit"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[features]
        \\default = ["client"]
        \\client = []
        \\server = ["client"]
        \\
        \\[dependencies.pkg]
        \\client = { version = ">=1.0.0 <2.0.0", features = ["http"], default-features = false }
        \\
        \\[profiles]
        \\default = { os = "linux", cpu = "x86_64", abi = "gnu" }
        \\
        \\[[exports]]
        \\name = "http-kit"
        \\path = "src/main.nako3"
        \\
    ;
    var manifest = try parseOk(allocator, source);
    defer manifest.deinit();

    try std.testing.expectEqualStrings("http-kit", manifest.package.name);
    try std.testing.expectEqual(@as(u64, 0), manifest.package.version.major);
    try std.testing.expectEqual(@as(u64, 1), manifest.package.version.minor);
    try std.testing.expectEqualStrings("MIT", manifest.package.license);
    try std.testing.expectEqual(@as(usize, 3), manifest.features.count());
    const client = manifest.dependencies.pkg.get("client").?;
    try std.testing.expect(!client.default_features);
    try std.testing.expect(client.version.satisfies(try semver.Version.parse("1.5.0")));
    try std.testing.expect(!client.version.satisfies(try semver.Version.parse("2.0.0")));
    const profile = manifest.profiles.get("default").?;
    try std.testing.expectEqualStrings("linux", profile.os);
    try std.testing.expectEqual(@as(usize, 1), manifest.exports.len);
    try std.testing.expectEqualStrings("http-kit", manifest.exports[0].name);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var expanded = try manifest.expandFeatures(allocator, &.{}, true, &list);
    defer expanded.deinit();
    try std.testing.expect(expanded.contains("default"));
    try std.testing.expect(expanded.contains("client"));
    try std.testing.expect(!expanded.contains("server"));
    try std.testing.expect(!expanded.dependency_aliases.contains("client"));
}

test "複数行文字列の改行区切りversion範囲を解析する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\lib = { version = """>=1.0.0
        \\<2.0.0""" }
        \\
    ;
    var manifest = try parseOk(allocator, source);
    defer manifest.deinit();
    const lib = manifest.dependencies.pkg.get("lib").?;
    try std.testing.expect(lib.version.satisfies(try semver.Version.parse("1.5.0")));
    try std.testing.expect(!lib.version.satisfies(try semver.Version.parse("2.0.0")));
}

test "既存診断を残したリストでも正常manifestを解析できる" {
    const allocator = std.testing.allocator;
    var list = diag.List.init(allocator);
    defer list.deinit();
    // 1個目の不正manifestの error が残っていても、2個目の成否は
    // 今回追加された診断だけで決まる。
    try std.testing.expectError(error.InvalidManifest, parse(allocator, "version = 1\n", &list));
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
    ;
    var manifest = try parse(allocator, source, &list);
    defer manifest.deinit();
    try std.testing.expectEqualStrings("a", manifest.package.name);
}

test "URIフィールドを検証する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\repository = "https://example.com/repo"
        \\homepage = "https://example.com"
        \\
    ;
    var manifest = try parseOk(allocator, source);
    defer manifest.deinit();
    // repository・homepage・git url・http url の `format: "uri"` を検査する。
    const cases = [_][]const u8{
        \\repository = "not a uri"
        ,
        \\repository = "a:"
        ,
        \\repository = "1abc:x"
        ,
        \\repository = "x:y z"
        ,
        \\repository = ":x"
        ,
        \\repository = "git@github.com:a/b"
        ,
        \\homepage = "%%%"
        ,
        \\[dependencies.git.lib]
        \\url = "not a uri"
        \\commit = "0123456789abcdef0123456789abcdef01234567"
        ,
        \\[dependencies.http.lib]
        \\url = "%%%"
        \\hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        ,
    };
    for (cases) |case| {
        const bad = try std.fmt.allocPrint(allocator,
            \\[package]
            \\name = "a"
            \\version = "1.0.0"
            \\license = "MIT"
            \\{s}
            \\
        , .{case});
        defer allocator.free(bad);
        try parseErrCode(allocator, bad, diag.E029_INVALID_VALUE);
    }
}

test "feature経由の依存aliasを展開する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "app"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[features]
        \\web = ["reqwest"]
        \\
        \\[dependencies.pkg]
        \\reqwest = { version = "^1.0.0" }
        \\
    ;
    var manifest = try parseOk(allocator, source);
    defer manifest.deinit();

    var list = diag.List.init(allocator);
    defer list.deinit();
    var expanded = try manifest.expandFeatures(allocator, &.{"web"}, false, &list);
    defer expanded.deinit();
    try std.testing.expect(expanded.contains("web"));
    try std.testing.expect(expanded.dependency_aliases.contains("reqwest"));
}

test "必須フィールド欠落を診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[features]\naa = []\n", diag.E019_REQUIRED_FIELD_MISSING);
    try parseErrCode(allocator, "[package]\nversion = \"1.0.0\"\nlicense = \"MIT\"\n", diag.E019_REQUIRED_FIELD_MISSING);
    try parseErrCode(allocator, "[dependencies.pkg]\nreq = {}\n", diag.E019_REQUIRED_FIELD_MISSING);
}

test "TOML構文エラーとUTF-8を診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package\nname = \"a\"\n", diag.E020_INVALID_TOML);
    try parseErrCode(allocator, "[package]\nname = \"a\"\nname = \"b\"\n", diag.E020_INVALID_TOML);
    try parseErrCode(allocator, "[package]\nname = \"\xff\"\n", diag.E021_INVALID_UTF8);
}

test "未知フィールドと型不一致を診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\nweird = 1\n", diag.E022_UNKNOWN_FIELD);
    try parseErrCode(allocator, "surprise = 1\n[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n", diag.E022_UNKNOWN_FIELD);
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = 3\n", diag.E023_INVALID_TYPE);
    try parseErrCode(allocator, "package = 1\n", diag.E023_INVALID_TYPE);
}

test "無効なsemverと範囲を診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0\"\nlicense = \"MIT\"\n", diag.E024_INVALID_SEMVER);
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[dependencies.pkg]\nreq = { version = \">=\" }\n", diag.E025_INVALID_RANGE);
}

test "未知のschema versionを診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\nschema-version = 99\n", diag.E001_UNKNOWN_MANIFEST_SCHEMA);
    // u32 範囲を超える巨大な値も E001 とする。
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\nschema-version = 99999999999\n", diag.E001_UNKNOWN_MANIFEST_SCHEMA);
    // 0 は schema の minimum 違反で E029。
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\nschema-version = 0\n", diag.E029_INVALID_VALUE);
}

test "無効なprofileを診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[profiles]\np = { os = " ++ "\"freebsd\"" ++ ", cpu = \"x86_64\", abi = \"gnu\" }\n", diag.E014_INVALID_PROFILE);
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[profiles]\np = { os = \"linux\", cpu = \"x86_64\", abi = \"gnu\", optimize = \"O9\" }\n", diag.E029_INVALID_VALUE);
}

test "export重複とESM制約を診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[[exports]]\nname = \"x\"\n[[exports]]\nname = \"x\"\n", diag.E011_DUPLICATE_EXPORT);
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\nruntimes = [\"lnako\"]\n[[exports]]\nname = \"x\"\nesm = \"m.mjs\"\n", diag.E006_JS_IN_NORMAL_MODE);

    // runtimes 未指定（両対応）または cnako を含む場合は ESM 専用 export も受理される。
    const ok_multi_runtime =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "x"
        \\esm = "m.mjs"
        \\
    ;
    var multi_runtime = try parseOk(allocator, ok_multi_runtime);
    defer multi_runtime.deinit();

    const ok_both_runtimes =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\runtimes = ["lnako", "cnako"]
        \\[[exports]]
        \\name = "x"
        \\esm = "m.mjs"
        \\
    ;
    var both_runtimes = try parseOk(allocator, ok_both_runtimes);
    defer both_runtimes.deinit();

    // compat-js profile があれば ESM export は受理される。
    const ok_source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[profiles]
        \\web = { os = "linux", cpu = "x86_64", abi = "gnu", compat-js = true }
        \\[[exports]]
        \\name = "x"
        \\esm = "m.mjs"
        \\
    ;
    var manifest = try parseOk(allocator, ok_source);
    defer manifest.deinit();
}

test "同一public-idの衝突するversion制約を診断する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\one = { version = ">=1.0.0 <2.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\two = { version = ">=2.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    try parseErrCode(allocator, source, diag.E003_CONFLICTING_VERSIONS);

    // 交差する制約は受理する。
    const ok_source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\one = { version = ">=1.0.0 <3.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\two = { version = ">=2.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    var manifest = try parseOk(allocator, ok_source);
    defer manifest.deinit();
}

test "feature循環を診断する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[features]
        \\aa = ["bb"]
        \\bb = ["aa"]
        \\
    ;
    try parseErrCode(allocator, source, diag.E027_FEATURE_CYCLE);
}

test "未知featureと未知profile参照を診断する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[features]
        \\web = ["missing-dep"]
        \\
    ;
    try parseErrCode(allocator, source, diag.E028_UNKNOWN_FEATURE);

    const bad_profile =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\req = { version = "^1", profile = "nope" }
        \\
    ;
    try parseErrCode(allocator, bad_profile, diag.E030_UNKNOWN_PROFILE);
}

test "npm依存の文字列短縮形とテーブル形を解析する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.npm]
        \\leftpad = "^1.0.0"
        \\express = { version = "^4.0.0", context = "web", peer-dependencies = { ws = "^8" }, optional-peers = ["debug"] }
        \\
    ;
    var manifest = try parseOk(allocator, source);
    defer manifest.deinit();
    const leftpad = manifest.dependencies.npm.get("leftpad").?;
    try std.testing.expect(leftpad.version.satisfies(try semver.Version.parse("1.2.0")));
    const express = manifest.dependencies.npm.get("express").?;
    try std.testing.expectEqualStrings("web", express.context.?);
    try std.testing.expect(express.peer_dependencies.contains("ws"));
    try std.testing.expectEqual(@as(usize, 1), express.optional_peers.len);
}

test "alias衝突を診断する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\one = { version = "^1", alias = "shared" }
        \\two = { version = "^2", alias = "shared" }
        \\
    ;
    try parseErrCode(allocator, source, diag.E012_ALIAS_COLLISION);

    // alias が他の依存エントリ名と衝突しても E012。
    const entry_collision =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\req = { version = "^1", alias = "other" }
        \\other = { version = "^2" }
        \\
    ;
    try parseErrCode(allocator, entry_collision, diag.E012_ALIAS_COLLISION);

    // git 依存の alias も同じ名前空間で検査する。
    const git_collision =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\req = { version = "^1" }
        \\[dependencies.git]
        \\lib = { url = "https://example.com/lib.git", commit = "0123456", alias = "req" }
        \\
    ;
    try parseErrCode(allocator, git_collision, diag.E012_ALIAS_COLLISION);

    // feature が参照する名前空間は dependencies/dev-dependencies で統合
    // されるため、セクションをまたぐ alias・エントリ名の重複も E012。
    const cross_section_alias =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\one = { version = "^1", alias = "shared" }
        \\[dev-dependencies.pkg]
        \\two = { version = "^2", alias = "shared" }
        \\
    ;
    try parseErrCode(allocator, cross_section_alias, diag.E012_ALIAS_COLLISION);

    const cross_section_entry =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\lib = { version = "^1" }
        \\[dev-dependencies.pkg]
        \\lib = { version = "^1" }
        \\
    ;
    try parseErrCode(allocator, cross_section_entry, diag.E012_ALIAS_COLLISION);
}

test "license式を検証する" {
    const allocator = std.testing.allocator;
    const base =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "{s}"
        \\
    ;
    const accepted = [_][]const u8{
        "MIT",
        "MIT OR Apache-2.0",
        "(MIT OR Apache-2.0) AND GPL-3.0-only",
        "GPL-2.0+",
        "GPL-3.0-only WITH Classpath-exception-2.0",
        "LicenseRef-FOO",
        "DocumentRef-doc:LicenseRef-FOO",
        // `DocumentRef-` 接頭辞のみのトークンは非空なら通常識別子として受理する。
        "DocumentRef-x",
        "UNLICENSED",
        "Proprietary",
    };
    for (accepted) |license| {
        const source = try std.fmt.allocPrint(allocator, base, .{license});
        defer allocator.free(source);
        var manifest = try parseOk(allocator, source);
        defer manifest.deinit();
    }
    const rejected = [_][]const u8{
        "definitely not a license",
        "MIT OR",
        "OR MIT",
        "MIT (Apache-2.0",
        "MIT)",
        "",
        "A+B",
        "MIT WITH",
        "MIT AND OR X",
        // 例外識別子に `:`（DocumentRef 複合形）は許容しない。
        "MIT WITH A:B",
        // `+` 接尾は例外識別子にも許容しない。
        "MIT WITH Foo+",
        // コロンは DocumentRef-<id>:LicenseRef-<id> 複合形のみ許容する。
        "MIT:Foo",
        "a:b:c",
        "DocumentRef-:LicenseRef-x",
        "DocumentRef-a:LicenseRef-",
        "DocumentRef-a:MIT",
        "Foo:LicenseRef-x",
        "DocumentRef-a:LicenseRef-b:c",
        // Ref 形には `+` 接尾を付けられず、idstring は非空必須。
        "LicenseRef-x+",
        "LicenseRef-",
        "DocumentRef-",
        "DocumentRef-a:LicenseRef-b+",
        "+",
        "+X",
        "AND+",
        "WITH+",
        // 有効な複合形も例外識別子には使えない。
        "MIT WITH DocumentRef-a:LicenseRef-b",
    };
    for (rejected) |license| {
        const source = try std.fmt.allocPrint(allocator, base, .{license});
        defer allocator.free(source);
        try parseErrCode(allocator, source, diag.E029_INVALID_VALUE);
    }
    // 括弧ネストは32段まで（32段は受理、33段は拒否）。
    var boundary = std.ArrayList(u8).empty;
    defer boundary.deinit(allocator);
    for (0..32) |_| try boundary.append(allocator, '(');
    try boundary.appendSlice(allocator, "MIT");
    for (0..32) |_| try boundary.append(allocator, ')');
    const boundary_source = try std.fmt.allocPrint(allocator, base, .{boundary.items});
    defer allocator.free(boundary_source);
    var boundary_manifest = try parseOk(allocator, boundary_source);
    defer boundary_manifest.deinit();
    var deep = std.ArrayList(u8).empty;
    defer deep.deinit(allocator);
    for (0..33) |_| try deep.append(allocator, '(');
    try deep.appendSlice(allocator, "MIT");
    for (0..33) |_| try deep.append(allocator, ')');
    const deep_source = try std.fmt.allocPrint(allocator, base, .{deep.items});
    defer allocator.free(deep_source);
    try parseErrCode(allocator, deep_source, diag.E029_INVALID_VALUE);
}

test "同一public-idの3者間衝突とfeature名規則を診断する" {
    const allocator = std.testing.allocator;
    // `>=1 <3` は `^1`/`^2` のどちらとも交差するが `^1` と `^2` は互いに衝突する。
    const three_way =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\one = { version = ">=1.0.0 <3.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\two = { version = "^1.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\three = { version = "^2.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    try parseErrCode(allocator, three_way, diag.E003_CONFLICTING_VERSIONS);

    // OR 範囲では各ペアが別の選択肢で交差しても全体の共通部分は空に
    // なり得る。`<2 || >=4`、`>=1 <3`、`>=2.5 <5` は二者毎には交差するが
    // 三者を同時に満たすバージョンは存在しない。
    const joint_empty =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\one = { version = "<2.0.0 || >=4.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\two = { version = ">=1.0.0 <3.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\three = { version = ">=2.5.0 <5.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    try parseErrCode(allocator, joint_empty, diag.E003_CONFLICTING_VERSIONS);

    // 各制約を順に積集合しても共通部分が残る場合は受理する。
    const joint_ok =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\one = { version = "<2.0.0 || >=4.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\two = { version = ">=1.0.0 <3.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\three = { version = ">=1.5.0 <1.9.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    var joint_manifest = try parseOk(allocator, joint_ok);
    defer joint_manifest.deinit();

    // 積集合の構成集合を併合すると別の依存が持つ prerelease 比較子で
    // ゲートを通過してしまう。`b` は 1.5.0 の prerelease 比較子を持たず
    // `c` の候補（1.5.0 prerelease のみ）を受理しないため非交差。
    const laundered_gate =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\a = { version = ">=1.5.0-alpha <2.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\b = { version = ">=1.0.0 <1.9.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\c = { version = ">=1.5.0-beta <1.5.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    try parseErrCode(allocator, laundered_gate, diag.E003_CONFLICTING_VERSIONS);

    // exact 版のゲートも同様。`=1.5.0-beta` は `>=1.0.0` の集合で
    // prerelease ゲートを通らない。
    const laundered_exact =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\a = { version = ">=1.5.0-alpha", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\b = { version = ">=1.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\c = { version = "1.5.0-beta", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    try parseErrCode(allocator, laundered_exact, diag.E003_CONFLICTING_VERSIONS);

    // `version = ""` は match-all であり、全バージョンを受理するが
    // prerelease は受理しないため prerelease 専用の制約と衝突する。
    const empty_range =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\a = { version = "", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\b = { version = ">=1.5.0-alpha <1.5.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    try parseErrCode(allocator, empty_range, diag.E003_CONFLICTING_VERSIONS);

    // 開発解決では通常依存と dev-dependencies が同じ public-id に効くため
    // セクションをまたいだ衝突も検出する。
    const cross_section =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\runtime = { version = "^1.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\[dev-dependencies.pkg]
        \\test = { version = "^2.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    try parseErrCode(allocator, cross_section, diag.E003_CONFLICTING_VERSIONS);

    // 隣接タプル間の prerelease 専用区間。`>1.5.0 <1.5.1` の候補は
    // 1.5.1 の prerelease のみで、双方の集合にそのタプルの
    // prerelease 比較子がないため非交差。
    const adjacent =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\a = { version = ">1.5.0 <1.5.1", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\b = { version = ">=1.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    try parseErrCode(allocator, adjacent, diag.E003_CONFLICTING_VERSIONS);

    // `>x` は `<0.0.0-0`（空範囲）に展開されるため `*` とも共通
    // バージョンを持たない。
    const empty_set =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\a = { version = ">x", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\b = { version = "*", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    try parseErrCode(allocator, empty_set, diag.E003_CONFLICTING_VERSIONS);

    // 積集合パス数の上限（1024）を超えた時点で絞り込みを打ち切り
    // 「非空のまま」とみなす。破棄したパスだけが後続の制約を満たす
    // 場合でも、打ち切りによる偽の衝突を報告しない。
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator,
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\d1 = { version = "
    );
    for (0..1024) |i| {
        const piece = try std.fmt.allocPrint(allocator, "{s}>={d}.0.0 <{d}.9.0", .{ if (i == 0) "" else " || ", i, i });
        defer allocator.free(piece);
        try buf.appendSlice(allocator, piece);
    }
    // 上限を超える選択肢 `>=9999.0.0` は破棄されるが、d2 はその
    // 選択肢とのみ整合する。打ち切りを saturated と記録しないと
    // 偽の E003 になる。
    try buf.appendSlice(allocator,
        \\ || >=9999.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\d2 = { version = ">=9999.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    );
    var saturated = try parseOk(allocator, buf.items);
    defer saturated.deinit();

    // 外積が上限に達した場合も同様に絞り込みを打ち切る。d1/d2 の
    // 組合せは 33×33=1089 通りで上限を超え、d3 との真の衝突は
    // saturated により見逃される（誤検出しない方向の近似）。
    var cross_buf: std.ArrayList(u8) = .empty;
    defer cross_buf.deinit(allocator);
    try cross_buf.appendSlice(allocator,
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\d1 = { version = "
    );
    for (0..33) |i| {
        const piece = try std.fmt.allocPrint(allocator, "{s}>=0.{d}.0 <100.0.0", .{ if (i == 0) "" else " || ", i });
        defer allocator.free(piece);
        try cross_buf.appendSlice(allocator, piece);
    }
    try cross_buf.appendSlice(allocator,
        \\", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\d2 = { version = "
    );
    for (0..33) |i| {
        const piece = try std.fmt.allocPrint(allocator, "{s}>=50.{d}.0 <150.0.0", .{ if (i == 0) "" else " || ", i });
        defer allocator.free(piece);
        try cross_buf.appendSlice(allocator, piece);
    }
    try cross_buf.appendSlice(allocator,
        \\", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\d3 = { version = ">=300.0.0 <400.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    );
    var cross_saturated = try parseOk(allocator, cross_buf.items);
    defer cross_saturated.deinit();

    // feature 定義の項目は featureName パターンに一致しなければならない。
    const bad_item =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[features]
        \\web = ["!!"]
        \\
    ;
    try parseErrCode(allocator, bad_item, diag.E029_INVALID_VALUE);

    // nako-version は `^\d+\.\d+\.\d+$` 形式のみ受理する。
    const bad_nako_version =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\nako-version = "1.2.3-alpha"
        \\
    ;
    try parseErrCode(allocator, bad_nako_version, diag.E029_INVALID_VALUE);
    const ok_nako_version =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\nako-version = "3.7.24"
        \\min-nako-version = "3.7.0"
        \\
    ;
    var manifest = try parseOk(allocator, ok_nako_version);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(u64, 7), manifest.package.nako_version.?.minor);

    // path/git/http 依存の空名も拒否する。
    const empty_path_name =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.path]
        \\"" = { path = "x" }
        \\
    ;
    try parseErrCode(allocator, empty_path_name, diag.E029_INVALID_VALUE);
}

/// cwd から上方向に `tools/package-system/conformance` を持つリポジトリルートを探す。
/// `zig build test`（プロジェクトルートが cwd）でも `zig test` を
/// サブディレクトリから直接実行しても動作する。
fn openRepoRoot(io: std.Io) !std.Io.Dir {
    const probe = "tools/package-system/conformance/valid/manifest/minimal/nako.toml";
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

// `tools/package-system/conformance` の manifest fixture を Zig 側でも検証する。
// 期待コードは同ディレクトリの expected.json から読み取る。
test "manifest適合fixtureを検証する" {
    const allocator = std.testing.allocator;
    var repo = try openRepoRoot(std.testing.io);
    defer repo.close(std.testing.io);
    const cases = [_]struct { path: []const u8, expected_code: ?[]const u8 }{
        .{ .path = "tools/package-system/conformance/valid/manifest/minimal/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/features/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/npm-aux/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/path-git/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/profiles/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/license-expression/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/engines-runtimes/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/prefer-native/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/profile-runtime/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/common-source-with-esm/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/native-esm-hybrid/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/esm-only-multi-runtime/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/esm-only-both-runtimes/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/invalid/manifest/empty-runtimes/nako.toml", .expected_code = diag.E029_INVALID_VALUE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/lnako-only-cnako-profile/nako.toml", .expected_code = diag.E006_JS_IN_NORMAL_MODE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/unknown-schema/nako.toml", .expected_code = diag.E001_UNKNOWN_MANIFEST_SCHEMA },
        .{ .path = "tools/package-system/conformance/invalid/manifest/conflicting-version/nako.toml", .expected_code = diag.E003_CONFLICTING_VERSIONS },
        .{ .path = "tools/package-system/conformance/invalid/manifest/conflicting-version-joint/nako.toml", .expected_code = diag.E003_CONFLICTING_VERSIONS },
        .{ .path = "tools/package-system/conformance/invalid/manifest/conflicting-version-prerelease/nako.toml", .expected_code = diag.E003_CONFLICTING_VERSIONS },
        .{ .path = "tools/package-system/conformance/invalid/manifest/conflicting-version-empty-range/nako.toml", .expected_code = diag.E003_CONFLICTING_VERSIONS },
        .{ .path = "tools/package-system/conformance/invalid/manifest/conflicting-version-dev/nako.toml", .expected_code = diag.E003_CONFLICTING_VERSIONS },
        .{ .path = "tools/package-system/conformance/invalid/manifest/conflicting-version-empty-set/nako.toml", .expected_code = diag.E003_CONFLICTING_VERSIONS },
        .{ .path = "tools/package-system/conformance/invalid/manifest/trailing-newline-version/nako.toml", .expected_code = diag.E024_INVALID_SEMVER },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-uri/nako.toml", .expected_code = diag.E029_INVALID_VALUE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/duplicate-exports/nako.toml", .expected_code = diag.E011_DUPLICATE_EXPORT },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-profile/nako.toml", .expected_code = diag.E014_INVALID_PROFILE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/unknown-runtime/nako.toml", .expected_code = diag.E014_INVALID_PROFILE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/unknown-engine/nako.toml", .expected_code = diag.E022_UNKNOWN_FIELD },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-engine-range/nako.toml", .expected_code = diag.E025_INVALID_RANGE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/js-without-compat-js/nako.toml", .expected_code = diag.E006_JS_IN_NORMAL_MODE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/missing-package/nako.toml", .expected_code = diag.E019_REQUIRED_FIELD_MISSING },
        .{ .path = "tools/package-system/conformance/invalid/manifest/unknown-field/nako.toml", .expected_code = diag.E022_UNKNOWN_FIELD },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-type/nako.toml", .expected_code = diag.E023_INVALID_TYPE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-value/nako.toml", .expected_code = diag.E029_INVALID_VALUE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-semver/nako.toml", .expected_code = diag.E024_INVALID_SEMVER },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-range/nako.toml", .expected_code = diag.E025_INVALID_RANGE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/alias-collision/nako.toml", .expected_code = diag.E012_ALIAS_COLLISION },
        .{ .path = "tools/package-system/conformance/invalid/manifest/alias-collision-cross-section/nako.toml", .expected_code = diag.E012_ALIAS_COLLISION },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-license/nako.toml", .expected_code = diag.E029_INVALID_VALUE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-license-document-ref/nako.toml", .expected_code = diag.E029_INVALID_VALUE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/wildcard-prerelease/nako.toml", .expected_code = diag.E025_INVALID_RANGE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/unknown-feature/nako.toml", .expected_code = diag.E028_UNKNOWN_FEATURE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/feature-cycle/nako.toml", .expected_code = diag.E027_FEATURE_CYCLE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/unknown-profile/nako.toml", .expected_code = diag.E030_UNKNOWN_PROFILE },
    };
    for (cases) |case| {
        const source = try repo.readFileAlloc(std.testing.io, case.path, allocator, .limited(1 << 20));
        defer allocator.free(source);
        var list = diag.List.init(allocator);
        defer list.deinit();
        const result = parse(allocator, source, &list);
        if (case.expected_code) |code| {
            try std.testing.expectError(error.InvalidManifest, result);
            if (list.find(code) == null) {
                std.debug.print("{s}: expected diagnostic {s}, got:", .{ case.path, code });
                for (list.items.items) |item| std.debug.print(" {s}", .{item.code});
                std.debug.print("\n", .{});
                return error.TestUnexpectedResult;
            }
        } else {
            var manifest = result catch |err| {
                std.debug.print("{s}: unexpected error {s}, diagnostics:", .{ case.path, @errorName(err) });
                for (list.items.items) |item| std.debug.print(" {s}", .{item.code});
                std.debug.print("\n", .{});
                return error.TestUnexpectedResult;
            };
            defer manifest.deinit();
        }
    }
}

test "manifest解析で確保失敗が診断へ変換されない" {
    // 範囲解析（[dependencies.pkg]・npm短縮形・peer-dependencies の
    // 3経路）等の確保失敗は OutOfMemory として伝播し、
    // E025 等の診断による InvalidManifest にならない。
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\lib = { version = "^1.0.0" }
        \\[dependencies.npm]
        \\leftpad = "^1.0.0"
        \\express = { version = "^4.0.0", peer-dependencies = { ws = "^8" } }
        \\
    ;
    var index: usize = 0;
    while (index < 256) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        var list = diag.List.init(failing.allocator());
        defer list.deinit();
        var manifest = parse(failing.allocator(), source, &list) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer manifest.deinit();
    }
}

test "runtimes、engines、include、prefer-native、profile runtimeを正常に解析する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "nako3-common-kit"
        \\version = "1.0.0"
        \\license = "MIT"
        \\runtimes = ["lnako", "cnako"]
        \\include = ["src/**/*.nako3", "data/*.json"]
        \\
        \\[package.engines]
        \\nako = "^3.7.24"
        \\cnako = ">=3.7.24"
        \\lnako = ">=0.1.0"
        \\
        \\[dependencies.pkg]
        \\fast-math = { version = "^2.0.0", prefer-native = true }
        \\
        \\[profiles.lnako-prof]
        \\runtime = "lnako"
        \\os = "macos"
        \\cpu = "aarch64"
        \\abi = "gnu"
        \\
        \\[profiles.cnako-prof]
        \\runtime = "cnako"
        \\os = "linux"
        \\cpu = "x86_64"
        \\abi = "none"
        \\
        \\[[exports]]
        \\name = "main"
        \\path = "src/main.nako3"
        \\native = "libmain.dylib"
        \\
    ;
    var manifest = try parseOk(allocator, source);
    defer manifest.deinit();

    try std.testing.expectEqual(@as(usize, 2), manifest.package.runtimes.len);
    try std.testing.expectEqualStrings("lnako", manifest.package.runtimes[0]);
    try std.testing.expectEqualStrings("cnako", manifest.package.runtimes[1]);

    try std.testing.expect(manifest.package.include != null);
    try std.testing.expectEqual(@as(usize, 2), manifest.package.include.?.len);

    try std.testing.expect(manifest.package.engines.nako != null);
    try std.testing.expect(manifest.package.engines.cnako != null);
    try std.testing.expect(manifest.package.engines.lnako != null);

    const dep = manifest.dependencies.pkg.get("fast-math").?;
    try std.testing.expect(dep.prefer_native);

    const prof_lnako = manifest.profiles.get("lnako-prof").?;
    try std.testing.expectEqualStrings("lnako", prof_lnako.runtime);

    const prof_cnako = manifest.profiles.get("cnako-prof").?;
    try std.testing.expectEqualStrings("cnako", prof_cnako.runtime);

    // checkRuntime
    var list = diag.List.init(allocator);
    defer list.deinit();
    try std.testing.expect(try manifest.checkRuntime("lnako", &list, .{}));
    try std.testing.expect(try manifest.checkRuntime("cnako", &list, .{}));
    try std.testing.expect(!(try manifest.checkRuntime("browser", &list, .{})));
    try std.testing.expect(list.find(diag.E031_UNSUPPORTED_RUNTIME) != null);

    // runtimes 未宣言（空配列）でも未知の処理系は E031 とする。
    var plain = try parseOk(allocator,
        \\[package]
        \\name = "plain"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
    );
    defer plain.deinit();
    var plain_list = diag.List.init(allocator);
    defer plain_list.deinit();
    try std.testing.expect(!(try plain.checkRuntime("browser", &plain_list, .{})));
    try std.testing.expect(plain_list.find(diag.E031_UNSUPPORTED_RUNTIME) != null);
    try std.testing.expect(try plain.checkRuntime("lnako", &plain_list, .{}));

    // checkEngines
    const v_nako = try semver.Version.parse("3.7.24");
    const v_cnako = try semver.Version.parse("3.7.25");
    const v_lnako = try semver.Version.parse("0.2.0");
    try std.testing.expect(try manifest.checkEngines(v_nako, v_cnako, v_lnako, &list, .{}));

    const v_old_cnako = try semver.Version.parse("3.6.0");
    try std.testing.expect(!(try manifest.checkEngines(v_nako, v_old_cnako, v_lnako, &list, .{})));
    try std.testing.expect(list.find(diag.E032_ENGINE_MISMATCH) != null);

    // 判定対象バージョンが不明（null）なキーは制約を未検査として成功扱いする
    var unknown_list = diag.List.init(allocator);
    defer unknown_list.deinit();
    try std.testing.expect(try manifest.checkEngines(null, null, null, &unknown_list, .{}));
    try std.testing.expect(unknown_list.find(diag.E032_ENGINE_MISMATCH) == null);
}

test "不正なruntimeやengineフィールドを診断する" {
    const allocator = std.testing.allocator;

    // 不正なpackage.runtimes
    try parseErrCode(allocator,
        \\[package]
        \\name = "pkg"
        \\version = "1.0.0"
        \\license = "MIT"
        \\runtimes = ["browser"]
        \\
    , diag.E029_INVALID_VALUE);

    // 明示的な空配列は未指定と区別して拒否する
    try parseErrCode(allocator,
        \\[package]
        \\name = "pkg"
        \\version = "1.0.0"
        \\license = "MIT"
        \\runtimes = []
        \\
    , diag.E029_INVALID_VALUE);

    // 不正なprofile runtime
    try parseErrCode(allocator,
        \\[package]
        \\name = "pkg"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[profiles.p]
        \\runtime = "invalid-runtime"
        \\os = "linux"
        \\cpu = "x86_64"
        \\abi = "gnu"
        \\
    , diag.E014_INVALID_PROFILE);

    // 未知のengineキー
    try parseErrCode(allocator,
        \\[package]
        \\name = "pkg"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[package.engines]
        \\python = ">=3.10"
        \\
    , diag.E022_UNKNOWN_FIELD);

    // 不正なengine range
    try parseErrCode(allocator,
        \\[package]
        \\name = "pkg"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[package.engines]
        \\nako = "not-a-semver-range"
        \\
    , diag.E025_INVALID_RANGE);
}

test "exportの実装選択契約（共通ソース優先・明示native選択・ESM制約）" {
    const allocator = std.testing.allocator;
    var list = diag.List.init(allocator);
    defer list.deinit();

    // 1. path と native の両方がある場合: 既定では共通ソース（path）が優先
    const dual_export = manifest_mod.Export{
        .name = "dual",
        .path = "src/dual.nako3",
        .native = &.{.{ .path = "libdual.dylib" }},
    };
    const def_lnako = (try dual_export.resolve(allocator, .{ .runtime = "lnako" }, false, &list)).?;
    try std.testing.expectEqual(manifest_mod.ResolvedExportKind.source, def_lnako.kind);
    try std.testing.expectEqualStrings("src/dual.nako3", def_lnako.target);

    const def_cnako = (try dual_export.resolve(allocator, .{ .runtime = "cnako" }, false, &list)).?;
    try std.testing.expectEqual(manifest_mod.ResolvedExportKind.source, def_cnako.kind);

    // 2. prefer_native = true の場合: lnako では native が選択される
    const native_lnako = (try dual_export.resolve(allocator, .{ .runtime = "lnako" }, true, &list)).?;
    try std.testing.expectEqual(manifest_mod.ResolvedExportKind.native, native_lnako.kind);
    try std.testing.expectEqualStrings("libdual.dylib", native_lnako.target);

    // 3. prefer_native = true は lnako のみ有効。cnako では共通ソース（path）が選ばれる
    const native_cnako = (try dual_export.resolve(allocator, .{ .runtime = "cnako" }, true, &list)).?;
    try std.testing.expectEqual(manifest_mod.ResolvedExportKind.source, native_cnako.kind);
    try std.testing.expectEqualStrings("src/dual.nako3", native_cnako.target);

    // 4. native + esm ハイブリッド（pathなし）:
    //    lnako では native が選択され、cnako では native に遮られず esm が選択される
    const hybrid_export = manifest_mod.Export{
        .name = "codec",
        .native = &.{.{ .path = "codec.so" }},
        .esm = &.{.{ .path = "codec.mjs" }},
    };
    const hybrid_lnako = (try hybrid_export.resolve(allocator, .{ .runtime = "lnako" }, false, &list)).?;
    try std.testing.expectEqual(manifest_mod.ResolvedExportKind.native, hybrid_lnako.kind);
    try std.testing.expectEqualStrings("codec.so", hybrid_lnako.target);

    const hybrid_cnako = (try hybrid_export.resolve(allocator, .{ .runtime = "cnako" }, false, &list)).?;
    try std.testing.expectEqual(manifest_mod.ResolvedExportKind.esm, hybrid_cnako.kind);
    try std.testing.expectEqualStrings("codec.mjs", hybrid_cnako.target);

    // 5. native専用package: lnako ではOK、cnako ではエラー（E031）
    const native_only = manifest_mod.Export{
        .name = "nat",
        .native = &.{.{ .path = "libnat.so" }},
    };
    const nat_ok = (try native_only.resolve(allocator, .{ .runtime = "lnako" }, false, &list)).?;
    try std.testing.expectEqual(manifest_mod.ResolvedExportKind.native, nat_ok.kind);
    const nat_fail = try native_only.resolve(allocator, .{ .runtime = "cnako" }, false, &list);
    try std.testing.expect(nat_fail == null);
    try std.testing.expect(list.find(diag.E031_UNSUPPORTED_RUNTIME) != null);

    // 6. ESM専用package: cnako ではOK、lnako 通常モードはE006、compat-js有効時はOK
    const esm_only = manifest_mod.Export{
        .name = "esm",
        .esm = &.{.{ .path = "index.mjs" }},
    };
    const esm_cnako = (try esm_only.resolve(allocator, .{ .runtime = "cnako" }, false, &list)).?;
    try std.testing.expectEqual(manifest_mod.ResolvedExportKind.esm, esm_cnako.kind);

    const esm_lnako_normal = try esm_only.resolve(allocator, .{ .runtime = "lnako" }, false, &list);
    try std.testing.expect(esm_lnako_normal == null);
    try std.testing.expect(list.find(diag.E006_JS_IN_NORMAL_MODE) != null);

    const esm_lnako_compat = (try esm_only.resolve(allocator, .{ .runtime = "lnako", .compat_js = true }, false, &list)).?;
    try std.testing.expectEqual(manifest_mod.ResolvedExportKind.esm, esm_lnako_compat.kind);

    // 7. 実装なしexport: E019
    const empty_export = manifest_mod.Export{ .name = "empty" };
    const empty_res = try empty_export.resolve(allocator, .{ .runtime = "lnako" }, false, &list);
    try std.testing.expect(empty_res == null);
    try std.testing.expect(list.find(diag.E019_REQUIRED_FIELD_MISSING) != null);

    // 8. 共通ソース（path）+ ESM: 通常モードでも path が選ばれ E006 にならない
    const source_esm = manifest_mod.Export{
        .name = "src-esm",
        .path = "src/main.nako3",
        .esm = &.{.{ .path = "main.mjs" }},
    };
    const source_esm_lnako = (try source_esm.resolve(allocator, .{ .runtime = "lnako" }, false, &list)).?;
    try std.testing.expectEqual(manifest_mod.ResolvedExportKind.source, source_esm_lnako.kind);
    const source_esm_cnako = (try source_esm.resolve(allocator, .{ .runtime = "cnako" }, false, &list)).?;
    try std.testing.expectEqual(manifest_mod.ResolvedExportKind.source, source_esm_cnako.kind);

    // 9. 未知の処理系は path があっても E031 で拒否する
    var unknown_list = diag.List.init(allocator);
    defer unknown_list.deinit();
    const unknown_res = try source_esm.resolve(allocator, .{ .runtime = "browser" }, false, &unknown_list);
    try std.testing.expect(unknown_res == null);
    try std.testing.expect(unknown_list.find(diag.E031_UNSUPPORTED_RUNTIME) != null);
}

test "cnako向けマニフェストでのESM exportを正常に受理する" {
    const allocator = std.testing.allocator;

    // package.runtimes = ["cnako"] の cnako 専用パッケージは compat-js なしでも ESM export を受理
    var m1 = try parseOk(allocator,
        \\[package]
        \\name = "cnako-esm-pkg"
        \\version = "1.0.0"
        \\license = "MIT"
        \\runtimes = ["cnako"]
        \\
        \\[profiles.default]
        \\os = "macos"
        \\cpu = "aarch64"
        \\abi = "gnu"
        \\compat-js = false
        \\
        \\[[exports]]
        \\name = "main"
        \\esm = "main.mjs"
        \\
    );
    defer m1.deinit();
    try std.testing.expectEqual(@as(usize, 1), m1.exports.len);

    // profiles に runtime = "cnako" を含む場合も ESM export を受理
    var m2 = try parseOk(allocator,
        \\[package]
        \\name = "multi-runtime-pkg"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[profiles.node]
        \\runtime = "cnako"
        \\os = "linux"
        \\cpu = "x86_64"
        \\abi = "gnu"
        \\compat-js = false
        \\
        \\[[exports]]
        \\name = "main"
        \\esm = "main.mjs"
        \\
    );
    defer m2.deinit();
    try std.testing.expectEqual(@as(usize, 1), m2.exports.len);
}

test "native/esmの構造化artifact宣言を解析する" {
    const allocator = std.testing.allocator;
    var manifest = try parseOk(allocator,
        \\[package]
        \\name = "multi-artifact"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[features]
        \\simd = []
        \\
        \\[[exports]]
        \\name = "main"
        \\path = "src/main.nako3"
        \\native = [
        \\  { path = "lib/a.dylib", when = "os == 'macos'", min-os = "14.0" },
        \\  { path = "lib/a.so", when = "os == 'linux'", libc = "gnu", features = ["simd"] },
        \\  "lib/fallback.so",
        \\]
        \\
        \\[[exports]]
        \\name = "web"
        \\esm = { path = "dist/web.mjs" }
        \\
    );
    defer manifest.deinit();

    try std.testing.expectEqual(@as(usize, 2), manifest.exports.len);
    const main = manifest.exports[0];
    try std.testing.expectEqual(@as(usize, 3), main.native.len);
    try std.testing.expectEqualStrings("lib/a.dylib", main.native[0].path);
    try std.testing.expectEqualStrings("os == 'macos'", main.native[0].when.?);
    try std.testing.expectEqualStrings("14.0", main.native[0].min_os.?);
    try std.testing.expectEqualStrings("lib/a.so", main.native[1].path);
    try std.testing.expectEqualStrings("gnu", main.native[1].libc.?);
    try std.testing.expectEqualStrings("simd", main.native[1].features[0]);
    try std.testing.expectEqualStrings("lib/fallback.so", main.native[2].path);
    try std.testing.expect(main.native[2].when == null);

    const web = manifest.exports[1];
    try std.testing.expectEqual(@as(usize, 1), web.esm.len);
    try std.testing.expectEqualStrings("dist/web.mjs", web.esm[0].path);
}

test "artifact条件の未定義feature名を診断する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\native = [{ path = "lib/a.so", features = ["typoed"] }]
        \\
    ;
    try parseErrCode(allocator, source, diag.E028_UNKNOWN_FEATURE);
}

test "artifact条件は対象環境へ照合される" {
    const allocator = std.testing.allocator;
    const decl = manifest_mod.ArtifactDecl{
        .path = "lib/a.so",
        .when = "os == 'linux'",
        .libc = "gnu",
        .features = &.{"simd"},
    };
    try std.testing.expect(try decl.matchesTarget(allocator, .{
        .runtime = "lnako",
        .os = "linux",
        .abi = "gnu",
        .features = &.{"simd"},
    }, true));
    // when が偽の場合は不適合
    try std.testing.expect(!try decl.matchesTarget(allocator, .{
        .runtime = "lnako",
        .os = "macos",
        .abi = "gnu",
        .features = &.{"simd"},
    }, true));
    // libc 不一致は不適合
    try std.testing.expect(!try decl.matchesTarget(allocator, .{
        .runtime = "lnako",
        .os = "linux",
        .abi = "musl",
        .features = &.{"simd"},
    }, true));
    // 要求 feature が対象に無ければ不適合
    try std.testing.expect(!try decl.matchesTarget(allocator, .{
        .runtime = "lnako",
        .os = "linux",
        .abi = "gnu",
    }, true));
    // check_features=false なら feature 要件は未評価（候補段階の用途）
    try std.testing.expect(try decl.matchesTarget(allocator, .{
        .runtime = "lnako",
        .os = "linux",
        .abi = "gnu",
    }, false));

    // min-os: 対象 os_version が下限以上なら適合、未指定なら証明不能で不適合
    const gated = manifest_mod.ArtifactDecl{
        .path = "lib/a.dylib",
        .min_os = "14.0",
    };
    try std.testing.expect(try gated.matchesTarget(allocator, .{ .runtime = "lnako", .os = "macos", .os_version = "15.1" }, true));
    try std.testing.expect(try gated.matchesTarget(allocator, .{ .runtime = "lnako", .os = "macos", .os_version = "14.0" }, true));
    try std.testing.expect(!try gated.matchesTarget(allocator, .{ .runtime = "lnako", .os = "macos", .os_version = "13.9" }, true));
    try std.testing.expect(!try gated.matchesTarget(allocator, .{ .runtime = "lnako", .os = "macos" }, true));
}

test "条件付きartifactは対象へ適合する宣言だけを選択する" {
    const allocator = std.testing.allocator;
    var list = diag.List.init(allocator);
    defer list.deinit();

    const conditional = manifest_mod.Export{
        .name = "cond",
        .native = &.{
            .{ .path = "lib/linux.so", .when = "os == 'linux'" },
            .{ .path = "lib/macos.dylib", .when = "os == 'macos'" },
        },
    };
    // 対象 os が与えられた場合は一致する宣言だけが選ばれる
    const linux = (try conditional.resolve(allocator, .{ .runtime = "lnako", .os = "linux", .abi = "gnu" }, false, &list)).?;
    try std.testing.expectEqualStrings("lib/linux.so", linux.target);
    const macos = (try conditional.resolve(allocator, .{ .runtime = "lnako", .os = "macos", .abi = "none" }, false, &list)).?;
    try std.testing.expectEqualStrings("lib/macos.dylib", macos.target);
    // 対象情報が無い最小ターゲットでは条件付き宣言は選択されない
    const unknown = try conditional.resolve(allocator, .{ .runtime = "lnako" }, false, &list);
    try std.testing.expect(unknown == null);
}

test "不正なartifact宣言を拒否する" {
    const allocator = std.testing.allocator;
    // テーブルに path が無い
    try parseErrCode(allocator,
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "x"
        \\native = { when = "os == 'linux'" }
        \\
    , diag.E019_REQUIRED_FIELD_MISSING);
    // when の marker 構文エラー
    try parseErrCode(allocator,
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "x"
        \\native = { path = "a.so", when = "os ==" }
        \\
    , diag.E026_INVALID_MARKER);
    // 未知フィールド
    try parseErrCode(allocator,
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "x"
        \\native = { path = "a.so", arch = "x86_64" }
        \\
    , diag.E022_UNKNOWN_FIELD);
    // 不正な min-os
    try parseErrCode(allocator,
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "x"
        \\native = { path = "a.so", min-os = "ventura" }
        \\
    , diag.E029_INVALID_VALUE);
    // 不正な libc
    try parseErrCode(allocator,
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "x"
        \\native = { path = "a.so", libc = "glibc2" }
        \\
    , diag.E029_INVALID_VALUE);
    // 空配列
    try parseErrCode(allocator,
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "x"
        \\native = []
        \\
    , diag.E029_INVALID_VALUE);
    // 配列内の数値要素
    try parseErrCode(allocator,
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "x"
        \\native = [42]
        \\
    , diag.E023_INVALID_TYPE);
}
