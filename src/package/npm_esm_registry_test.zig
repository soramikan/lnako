//! `npm_esm` の #54 回帰テスト（registry / exports / symlink）。
//!
//! bare specifier から `BareRegistry` を構築し、`exports` の pattern・条件・
//! 配列 fallback と、`package_root` の symlink canonicalization を検証する。
//! テスト用 fixture helper もこのファイルが所有する。helper を使わない
//! package.json / 入口解決 / specifier 分解の回帰テストは
//! `npm_esm_entry_test.zig` に分離し、このファイルを 60 KB 未満に保つ。
//! #53 の package.json 本格パース回帰テストは `npm_esm_test.zig` が所有する。

const std = @import("std");
const testing = std.testing;
const npm_esm = @import("npm_esm.zig");

const Allocator = std.mem.Allocator;
const BareRegistry = npm_esm.BareRegistry;
const pickEntryFromPackageJson = npm_esm.pickEntryFromPackageJson;
const resolveEntryInRoot = npm_esm.resolveEntryInRoot;
const resolveSubpathInRoot = npm_esm.resolveSubpathInRoot;
const resolvePackageForRegistry = npm_esm.resolvePackageForRegistry;
const parseBareSpecifier = npm_esm.parseBareSpecifier;

/// テスト用 fixture の追加ファイル。
const TestFile = struct { path: []const u8, data: []const u8 };

/// `parts` を `std.fs.path.join` で連結した期待 path と `actual` を比較する。
/// 解決結果は realpath で canonicalize されるため、Windows では区切りが
/// `\` になる。固定 `/` の suffix 比較ではなく platform の区切りで組み立てて
/// 厳密に比較する。
fn expectJoinedPath(parts: []const []const u8, actual: []const u8) !void {
    const expected = try std.fs.path.join(testing.allocator, parts);
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, actual);
}

/// テスト用: `dir/package.json` と追加ファイルを作り registry へ登録する。
/// `create_root_index` が false の fixture は root 入口を持たない package に
/// なる（exports がサブパスのみを公開する package など）。
fn makeTestRegistryWithRoot(
    gpa: Allocator,
    io: std.Io,
    tmp: *testing.TmpDir,
    dir: []const u8,
    name: []const u8,
    package_json: []const u8,
    files: []const TestFile,
    create_root_index: bool,
) !BareRegistry {
    try tmp.dir.createDirPath(io, dir);
    const pj = try std.fs.path.join(gpa, &.{ dir, "package.json" });
    defer gpa.free(pj);
    try tmp.dir.writeFile(io, .{ .sub_path = pj, .data = package_json });
    if (create_root_index) {
        const root_index = try std.fs.path.join(gpa, &.{ dir, "index.js" });
        defer gpa.free(root_index);
        try tmp.dir.writeFile(io, .{ .sub_path = root_index, .data = "export default 1;\n" });
    }
    for (files) |f| {
        const path = try std.fs.path.join(gpa, &.{ dir, f.path });
        defer gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| {
            try tmp.dir.createDirPath(io, parent);
        }
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = f.data });
    }
    const root = try tmp.dir.realPathFileAlloc(io, dir, gpa);
    defer gpa.free(root);
    var reg: BareRegistry = .{ .gpa = gpa, .io = io };
    errdefer reg.deinit();
    // 入口解決は registry 登録時に行わないため、root 入口を持たない
    // fixture も登録できる（root は bare name の要求時に遅延解決する）。
    const package = try resolvePackageForRegistry(gpa, io, root);
    errdefer package.deinit(gpa);
    const key = try gpa.dupe(u8, name);
    errdefer gpa.free(key);
    try reg.by_name.put(gpa, key, package);
    return reg;
}

fn makeTestRegistry(
    gpa: Allocator,
    io: std.Io,
    tmp: *testing.TmpDir,
    dir: []const u8,
    name: []const u8,
    package_json: []const u8,
    files: []const TestFile,
) !BareRegistry {
    return makeTestRegistryWithRoot(gpa, io, tmp, dir, name, package_json, files, true);
}

test "BareRegistry resolveBare exports subpath" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./sub":"./dist/sub.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "dist/sub.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    const got = try reg.resolveBare("left-pad/sub");
    defer got.deinit(gpa);
    try expectJoinedPath(&.{ got.package_root, "dist", "sub.mjs" }, got.path);
    try testing.expectEqualStrings("pkg", std.fs.path.basename(got.package_root));
}

