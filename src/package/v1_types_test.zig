const std = @import("std");
const v1 = @import("v1_types.zig");
const semver = @import("semver.zig");
const spdx = @import("v1_spdx.zig");

fn satisfies(allocator: std.mem.Allocator, range_text: []const u8, version_text: []const u8) !bool {
    var range = try v1.parseRange(allocator, range_text);
    defer range.deinit(allocator);
    const version = try semver.Version.parse(version_text);
    return range.satisfies(version);
}

test "ID-01 通常のPackage IDを受理する" {
    // 要件 §1.1 の scope 2..39 文字・name 1..64 文字の境界を含む。
    try std.testing.expect(v1.validId("@soramikan/http"));
    try std.testing.expect(v1.validId("@a1/pkg-2"));
    try std.testing.expect(v1.validId("@ab/c"));
    try std.testing.expect(v1.validId("@a2345678901234567890123456789012345678/x"));
    try std.testing.expect(!v1.validId("@a/x"));
    var name_64: [64]u8 = undefined;
    @memset(&name_64, 'a');
    var id: [68]u8 = undefined;
    id[0] = '@';
    id[1] = 'a';
    id[2] = 'b';
    id[3] = '/';
    @memcpy(id[4..], &name_64);
    try std.testing.expect(v1.validId(&id));
    var name_65: [65]u8 = undefined;
    @memset(&name_65, 'a');
    var long_id: [69]u8 = undefined;
    long_id[0] = '@';
    long_id[1] = 'a';
    long_id[2] = 'b';
    long_id[3] = '/';
    @memcpy(long_id[4..], &name_65);
    try std.testing.expect(!v1.validId(&long_id));
}

test "ID-02 スコープのないIDを拒否する" {
    try std.testing.expect(!v1.validId("http"));
    try std.testing.expect(!v1.validId("@http"));
    try std.testing.expect(!v1.validId("@/http"));
    try std.testing.expect(!v1.validId("@scope/"));
}

test "ID-03 大文字を含むIDを拒否する" {
    try std.testing.expect(!v1.validId("@Std/pkg"));
    try std.testing.expect(!v1.validId("@std/Pkg"));
}

test "ID-04 予約スコープは構文上有効で予約判定だけが別である" {
    // 依存の ID としては構文上有効。存在確認は解決側の責務。
    try std.testing.expect(v1.validId("@std/foo"));
    try std.testing.expect(v1.validId("@std/json"));
    try std.testing.expect(v1.isReservedScope("std"));
    try std.testing.expect(v1.isReservedId("@std/json"));
    try std.testing.expect(v1.isReservedId("@nako/legacy-dsl"));
    // 一般 scope は予約ではない。
    try std.testing.expect(!v1.isReservedScope("example"));
    try std.testing.expect(!v1.isReservedId("@example/demo"));
    // 予約語に似ただけの scope は予約ではない。
    try std.testing.expect(!v1.isReservedScope("stdlib"));
    try std.testing.expect(!v1.isReservedId("@stdlib/json"));
}

test "ID-05 連続・末尾ハイフンのIDを拒否する" {
    try std.testing.expect(!v1.validId("@a--b/c"));
    try std.testing.expect(!v1.validId("@ab-/c"));
    try std.testing.expect(!v1.validId("@ab/c-"));
    try std.testing.expect(!v1.validId("@ab/c--d"));
    // 単独ハイフンは許容する。
    try std.testing.expect(v1.validId("@a-b/c-d"));
}

test "ID-06 公開バージョンはprereleaseを受理しbuild metadataを拒否する" {
    try std.testing.expect(v1.validPublicVersion("1.2.0-rc.1"));
    try std.testing.expect(!v1.validPublicVersion("01.2.0"));
    try std.testing.expect(!v1.validPublicVersion("1.2.0-01"));
    try std.testing.expect(!v1.validPublicVersion("1.2.0+rev"));
    try std.testing.expect(v1.validPublicVersion("0.0.1"));
    try std.testing.expect(v1.validPublicVersion("1.2.3-alpha.10.beta"));
    try std.testing.expect(!v1.validPublicVersion("1.2"));
    try std.testing.expect(!v1.validPublicVersion("v1.2.3"));
}

test "ID-06b 公開バージョンは数値幅に依存せず3要素とprereleaseを検証する" {
    // 数値幅の境界。node-semver の MAX_SAFE_INTEGER も u64 も超えてよい。
    try std.testing.expect(v1.validPublicVersion("9007199254740991.0.0"));
    try std.testing.expect(v1.validPublicVersion("9007199254740992.0.0"));
    try std.testing.expect(v1.validPublicVersion("18446744073709551615.0.0"));
    try std.testing.expect(v1.validPublicVersion("18446744073709551616.0.0"));
    try std.testing.expect(v1.validPublicVersion("9999999999999999999999999999999999999999.0.0"));
    try std.testing.expect(v1.validPublicVersion("0.0.9007199254740992"));
    try std.testing.expect(!v1.validPublicVersion("9007199254740992"));

    // ゼロは各要素と prerelease で単独なら有効。先行ゼロは拒否する。
    try std.testing.expect(v1.validPublicVersion("0.0.0"));
    try std.testing.expect(v1.validPublicVersion("0.0.0-0"));
    try std.testing.expect(v1.validPublicVersion("0.0.0-0.0.0"));
    try std.testing.expect(!v1.validPublicVersion("00.0.0"));
    try std.testing.expect(!v1.validPublicVersion("0.00.0"));
    try std.testing.expect(!v1.validPublicVersion("0.0.00"));
    try std.testing.expect(!v1.validPublicVersion("0.0.0-00"));
    try std.testing.expect(!v1.validPublicVersion("0.0.0-01"));

    // prerelease は英数字とハイフンのドット区切り。空識別子は拒否する。
    try std.testing.expect(v1.validPublicVersion("1.2.3-alpha"));
    try std.testing.expect(v1.validPublicVersion("1.2.3-alpha.1"));
    try std.testing.expect(v1.validPublicVersion("1.2.3-0.3.7"));
    try std.testing.expect(v1.validPublicVersion("1.2.3-x.7.z.92"));
    try std.testing.expect(v1.validPublicVersion("1.2.3-x-y-z.--"));
    try std.testing.expect(!v1.validPublicVersion("1.2.3-"));
    try std.testing.expect(!v1.validPublicVersion("1.2.3-alpha..1"));
    try std.testing.expect(!v1.validPublicVersion("1.2.3-alpha_1"));
    try std.testing.expect(!v1.validPublicVersion("1.2.3-α"));

    // build metadata は禁止する。
    try std.testing.expect(!v1.validPublicVersion("1.2.3+build"));
    try std.testing.expect(!v1.validPublicVersion("1.2.3-rc.1+build.5"));
    try std.testing.expect(!v1.validPublicVersion("1.2.3-rc.1+"));

    // 3 要素固定。
    try std.testing.expect(!v1.validPublicVersion("1.2"));
    try std.testing.expect(!v1.validPublicVersion("1.2.3.4"));
    try std.testing.expect(!v1.validPublicVersion("1.2."));
    try std.testing.expect(!v1.validPublicVersion("1..3"));
    try std.testing.expect(!v1.validPublicVersion("v1.2.3"));

    // 公開構文の受理と range 側の node-semver 制限は独立している。
    try std.testing.expectError(error.InvalidSemver, semver.Version.parse("9007199254740992.0.0"));
}

test "ID-07 node-semver既定動作のcaretとprerelease境界を照合する" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try satisfies(allocator, "^1.2.3", "1.9.0"));
    try std.testing.expect(!try satisfies(allocator, "^1.2.3 >=2.0.0-alpha.1", "2.0.0-alpha.2"));
    // caret の上限は `<2.0.0-0`。2.0.0 の prerelease を巻き込まない。
    try std.testing.expect(!try satisfies(allocator, "^1.2.3", "2.0.0-alpha.0"));
    try std.testing.expect(!try satisfies(allocator, "^0.0.3", "0.0.4-0"));
    try std.testing.expect(try satisfies(allocator, "^1.2.3-alpha.1", "1.2.3-alpha.2"));
}