test "BareRegistry resolveBare scoped exports subpath" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./client":"./dist/client.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "scoped", "@scope/pkg", json, &.{
        .{ .path = "dist/client.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    const got = try reg.resolveBare("@scope/pkg/client");
    defer got.deinit(gpa);
    try expectJoinedPath(&.{ got.package_root, "dist", "client.mjs" }, got.path);
    // 公開キーに一致しない深いサブパスは非公開。
    try testing.expectError(error.BareNotFound, reg.resolveBare("@scope/pkg/client/deep"));
}

test "BareRegistry resolveBare subpath condition import then default" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{
        \\  ".":"./index.js",
        \\  "./cond":{"node":"./node.js","import":"./esm.mjs","default":"./default.js"},
        \\  "./default-only":{"default":"./default.js"},
        \\  "./node-only":{"node":"./node.js"}
        \\}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "esm.mjs", .data = "export default 2;\n" },
        .{ .path = "default.js", .data = "export default 3;\n" },
        .{ .path = "node.js", .data = "module.exports = 4;\n" },
    });
    defer reg.deinit();

    const cond = try reg.resolveBare("left-pad/cond");
    defer cond.deinit(gpa);
    try expectJoinedPath(&.{ cond.package_root, "esm.mjs" }, cond.path);

    const def = try reg.resolveBare("left-pad/default-only");
    defer def.deinit(gpa);
    try expectJoinedPath(&.{ def.package_root, "default.js" }, def.path);

    // node 条件は暗黙に有効化しない。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/node-only"));
}

test "BareRegistry resolveBare rejects unpublished subpath" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./published":"./dist/published.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "dist/published.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/missing"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/published/deep"));
    // exports が文字列（root のみ）の package もサブパスは非公開。
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    var reg2 = try makeTestRegistry(gpa, io, &tmp2, "pkg2", "right-pad", "{\"exports\":\"./index.js\"}", &.{});
    defer reg2.deinit();
    try testing.expectError(error.BareNotFound, reg2.resolveBare("right-pad/sub"));
}

test "BareRegistry resolveBare rejects traversal specifier" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./sub":"./dist/sub.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "dist/sub.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/../evil"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/./sub"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad//sub"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("@scope/pkg/../evil"));
}

test "BareRegistry resolveBare rejects invalid export targets as PackageJsonInvalid" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{
        \\  ".":"./index.js",
        \\  "./up":"../evil.js",
        \\  "./nested-up":"./dist/../../evil.js",
        \\  "./abs":"/tmp/evil.js",
        \\  "./node-modules":"./node_modules/evil.js",
        \\  "./bare-target":"dist/sub.mjs",
        \\  "./dot":"./dist/./sub.mjs"
        \\}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "dist/sub.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // 「未公開（BareNotFound）」と「壊れた/悪意ある package.json」を区別する。
    for ([_][]const u8{
        "left-pad/up",
        "left-pad/nested-up",
        "left-pad/abs",
        "left-pad/node-modules",
        "left-pad/bare-target",
        "left-pad/dot",
    }) |spec| {
        try testing.expectError(error.PackageJsonInvalid, reg.resolveBare(spec));
    }
}

test "BareRegistry resolveBare missing subpath file is EntryNotFound" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./sub":"./dist/sub.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{});
    defer reg.deinit();

    try testing.expectError(error.EntryNotFound, reg.resolveBare("left-pad/sub"));
}

test "BareRegistry resolveBare keeps root entry with subpath exports" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":{"import":"./esm.mjs","default":"./index.js"},"./sub":"./dist/sub.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "esm.mjs", .data = "export default 2;\n" },
        .{ .path = "dist/sub.mjs", .data = "export default 3;\n" },
    });
    defer reg.deinit();

    const root = try reg.resolveBare("left-pad");
    defer root.deinit(gpa);
    try expectJoinedPath(&.{ root.package_root, "esm.mjs" }, root.path);
    try testing.expectEqualStrings("pkg", std.fs.path.basename(root.package_root));
}