test "#8 v1範囲はnode-semver 7.7.4のwildcardとqualifierを受理する" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "1.x.5", "*.1", "*.*.*-alpha" }) |text| {
        try std.testing.expect(v1.validRange(allocator, text));
    }
    // `1.x.5` は `>=1.0.0 <2.0.0-0`、`*.1`/`*.*.*-alpha` は `*`。
    try std.testing.expect(try satisfies(allocator, "1.x.5", "1.9.9"));
    try std.testing.expect(!try satisfies(allocator, "1.x.5", "2.0.0"));
    try std.testing.expect(!try satisfies(allocator, "1.x.5", "2.0.0-alpha"));
    try std.testing.expect(try satisfies(allocator, "*.1", "9.9.9"));
    try std.testing.expect(!try satisfies(allocator, "*.1", "1.0.0-alpha"));
    try std.testing.expect(try satisfies(allocator, "*.*.*-alpha", "9.9.9"));
    try std.testing.expect(!try satisfies(allocator, "*.*.*-alpha", "1.0.0-alpha"));
    // qualifier は wildcard 位置で node-semver と同じく捨てる。
    try std.testing.expect(try satisfies(allocator, "1.x.5-alpha", "1.5.0"));
    try std.testing.expect(!try satisfies(allocator, "1.x.5-alpha", "1.5.0-alpha"));
    // node-semver 7.7.4 の演算子・v/= 前置・hyphen の組合せ。
    for ([_][]const u8{ "^=1.2.3", "~=1.2.3", ">=vv1.2", "v1.2.3", "1.2.3 - 2.0.0" }) |text| {
        try std.testing.expect(v1.validRange(allocator, text));
    }
    // Node の Range は ECMAScript 空白を正規化する。
    try std.testing.expect(v1.validRange(allocator, "\u{00A0}^1.2.3\u{00A0}"));
    try std.testing.expect(try satisfies(allocator, "\u{00A0}^1.2.3\u{00A0}", "1.9.9"));
    try std.testing.expect(try satisfies(allocator, "^=1.2.3", "1.9.9"));
    try std.testing.expect(try satisfies(allocator, "~=1.2.3", "1.2.9"));
    try std.testing.expect(try satisfies(allocator, ">=vv1.2", "1.2.0"));
    try std.testing.expect(try satisfies(allocator, "1.2.3 - 2.0.0", "2.0.0"));
    for ([_][]const u8{ ">=vv1.2.3", "v=1.2.3", "1.2.3 - 2.0.0 >=1" }) |text| {
        try std.testing.expect(!v1.validRange(allocator, text));
    }
    var legacy_operator = semver.Range.parse(allocator, "^=1.2.3") catch null;
    if (legacy_operator) |*value| {
        value.deinit(allocator);
        return error.TestUnexpectedResult;
    }
    // 不正形と旧 API 専用の厳格規則は v1 へ持ち込まない。
    try std.testing.expect(!v1.validRange(allocator, "1.x.5.6"));
    try std.testing.expect(!v1.validRange(allocator, "*.1.2.3"));
    try std.testing.expect(!v1.validRange(allocator, "*-alpha"));
    var legacy = semver.Range.parse(allocator, "1.x.5") catch null;
    if (legacy) |*value| {
        value.deinit(allocator);
        return error.TestUnexpectedResult;
    }
}

test "node-semver境界: tilde・wildcard・比較演算子の上端" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try satisfies(allocator, "~1.2.3", "1.3.0-0"));
    try std.testing.expect(try satisfies(allocator, "~1.2.3", "1.2.9"));
    try std.testing.expect(!try satisfies(allocator, "1.2.x", "1.3.0-alpha"));
    try std.testing.expect(!try satisfies(allocator, "1.x", "2.0.0-alpha"));
    try std.testing.expect(!try satisfies(allocator, "<=1.2", "1.3.0-alpha"));
    try std.testing.expect(!try satisfies(allocator, "<1.2", "1.2.0-alpha"));
    try std.testing.expect(!try satisfies(allocator, "1.2.3 - 2.3", "2.4.0-alpha"));
    try std.testing.expect(try satisfies(allocator, ">1.2", "1.3.0"));
    try std.testing.expect(!try satisfies(allocator, ">1.2", "1.3.0-alpha"));
}