test "BareRegistry resolveBare wildcard subpath" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./*":"./src/*.mjs","./features/*":"./feat/*.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "src/foo.mjs", .data = "export default 2;\n" },
        .{ .path = "feat/bar.mjs", .data = "export default 3;\n" },
    });
    defer reg.deinit();

    const foo = try reg.resolveBare("left-pad/foo");
    defer foo.deinit(gpa);
    try expectJoinedPath(&.{ foo.package_root, "src", "foo.mjs" }, foo.path);

    // 具体的な prefix のパターンを優先する。
    const bar = try reg.resolveBare("left-pad/features/bar");
    defer bar.deinit(gpa);
    try expectJoinedPath(&.{ bar.package_root, "feat", "bar.mjs" }, bar.path);
}

test "BareRegistry resolveBare array fallback" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./sub":[{"node":"./node.js"},"./esm.mjs"]}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "esm.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    const got = try reg.resolveBare("left-pad/sub");
    defer got.deinit(gpa);
    try expectJoinedPath(&.{ got.package_root, "esm.mjs" }, got.path);
}

test "BareRegistry resolveBare rejects backslash specifier" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./sub":"./dist/sub.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "dist/sub.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // Windows 区切り文字での逃避を bare 名として解釈しない。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad\\sub"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/sub\\evil"));
}

test "BareRegistry resolveBare wildcard boundaries" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{
        \\  "./features/*":"./feat/*.mjs",
        \\  "./slash":"./dist/",
        \\  "./drive":"./C:/evil.js",
        \\  "./a*b":"./*"
        \\}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "feat/a/b.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // wildcard は複数セグメントにも一致し、target の `*` を置換する。
    const deep = try reg.resolveBare("left-pad/features/a/b");
    defer deep.deinit(gpa);
    try expectJoinedPath(&.{ deep.package_root, "feat", "a", "b.mjs" }, deep.path);

    // trailing slash target（空セグメント）は不正な target。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/slash"));
    // Windows ドライブレター target は不正な target。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/drive"));
    // `*` は 1 文字以上: 空マッチは非公開。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/ab"));
}

// --- PR #225 レビュー指摘の回帰テスト（M1/M2 + correctness minor） ---

test "BareRegistry resolveBare wildcard requires one character (M1 example 1)" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./foo*":"./foo*.js"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "foo.js", .data = "export default 1;\n" },
        .{ .path = "foobar.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // `*` は 1 文字以上: `pkg/foo` は非公開（Node: ERR_PACKAGE_PATH_NOT_EXPORTED）。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/foo"));
    const bar = try reg.resolveBare("left-pad/foobar");
    defer bar.deinit(gpa);
    try expectJoinedPath(&.{ bar.package_root, "foobar.js" }, bar.path);
}

test "BareRegistry resolveBare wildcard does not hide on empty match (M1 example 2)" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./features/*":"./src/*.js","./features/private*":null}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "src/private.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // 空マッチした `private*` が prefix 最長として選ばれてはならない。
    const priv = try reg.resolveBare("left-pad/features/private");
    defer priv.deinit(gpa);
    try expectJoinedPath(&.{ priv.package_root, "src", "private.js" }, priv.path);
    // 1 文字以上マッチするなら null target が勝って非公開になる。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/features/privatex"));
}

test "BareRegistry resolveBare wildcard prefix tie prefers longer key" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./feat*":"./generic/*.mjs","./feat*x":"./specific/*.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "generic/abx.mjs", .data = "export default 1;\n" },
        .{ .path = "specific/ab.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // prefix 長が同じなら key が長い `./feat*x` が勝つ（Node の patternKeyCompare）。
    const got = try reg.resolveBare("left-pad/featabx");
    defer got.deinit(gpa);
    try expectJoinedPath(&.{ got.package_root, "specific", "ab.mjs" }, got.path);
}

test "BareRegistry resolveBare substitutes every star in target" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./f/*":"./x/*/*.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "x/a/a.mjs", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    const got = try reg.resolveBare("left-pad/f/a");
    defer got.deinit(gpa);
    try expectJoinedPath(&.{ got.package_root, "x", "a", "a.mjs" }, got.path);
}

test "BareRegistry resolveBare conditions follow insertion order" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./cond":{"default":"./a.js","import":"./b.mjs"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "a.js", .data = "export default 1;\n" },
        .{ .path = "b.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // `import` を固定優先せず、object の挿入順で最初の一致を使う。
    const got = try reg.resolveBare("left-pad/cond");
    defer got.deinit(gpa);
    try expectJoinedPath(&.{ got.package_root, "a.js" }, got.path);
}

test "BareRegistry resolveBare null condition stops lookup" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./hidden":{"import":null,"default":"./fallback.js"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "fallback.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // 一致した条件の値が null なら、そこで非公開（default へ進まない）。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/hidden"));
}

test "BareRegistry resolveBare array fallback skips invalid targets" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./sub":["../evil.js","./ok.mjs"],"./bad":["../evil.js"]}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "ok.mjs", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // 不正な候補は飛ばして次の候補を使う（Node の配列 fallback）。
    const ok = try reg.resolveBare("left-pad/sub");
    defer ok.deinit(gpa);
    try expectJoinedPath(&.{ ok.package_root, "ok.mjs" }, ok.path);
    // 全候補が不正なら「未公開」ではなく package.json 不正として分類する。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/bad"));
}

test "BareRegistry resolveBare classifies invalid export targets" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        "{\"exports\":{\".\":\"./index.js\",\"./up\":\"../evil.js\"," ++
        "\"./abs\":\"/tmp/evil.js\",\"./node-modules\":\"./node_modules/evil.js\"," ++
        "\"./upper-node-modules\":\"./NODE_MODULES/evil.js\",\"./bare\":\"dist/sub.mjs\"," ++
        "\"./ads\":\"./index.js:s\",\"./control\":\"./dist/a\\u0001.mjs\"," ++
        "\"./nul\":\"./dist/a\\u0000.mjs\",\"./backslash\":\"./dist/a\\\\b.mjs\"}}";
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{});
    defer reg.deinit();

    for ([_][]const u8{
        "left-pad/up",
        "left-pad/abs",
        "left-pad/node-modules",
        "left-pad/upper-node-modules",
        "left-pad/bare",
        "left-pad/ads",
        "left-pad/control",
        "left-pad/nul",
        "left-pad/backslash",
    }) |spec| {
        try testing.expectError(error.PackageJsonInvalid, reg.resolveBare(spec));
    }
}