test "ハッシュ・target triple・glibc最小版を検証する" {
    try std.testing.expect(v1.validHash("sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    try std.testing.expect(v1.validHash("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!v1.validHash("sha256:BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"));
    try std.testing.expect(!v1.validHash("sha256:abc"));
    try std.testing.expect(!v1.validHash("sha512:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    // ASCII の 0-9 と a-f だけを受理する。g-z は 64 桁でも拒否する。
    try std.testing.expect(!v1.validHash("sha256:gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg"));
    try std.testing.expect(!v1.validHash("sha256:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
    try std.testing.expect(!v1.validHash("sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ag"));
    try std.testing.expect(!v1.validHash("sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015az"));

    const triples = [_][]const u8{
        "aarch64-macos-none",
        "x86_64-linux-gnu",
        "x86_64-linux-musl",
        "x86_64-windows-msvc",
        "aarch64-linux-musleabihf",
    };
    for (triples) |triple| try std.testing.expect(v1.validTargetTriple(triple));
    const bad = [_][]const u8{
        "x86_64-linux",
        "x86_64-linux-gnu-extra",
        "X86_64-linux-gnu",
        "x86_64-freebsd-msvc",
        "x86_64",
        "-linux-gnu",
    };
    for (bad) |triple| try std.testing.expect(!v1.validTargetTriple(triple));

    try std.testing.expect(v1.validGlibcVersion("2.31"));
    try std.testing.expect(v1.validGlibcVersion("2.17.1"));
    try std.testing.expect(!v1.validGlibcVersion("2"));
    try std.testing.expect(!v1.validGlibcVersion("2."));
    try std.testing.expect(!v1.validGlibcVersion("v2.31"));
}

test "SPDX式と固定ライセンス一覧を検証する" {
    try std.testing.expect(v1.validLicense("MIT"));
    try std.testing.expect(v1.validLicense("Mit"));
    try std.testing.expect(v1.validLicense("mit"));
    try std.testing.expect(v1.validLicense("Apache-2.0 WITH LLVM-exception"));
    try std.testing.expect(v1.validLicense("Apache-2.0 WITH llvm-exception"));
    try std.testing.expect(v1.validLicense("(MIT OR Apache-2.0) AND BSD-3-Clause"));
    try std.testing.expect(v1.validLicense("LicenseRef-Demo"));
    try std.testing.expect(v1.validLicense("LicenseRef-Demo WITH LLVM-exception"));
    try std.testing.expect(!v1.validLicense("MIT AND"));
    try std.testing.expect(!v1.validLicense("NotALicense"));
    // 演算子は大文字だけを受理する（Annex D.2）。
    try std.testing.expect(!v1.validLicense("MIT and Apache-2.0"));
    try std.testing.expect(!v1.validLicense("MIT or Apache-2.0"));
    try std.testing.expect(!v1.validLicense("MIT with LLVM-exception"));
    try std.testing.expectEqualStrings("3.27.0", spdx.license_list_version);
}

test "相対パスとglobパターンの禁止形を検証する" {
    try std.testing.expect(v1.validPath("src/main.nako3"));
    try std.testing.expect(v1.validPath("README.md"));
    try std.testing.expect(v1.validPath("src/日本語.nako3"));
    try std.testing.expect(!v1.validPath(""));
    try std.testing.expect(!v1.validPath("/abs/path"));
    try std.testing.expect(!v1.validPath("../evil"));
    try std.testing.expect(!v1.validPath("src/../evil"));
    try std.testing.expect(!v1.validPath("src/./file"));
    try std.testing.expect(!v1.validPath("C:/file"));
    try std.testing.expect(!v1.validPath("src\\file"));
    try std.testing.expect(!v1.validPath("src//file"));
    try std.testing.expect(!v1.validPath("src/file\x7f"));
    try std.testing.expect(v1.validPath("src/*.nako3"));

    try std.testing.expect(v1.validGlobPattern("src/**/*.nako3"));
    try std.testing.expect(v1.validGlobPattern("LICENSE"));
    try std.testing.expect(!v1.validGlobPattern("../**"));
    try std.testing.expect(!v1.validGlobPattern("/src/**"));
}

test "範囲とローカル名の検証" {
    const allocator = std.testing.allocator;
    try std.testing.expect(v1.validRange(allocator, ""));
    try std.testing.expect(v1.validRange(allocator, ">=0.3.0 <1.0.0"));
    try std.testing.expect(v1.validRange(allocator, "^1.2.3 || ~2.0.0"));
    try std.testing.expect(!v1.validRange(allocator, "1.2.3.4"));
    try std.testing.expect(!v1.validRange(allocator, ">="));

    try std.testing.expect(v1.validLocalName("fast_json"));
    try std.testing.expect(v1.validLocalName("ローカル名"));
    try std.testing.expect(!v1.validLocalName(""));
    try std.testing.expect(!v1.validLocalName("a/b"));
    try std.testing.expect(!v1.validLocalName("a b"));
    try std.testing.expect(!v1.validLocalName(".."));
}

test "Runtime・Kind・Binding・Capabilityの写像" {
    try std.testing.expectEqual(v1.Runtime.lnako, v1.parseRuntime("lnako").?);
    try std.testing.expectEqual(v1.Kind.@"native-source", v1.parseKind("native-source").?);
    try std.testing.expectEqual(v1.Binding.global, v1.parseBinding("global").?);
    try std.testing.expectEqual(v1.Capability.@"pure-nako", v1.parseCapability("pure-nako").?);
    try std.testing.expect(v1.parseRuntime("node") == null);
    try std.testing.expectEqualStrings("native-prebuilt", v1.kindName(.@"native-prebuilt"));
}