test "BareRegistry resolveBare classifies scalar targets as PackageJsonInvalid" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./scalar":{"import":true,"default":"./x.js"},"./num":5}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "x.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // Node は string / array / null / object 以外の target を
    // ERR_INVALID_PACKAGE_TARGET にする（default へ進まない）。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/scalar"));
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/num"));
}

test "BareRegistry resolveBare rejects array index condition keys" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./idx":{"0":"./a.js","default":"./x.js"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "x.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // Node は条件オブジェクトの配列 index キーを ERR_INVALID_PACKAGE_CONFIG に
    // する（配列 fallback でも飛ばさない）。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/idx"));
}

test "BareRegistry resolveBare array index boundary keys" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./max":{"4294967294":"./a.js","default":"./x.js"},"./over":{"4294967295":"./a.js","default":"./x.js"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "x.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // Node の isArrayIndex は 2^32-2 までを index とする（`4294967295` は違う）。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/max"));
    const over = try reg.resolveBare("left-pad/over");
    defer over.deinit(gpa);
    try expectJoinedPath(&.{ over.package_root, "x.js" }, over.path);
}

test "BareRegistry resolveBare duplicate keys use last value" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./sub":"./a.js","./sub":"./b.js"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "a.js", .data = "export default 1;\n" },
        .{ .path = "b.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // JS の JSON.parse と同じく後勝ち（Node 実測: b.js）。
    const got = try reg.resolveBare("left-pad/sub");
    defer got.deinit(gpa);
    try expectJoinedPath(&.{ got.package_root, "b.js" }, got.path);
}

test "BareRegistry resolveBare array last exception decides" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./last-null":["../evil.js",null],"./last-invalid":[null,"../evil.js"]}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{});
    defer reg.deinit();

    // Node: 最後の例外が null なら非公開、不正 target なら package.json 不正。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/last-null"));
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/last-invalid"));
}

test "BareRegistry resolveBare rejects numeric key after matching condition" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./sub":{"import":"./a.js","0":"./b.js"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "a.js", .data = "export default 1;\n" },
        .{ .path = "b.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // Node は条件マッチング前に全キーを検査する（import が先でも拒否）。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/sub"));
}

test "BareRegistry resolveBare array skips scalar but not numeric key error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./scalar":[true,"./x.js"],"./numeric":[{"0":"./a.js"},"./x.js"]}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "x.js", .data = "export default 1;\n" },
        .{ .path = "a.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // スカラー target は配列で飛ばす（Node: ERR_INVALID_PACKAGE_TARGET → continue）。
    const scalar = try reg.resolveBare("left-pad/scalar");
    defer scalar.deinit(gpa);
    try expectJoinedPath(&.{ scalar.package_root, "x.js" }, scalar.path);
    // 数値キーは package.json 不正で、配列でも飛ばさない。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/numeric"));
}

test "BareRegistry resolveBare rejects node_modules in wildcard match" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./*":["./a/*.js","./fallback.js"]}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "fallback.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // Node: ERR_INVALID_MODULE_SPECIFIER。配列 fallback で後続候補へ進まない。
    try testing.expectError(error.InvalidSpecifier, reg.resolveBare("left-pad/node_modules/x"));
}

test "BareRegistry resolveBare keeps longer prefix key seen first" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./feat*x":"./specific/*.mjs","./feat*":"./generic/*.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "specific/ab.mjs", .data = "export default 1;\n" },
        .{ .path = "generic/abx.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // 長いキーが先に出てきても、後の短いキーで上書きしない。
    const got = try reg.resolveBare("left-pad/featabx");
    defer got.deinit(gpa);
    try expectJoinedPath(&.{ got.package_root, "specific", "ab.mjs" }, got.path);
}

test "BareRegistry resolveBare root-less fixture without index.js" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./app":"./app.mjs"}}
    ;
    // `index.js` を書かない fixture。root 入口は存在しない。
    var reg = try makeTestRegistryWithRoot(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "app.mjs", .data = "export default 1;\n" },
    }, false);
    defer reg.deinit();

    const app = try reg.resolveBare("left-pad/app");
    defer app.deinit(gpa);
    try expectJoinedPath(&.{ app.package_root, "app.mjs" }, app.path);
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad"));
}

test "resolveEntryInRoot rejects directory as entry file" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "dist");
    // `dist.js` があっても exports は拡張子補完しない（Node は厳密 path）。
    try tmp.dir.writeFile(io, .{ .sub_path = "dist.js", .data = "export default 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{\"exports\":\"./dist\"}" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    try testing.expectError(error.EntryNotFound, resolveEntryInRoot(gpa, io, root));
}

test "resolveEntryInRoot does not probe extensions for exports targets" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":"./dist/index"}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = json });
    try tmp.dir.createDirPath(io, "dist");
    try tmp.dir.writeFile(io, .{ .sub_path = "dist/index.js", .data = "export default 1;\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    // exports target は拡張子補完しない（Node: ERR_MODULE_NOT_FOUND）。
    try testing.expectError(error.EntryNotFound, resolveEntryInRoot(gpa, io, root));
}

test "resolveEntryInRoot does not fall back to main when exports hides root" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./app":"./app.mjs"},"main":"index.js"}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = json });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.mjs", .data = "export default 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "index.js", .data = "export default 2;\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    // exports がある package は root 入口を exports からのみ選ぶ（Node と同じ）。
    try testing.expectError(error.EntryNotFound, resolveEntryInRoot(gpa, io, root));
}

test "resolveEntryInRoot rejects exports target outside root" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{\"exports\":\"./../evil.js\"}" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    try testing.expectError(error.PackageJsonInvalid, resolveEntryInRoot(gpa, io, root));
}

test "pickEntryFromPackageJson rejects mixed exports keys" {
    const gpa = testing.allocator;
    // Node は `.` 前置キーと条件キーの混在を ERR_INVALID_PACKAGE_CONFIG にする。
    try testing.expectError(error.PackageJsonInvalid, pickEntryFromPackageJson(
        gpa,
        "{\"exports\":{\".\":\"./index.js\",\"import\":\"./esm.mjs\"}}",
    ));
}

test "BareRegistry resolveBare empty array target is unpublished" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./empty":[],"./cond-empty":{"import":[],"default":"./ok.mjs"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "ok.mjs", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // Node は空配列 target を null（非公開）として即座に確定する
    // （`default` へは進まない）。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/empty"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/cond-empty"));
}

test "resolveSubpathInRoot rejects mixed exports keys" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./sub":"./sub.mjs","import":"./esm.mjs"}}
    ;
    // package_json 自体が不正なので registry 構築を経ずに直接検査する。
    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/package.json", .data = json });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/sub.mjs", .data = "export default 1;\n" });
    const root = try tmp.dir.realPathFileAlloc(io, "pkg", gpa);
    defer gpa.free(root);

    try testing.expectError(error.PackageJsonInvalid, resolveSubpathInRoot(gpa, io, root, "sub"));
}

test "BareRegistry resolveBare top-level conditions exports" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"import":"./esm.mjs","default":"./index.js"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "esm.mjs", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    const root = try reg.resolveBare("left-pad");
    defer root.deinit(gpa);
    try expectJoinedPath(&.{ root.package_root, "esm.mjs" }, root.path);
    // 条件オブジェクトは root 専用で、サブパスは公開されない。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/sub"));
}

test "BareRegistry resolveBare without exports resolves legacy subpath" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    // Node の ESM は `exports` 無し package の `name/sub` を
    // `<package_root>/<sub>` の厳密 path として解決する。
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", "{\"main\":\"index.js\"}", &.{
        .{ .path = "sub.mjs", .data = "export default 1;\n" },
        .{ .path = "lib/sub.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    const root = try reg.resolveBare("left-pad");
    defer root.deinit(gpa);
    // `path` は realpath で canonicalize されるため、Windows の区切りも
    // 吸収できるよう期待 path を `path.join` で組み立てて比較する。
    const expected_root = try std.fs.path.join(gpa, &.{ root.package_root, "index.js" });
    defer gpa.free(expected_root);
    try testing.expectEqualStrings(expected_root, root.path);

    const mjs = try reg.resolveBare("left-pad/sub.mjs");
    defer mjs.deinit(gpa);
    const expected_mjs = try std.fs.path.join(gpa, &.{ mjs.package_root, "sub.mjs" });
    defer gpa.free(expected_mjs);
    try testing.expectEqualStrings(expected_mjs, mjs.path);
    try testing.expectEqualStrings("pkg", std.fs.path.basename(mjs.package_root));

    const nested = try reg.resolveBare("left-pad/lib/sub.js");
    defer nested.deinit(gpa);
    const expected_nested = try std.fs.path.join(gpa, &.{ nested.package_root, "lib", "sub.js" });
    defer gpa.free(expected_nested);
    try testing.expectEqualStrings(expected_nested, nested.path);
}

test "BareRegistry resolveBare without exports does not complete extensions" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", "{\"main\":\"index.js\"}", &.{
        .{ .path = "sub.mjs", .data = "export default 1;\n" },
        .{ .path = "sub.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // Node ESM は legacy subpath でも拡張子を補完しない（ERR_MODULE_NOT_FOUND）。
    try testing.expectError(error.EntryNotFound, reg.resolveBare("left-pad/sub"));
}

test "BareRegistry resolveBare without exports rejects directory subpath" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", "{\"main\":\"index.js\"}", &.{
        .{ .path = "dist/index.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // ディレクトリは入口にしない（`<sub>/index.js` フォールバックもしない）。
    try testing.expectError(error.EntryNotFound, reg.resolveBare("left-pad/dist"));
}

test "BareRegistry resolveBare treats scalar exports as absent for legacy subpath" {
    const gpa = testing.allocator;
    const jsons = [_][]const u8{
        "{\"exports\":null,\"main\":\"index.js\"}",
        "{\"exports\":5,\"main\":\"index.js\"}",
        "{\"exports\":false,\"main\":\"index.js\"}",
    };
    for (jsons, 0..) |json, index| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = testing.io;
        var dir_buf: [32]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "scalar{d}", .{index});
        var reg = try makeTestRegistry(gpa, io, &tmp, dir, "left-pad", json, &.{
            .{ .path = "sub.mjs", .data = "export default 1;\n" },
        });
        defer reg.deinit();

        const got = try reg.resolveBare("left-pad/sub.mjs");
        defer got.deinit(gpa);
        try expectJoinedPath(&.{ got.package_root, "sub.mjs" }, got.path);
    }
}

test "resolveSubpathInRoot rejects unsafe legacy subpath characters" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/package.json", .data = "{\"main\":\"index.js\"}" });
    const root = try tmp.dir.realPathFileAlloc(io, "pkg", gpa);
    defer gpa.free(root);

    // Node POSIX は `:`・制御文字を解決し得るが、lnako は fail-closed。
    try testing.expectError(error.InvalidSpecifier, resolveSubpathInRoot(gpa, io, root, "a:b"));
    try testing.expectError(error.InvalidSpecifier, resolveSubpathInRoot(gpa, io, root, "a\x01b"));
    try testing.expectError(error.InvalidSpecifier, resolveSubpathInRoot(gpa, io, root, "C:/x"));
    // `.`/`..`/空セグメントは bare specifier の段階で拒否する既存分類。
    try testing.expectError(error.BareNotFound, resolveSubpathInRoot(gpa, io, root, "a/../b"));
}

test "parseBareSpecifier rejects empty scope and empty name" {
    try testing.expect(parseBareSpecifier("@/x") == null);
    try testing.expect(parseBareSpecifier("@scope/") == null);
    try testing.expect(parseBareSpecifier("@scope//x") == null);
    try testing.expect(parseBareSpecifier("@scope") == null);
    try testing.expect(parseBareSpecifier("@") == null);
    try testing.expect(parseBareSpecifier("/x") == null);
    try testing.expect(parseBareSpecifier("./x") == null);
}

test "parseBareSpecifier splits scoped subpath" {
    const scoped = parseBareSpecifier("@scope/pkg/sub").?;
    try testing.expectEqualStrings("@scope/pkg", scoped.name);
    try testing.expectEqualStrings("sub", scoped.subpath);
    const scoped_root = parseBareSpecifier("@scope/pkg").?;
    try testing.expectEqualStrings("@scope/pkg", scoped_root.name);
    try testing.expectEqualStrings("", scoped_root.subpath);
    const plain = parseBareSpecifier("pkg/sub/deep").?;
    try testing.expectEqualStrings("pkg", plain.name);
    try testing.expectEqualStrings("sub/deep", plain.subpath);
}

test "BareRegistry resolveBare null target precedes specifier validation" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./*":null}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{});
    defer reg.deinit();

    // Node 実測（v24/v26）: `"./*": null` + `pkg/node_modules/x` は
    // ERR_PACKAGE_PATH_NOT_EXPORTED。一致部分の検証より null が先。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/node_modules/x"));
}

test "BareRegistry resolveBare rejects colon and control chars in wildcard match" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./*":"./a/*.js"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{});
    defer reg.deinit();

    // Node は警告のみで通すが、この実装は fail-closed（docs/TODO.md）。
    try testing.expectError(error.InvalidSpecifier, reg.resolveBare("left-pad/a:b"));
    try testing.expectError(error.InvalidSpecifier, reg.resolveBare("left-pad/a\x01b"));
    // 空セグメントは specifier の段階で bare として拒否する。
    try testing.expect(parseBareSpecifier("left-pad/x//y") == null);
}

test "BareRegistry resolveBare empty string exports is invalid" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", "{\"exports\":\"\"}", &.{});
    defer reg.deinit();

    // Node 実測（v24/v26）: `exports: ""` は root で ERR_INVALID_PACKAGE_TARGET、
    // サブパスは sugar 経由で ERR_PACKAGE_PATH_NOT_EXPORTED。
    try testing.expectError(error.PackageJsonInvalid, pickEntryFromPackageJson(gpa, "{\"exports\":\"\"}"));
    // registry も root の package.json 不正を遅延解決で保持する。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/sub"));
}

test "BareRegistry resolveBare nested unresolved condition falls through" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./sub":{"import":{"node":"./x.js"},"default":"./y.js"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "y.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // 一致した `import` の値が未解決なら、挿入順で次の一致キー（default）へ進む。
    const got = try reg.resolveBare("left-pad/sub");
    defer got.deinit(gpa);
    try expectJoinedPath(&.{ got.package_root, "y.js" }, got.path);
}

test "BareRegistry resolveBare は * 入り specifier をパターンとして解決する" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./a*b":"./literal.mjs","./*":"./wild/*.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "literal.mjs", .data = "export default 1;\n" },
    });
    defer reg.deinit();
    const got = try reg.resolveBare("left-pad/a*b");
    defer got.deinit(gpa);
    try expectJoinedPath(&.{ got.package_root, "literal.mjs" }, got.path);
}

test "BareRegistry resolveBare は選択パターンの不正 target を他パターンへ fallback しない" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./a*b":"../evil.js","./*":"./wild/*.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{});
    defer reg.deinit();
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/a*b"));
}

// --- #54: package_root / 入口 symlink の canonicalization ---

/// 権限なし環境では symlink を作れないため、テストを skip する。
fn makeSymLinkOrSkip(tmp: *testing.TmpDir, io: std.Io, target: []const u8, link: []const u8, is_directory: bool) !void {
    tmp.dir.symLink(io, target, link, .{ .is_directory = is_directory }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };
}

test "resolveEntryInRoot canonicalizes package_root through a symlink" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "real/pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/pkg/package.json", .data = "{\"main\":\"index.js\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "real/pkg/index.js", .data = "export default 1;\n" });
    try makeSymLinkOrSkip(&tmp, io, "real/pkg", "link", true);

    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    // lexical な symlink path（realpath で解決しない）を渡す。
    const link_root = try std.fs.path.join(gpa, &.{ base, "link" });
    defer gpa.free(link_root);
    const canonical_root = try tmp.dir.realPathFileAlloc(io, "real/pkg", gpa);
    defer gpa.free(canonical_root);

    const resolved = try resolveEntryInRoot(gpa, io, link_root);
    defer resolved.deinit(gpa);
    try testing.expectEqualStrings(canonical_root, resolved.package_root);
    try expectJoinedPath(&.{ canonical_root, "index.js" }, resolved.path);
    try testing.expectEqualStrings(canonical_root, std.fs.path.dirname(resolved.path).?);
}

test "BareRegistry resolveBare canonicalizes package_root through a symlink" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "real/pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/pkg/package.json", .data = "{\"main\":\"index.js\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "real/pkg/index.js", .data = "export default 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "real/pkg/sub.mjs", .data = "export default 2;\n" });
    try makeSymLinkOrSkip(&tmp, io, "real/pkg", "link", true);

    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const link_root = try std.fs.path.join(gpa, &.{ base, "link" });
    defer gpa.free(link_root);
    const canonical_root = try tmp.dir.realPathFileAlloc(io, "real/pkg", gpa);
    defer gpa.free(canonical_root);

    var reg: BareRegistry = .{ .gpa = gpa, .io = io };
    defer reg.deinit();
    const name = try gpa.dupe(u8, "left-pad");
    try reg.by_name.put(gpa, name, try resolvePackageForRegistry(gpa, io, link_root));

    const root = try reg.resolveBare("left-pad");
    defer root.deinit(gpa);
    try testing.expectEqualStrings(canonical_root, root.package_root);
    try testing.expectEqualStrings(canonical_root, std.fs.path.dirname(root.path).?);

    const sub = try reg.resolveBare("left-pad/sub.mjs");
    defer sub.deinit(gpa);
    try testing.expectEqualStrings(canonical_root, sub.package_root);
    const expected_sub = try std.fs.path.join(gpa, &.{ canonical_root, "sub.mjs" });
    defer gpa.free(expected_sub);
    try testing.expectEqualStrings(expected_sub, sub.path);
}

test "resolveEntryInRoot rejects symlinked entries escaping package_root" {
    const gpa = testing.allocator;
    const io = testing.io;
    const Case = struct {
        package_json: []const u8,
        link: []const u8,
        /// フォールバックを隠すための root index.js を作るか。
        create_index: bool,
    };
    const cases = [_]Case{
        // exports target / main / module / index.js の各経路。
        .{ .package_json = "{\"exports\":\"./escape.mjs\"}", .link = "escape.mjs", .create_index = false },
        .{ .package_json = "{\"main\":\"escape.js\"}", .link = "escape.js", .create_index = true },
        .{ .package_json = "{\"module\":\"escape.mjs\"}", .link = "escape.mjs", .create_index = true },
        .{ .package_json = "{}", .link = "index.js", .create_index = false },
    };
    for (cases, 0..) |case, index| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var dir_buf: [32]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "escape{d}", .{index});
        try tmp.dir.createDirPath(io, dir);
        const pj_path = try std.fmt.allocPrint(gpa, "{s}/package.json", .{dir});
        defer gpa.free(pj_path);
        try tmp.dir.writeFile(io, .{ .sub_path = pj_path, .data = case.package_json });
        if (case.create_index) {
            const index_path = try std.fmt.allocPrint(gpa, "{s}/index.js", .{dir});
            defer gpa.free(index_path);
            try tmp.dir.writeFile(io, .{ .sub_path = index_path, .data = "export default 1;\n" });
        }
        try tmp.dir.writeFile(io, .{ .sub_path = "outside.mjs", .data = "export default 9;\n" });
        const link_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, case.link });
        defer gpa.free(link_path);
        try makeSymLinkOrSkip(&tmp, io, "../outside.mjs", link_path, false);

        const root = try tmp.dir.realPathFileAlloc(io, dir, gpa);
        defer gpa.free(root);
        // fail-closed: 次候補（index.js）へフォールバックしない。
        try testing.expectError(error.PackageJsonInvalid, resolveEntryInRoot(gpa, io, root));
    }
}

test "resolveSubpathInRoot rejects symlinked subpaths escaping package_root" {
    const gpa = testing.allocator;
    const io = testing.io;
    const Case = struct { package_json: []const u8, subpath: []const u8, expect: anyerror };
    const cases = [_]Case{
        // exports 無し `name/sub` は InvalidSpecifier、exports target は
        // exports/legacy 共通の PackageJsonInvalid。
        .{ .package_json = "{\"main\":\"index.js\"}", .subpath = "sub.mjs", .expect = error.InvalidSpecifier },
        .{ .package_json = "{\"exports\":{\"./sub\":\"./sub.mjs\"}}", .subpath = "sub", .expect = error.PackageJsonInvalid },
    };
    for (cases, 0..) |case, index| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var dir_buf: [32]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "subescape{d}", .{index});
        try tmp.dir.createDirPath(io, dir);
        const pj_path = try std.fmt.allocPrint(gpa, "{s}/package.json", .{dir});
        defer gpa.free(pj_path);
        try tmp.dir.writeFile(io, .{ .sub_path = pj_path, .data = case.package_json });
        try tmp.dir.writeFile(io, .{ .sub_path = "outside.mjs", .data = "export default 9;\n" });
        const link_path = try std.fmt.allocPrint(gpa, "{s}/sub.mjs", .{dir});
        defer gpa.free(link_path);
        try makeSymLinkOrSkip(&tmp, io, "../outside.mjs", link_path, false);

        const root = try tmp.dir.realPathFileAlloc(io, dir, gpa);
        defer gpa.free(root);
        try testing.expectError(case.expect, resolveSubpathInRoot(gpa, io, root, case.subpath));
    }
}

// --- #54: registry の root 入口遅延解決（エラー分類の保持） ---

test "BareRegistry resolveBare keeps EntryNotFound for missing root target" {
    const gpa = testing.allocator;
    const Case = struct { package_json: []const u8, create_root_index: bool };
    const cases = [_]Case{
        // exports の "." target 欠落（拡張子補完・main への fallback なし）。
        .{ .package_json = "{\"exports\":{\".\":\"./missing.mjs\"},\"main\":\"index.js\"}", .create_root_index = true },
        // exports 無しで main も index.js も無い。
        .{ .package_json = "{\"main\":\"missing.js\"}", .create_root_index = false },
        // exports 無しで module だけがあり欠落。
        .{ .package_json = "{\"module\":\"missing.mjs\"}", .create_root_index = false },
    };
    for (cases, 0..) |case, index| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = testing.io;
        var dir_buf: [32]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "noroot{d}", .{index});
        var reg = try makeTestRegistryWithRoot(
            gpa,
            io,
            &tmp,
            dir,
            "left-pad",
            case.package_json,
            &.{},
            case.create_root_index,
        );
        defer reg.deinit();
        try testing.expectError(error.EntryNotFound, reg.resolveBare("left-pad"));
    }
}

test "BareRegistry resolveBare maps unpublished root to BareNotFound" {
    const gpa = testing.allocator;
    const jsons = [_][]const u8{
        "{\"exports\":{\"./app\":\"./app.mjs\"}}",
        "{\"exports\":[]}",
        "{\"exports\":{\"import\":null}}",
        "{\"exports\":{\"node\":\"./x.js\"}}",
    };
    for (jsons, 0..) |json, index| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = testing.io;
        var dir_buf: [32]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "hidden{d}", .{index});
        var reg = try makeTestRegistry(gpa, io, &tmp, dir, "left-pad", json, &.{});
        defer reg.deinit();
        try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad"));
    }
}
