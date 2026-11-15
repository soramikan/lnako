//! `npm_esm` の #54 回帰テスト（package.json / 入口 / specifier）。
//!
//! helper を使わない `pickEntryFromPackageJson`・`resolveEntryInRoot`・
//! `resolveSubpathInRoot`・`pickExportsSubpath`・`parseBareSpecifier` と
//! instance 登録の回帰テスト。fixture helper を使う registry / exports /
//! symlink の回帰テストは `npm_esm_registry_test.zig` が所有する。

const std = @import("std");
const testing = std.testing;
const npm_esm = @import("npm_esm.zig");
const lock_model = @import("lock_model.zig");

const Allocator = std.mem.Allocator;
const BareRegistry = npm_esm.BareRegistry;
const pickEntryFromPackageJson = npm_esm.pickEntryFromPackageJson;
const resolveEntryInRoot = npm_esm.resolveEntryInRoot;
const resolveSubpathInRoot = npm_esm.resolveSubpathInRoot;
const resolvePackageForRegistry = npm_esm.resolvePackageForRegistry;
const parseBareSpecifier = npm_esm.parseBareSpecifier;

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "pickEntryFromPackageJson exports string" {
    const gpa = testing.allocator;
    const entry = (try pickEntryFromPackageJson(gpa, "{\"exports\":\"./dist/index.mjs\"}")).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("./dist/index.mjs", entry.target);
    try testing.expect(entry.from_exports);
}

test "pickEntryFromPackageJson rejects exports target without ./" {
    const gpa = testing.allocator;
    // Node の exports target は `./` 前置の相対 path でなければならない。
    try testing.expectError(error.PackageJsonInvalid, pickEntryFromPackageJson(gpa, "{\"exports\":\"dist/index.mjs\"}"));
}

test "pickEntryFromPackageJson exports import condition ignores node" {
    const gpa = testing.allocator;
    const json =
        \\{"exports":{".":{"node":"./node.js","import":"./esm.mjs","default":"./default.js"}}}
    ;
    const entry = (try pickEntryFromPackageJson(gpa, json)).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("./esm.mjs", entry.target);
}

test "pickEntryFromPackageJson exports conditions follow insertion order" {
    const gpa = testing.allocator;
    // `import` 固定優先にせず、object の挿入順で最初の一致を使う。
    const json =
        \\{"exports":{"default":"./a.js","import":"./b.mjs"}}
    ;
    const entry = (try pickEntryFromPackageJson(gpa, json)).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("./a.js", entry.target);
}

test "pickEntryFromPackageJson exports null condition stops lookup" {
    const gpa = testing.allocator;
    const json =
        \\{"exports":{".":{"import":null,"default":"./x.js"}}}
    ;
    // 一致した条件の値が null なら、そこで非公開（default へ進まない）。
    const picked = try pickEntryFromPackageJson(gpa, json);
    if (picked) |entry| entry.deinit(gpa);
    try testing.expect(picked == null);
}

test "pickEntryFromPackageJson does not pick browser alone" {
    const gpa = testing.allocator;
    const json =
        \\{"exports":{".":{"browser":"./browser.js","require":"./cjs.js"}},"main":"lib/main.js"}
    ;
    // import/default が一致しない exports は root を公開しない
    // （`module` / `main` / `index.js` へはフォールバックしない）。
    const picked = try pickEntryFromPackageJson(gpa, json);
    if (picked) |entry| entry.deinit(gpa);
    try testing.expect(picked == null);
}

test "pickEntryFromPackageJson treats scalar exports as absent" {
    const gpa = testing.allocator;
    // Node は exports が string / array / object 以外なら exports 無しとして
    // module/main/index.js の従来解決へ落とす。
    for ([_][]const u8{
        "{\"exports\":5,\"main\":\"lib/main.js\"}",
        "{\"exports\":false,\"main\":\"lib/main.js\"}",
        "{\"exports\":null,\"main\":\"lib/main.js\"}",
    }) |json| {
        const entry = (try pickEntryFromPackageJson(gpa, json)).?;
        defer entry.deinit(gpa);
        try testing.expectEqualStrings("lib/main.js", entry.target);
        try testing.expect(!entry.from_exports);
    }
}

test "pickEntryFromPackageJson module field" {
    const gpa = testing.allocator;
    const entry = (try pickEntryFromPackageJson(gpa, "{\"module\":\"lib/mod.mjs\",\"main\":\"lib/mod.js\"}")).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("lib/mod.mjs", entry.target);
    try testing.expect(!entry.from_exports);
}

test "pickEntryFromPackageJson exports array" {
    const gpa = testing.allocator;
    // root exports の配列 fallback（不正 target は飛ばす）。
    const entry = (try pickEntryFromPackageJson(gpa, "{\"exports\":[\"../evil.js\",\"./a.js\"]}")).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("./a.js", entry.target);
    try testing.expect(entry.from_exports);
}

test "resolveEntryInRoot reads package.json" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{\"exports\":\"./hi.mjs\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hi.mjs", .data = "export const x = 1;\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const resolved = try resolveEntryInRoot(gpa, io, root);
    defer resolved.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, resolved.path, "hi.mjs"));
}

test "BareRegistry resolveBare returns entry" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/package.json", .data = "{\"main\":\"index.js\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/index.js", .data = "export default 1;\n" });
    const pkg_root = try tmp.dir.realPathFileAlloc(io, "pkg", gpa);
    defer gpa.free(pkg_root);

    var reg: BareRegistry = .{ .gpa = gpa, .io = io };
    defer reg.deinit();
    const name = try gpa.dupe(u8, "left-pad");
    errdefer gpa.free(name);
    try reg.by_name.put(gpa, name, try resolvePackageForRegistry(gpa, io, pkg_root));

    const got = try reg.resolveBare("left-pad");
    defer got.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, got.path, "index.js"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("missing"));
}

const TestInstanceTrees = struct {
    paths: []const struct { name: []const u8, path: []const u8 },

    fn treePath(ctx: *anyopaque, gpa: Allocator, instance: lock_model.NpmInstance) anyerror!?[]u8 {
        const self: *const TestInstanceTrees = @ptrCast(@alignCast(ctx));
        for (self.paths) |entry| {
            if (std.mem.eql(u8, entry.name, instance.name)) return try gpa.dupe(u8, entry.path);
        }
        return null;
    }
};

test "BareRegistry registerInstance は同名を no-op にする" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_]struct { dir: []const u8, version: []const u8 }{
        .{ .dir = "first", .version = "1.0.0" },
        .{ .dir = "second", .version = "2.0.0" },
    }) |entry| {
        try tmp.dir.createDirPath(io, entry.dir);
        const json = try std.fmt.allocPrint(gpa, "{{\"version\":\"{s}\",\"main\":\"index.js\"}}", .{entry.version});
        defer gpa.free(json);
        const manifest_path = try std.fmt.allocPrint(gpa, "{s}/package.json", .{entry.dir});
        defer gpa.free(manifest_path);
        const source_path = try std.fmt.allocPrint(gpa, "{s}/index.js", .{entry.dir});
        defer gpa.free(source_path);
        try tmp.dir.writeFile(io, .{ .sub_path = manifest_path, .data = json });
        try tmp.dir.writeFile(io, .{ .sub_path = source_path, .data = "export default 1;\n" });
    }
    const first_root = try tmp.dir.realPathFileAlloc(io, "first", gpa);
    defer gpa.free(first_root);
    const second_root = try tmp.dir.realPathFileAlloc(io, "second", gpa);
    defer gpa.free(second_root);

    var reg: BareRegistry = .{ .gpa = gpa, .io = io };
    defer reg.deinit();
    const first = lock_model.NpmInstance{ .key = "pkg@1.0.0", .name = "pkg", .version = "1.0.0" };
    const second = lock_model.NpmInstance{ .key = "pkg@2.0.0", .name = "pkg", .version = "2.0.0" };
    try reg.registerInstance(first, first_root);
    try reg.registerInstance(second, second_root);
    const entry = try reg.resolveBare("pkg");
    defer entry.deinit(gpa);
    const entry_dir = std.fs.path.dirname(entry.path) orelse return error.UnexpectedResult;
    try testing.expectEqualStrings("first", std.fs.path.basename(entry_dir));
}

test "BareRegistry buildFromInstances registers subpath-only package (M2)" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.createDirPath(io, "subonly");
    try tmp.dir.writeFile(io, .{ .sub_path = "subonly/package.json", .data = "{\"exports\":{\"./app\":\"./app.mjs\"}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "subonly/app.mjs", .data = "export default 1;\n" });
    try tmp.dir.createDirPath(io, "rooted");
    try tmp.dir.writeFile(io, .{ .sub_path = "rooted/package.json", .data = "{\"main\":\"index.js\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "rooted/index.js", .data = "export default 2;\n" });

    const subonly_root = try tmp.dir.realPathFileAlloc(io, "subonly", gpa);
    defer gpa.free(subonly_root);
    const rooted_root = try tmp.dir.realPathFileAlloc(io, "rooted", gpa);
    defer gpa.free(rooted_root);

    var trees = TestInstanceTrees{ .paths = &.{
        .{ .name = "subonly", .path = subonly_root },
        .{ .name = "rooted", .path = rooted_root },
    } };
    const instances = [_]lock_model.NpmInstance{
        .{ .key = "subonly@1.0.0", .name = "subonly", .version = "1.0.0" },
        .{ .key = "rooted@1.0.0", .name = "rooted", .version = "1.0.0" },
    };

    var reg = try BareRegistry.buildFromInstances(gpa, io, &instances, TestInstanceTrees.treePath, &trees);
    defer reg.deinit();

    // root 入口を持たない package でもサブパスは解決できる。
    const app = try reg.resolveBare("subonly/app");
    defer app.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, app.path, "app.mjs"));
    // root 入口だけが非公開になる。
    try testing.expectError(error.BareNotFound, reg.resolveBare("subonly"));
    // 同じ registry の他の package は影響を受けない。
    const root = try reg.resolveBare("rooted");
    defer root.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, root.path, "index.js"));
}

test "BareRegistry buildFromInstances keeps other packages when one is invalid" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.createDirPath(io, "broken");
    // JSON として壊れた package.json。
    try tmp.dir.writeFile(io, .{ .sub_path = "broken/package.json", .data = "{\"exports\":{\"./sub\":\"./s.mjs\"" });
    try tmp.dir.writeFile(io, .{ .sub_path = "broken/s.mjs", .data = "export default 1;\n" });
    try tmp.dir.createDirPath(io, "ok");
    try tmp.dir.writeFile(io, .{ .sub_path = "ok/package.json", .data = "{\"main\":\"index.js\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ok/index.js", .data = "export default 2;\n" });

    const broken_root = try tmp.dir.realPathFileAlloc(io, "broken", gpa);
    defer gpa.free(broken_root);
    const ok_root = try tmp.dir.realPathFileAlloc(io, "ok", gpa);
    defer gpa.free(ok_root);

    var trees = TestInstanceTrees{ .paths = &.{
        .{ .name = "broken", .path = broken_root },
        .{ .name = "ok", .path = ok_root },
    } };
    const instances = [_]lock_model.NpmInstance{
        .{ .key = "broken@1.0.0", .name = "broken", .version = "1.0.0" },
        .{ .key = "ok@1.0.0", .name = "ok", .version = "1.0.0" },
    };

    // 壊れた package.json があっても registry 全体は構築できる。
    var reg = try BareRegistry.buildFromInstances(gpa, io, &instances, TestInstanceTrees.treePath, &trees);
    defer reg.deinit();

    // 壊れた package のサブパスは per-import で package.json 不正になる。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("broken/sub"));
    // root 入口も遅延解決で package.json 不正を保持する（旧実装は
    // registry 構築時に失敗を丸めて BareNotFound にしていた）。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("broken"));
    // 無関係な package は影響を受けない。
    const root = try reg.resolveBare("ok");
    defer root.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, root.path, "index.js"));
}

test "BareRegistry resolveBare は過大な wildcard 展開を確保前に拒否する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg");
    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"exports\":{\"./*\":\"./");
    var i: usize = 0;
    while (i < 100) : (i += 1) try json.appendSlice(gpa, "x*");
    try json.appendSlice(gpa, "\"}}");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/package.json", .data = json.items });
    const root = try tmp.dir.realPathFileAlloc(io, "pkg", gpa);
    defer gpa.free(root);
    var reg: BareRegistry = .{ .gpa = gpa, .io = io };
    defer reg.deinit();
    const name = try gpa.dupe(u8, "left-pad");
    const package_root = try gpa.dupe(u8, root);
    try reg.by_name.put(gpa, name, .{ .package_root = package_root });

    const long = try gpa.alloc(u8, 20_000);
    defer gpa.free(long);
    @memset(long, 'a');
    const spec = try std.fmt.allocPrint(gpa, "left-pad/{s}", .{long});
    defer gpa.free(spec);
    try testing.expectError(error.InvalidSpecifier, reg.resolveBare(spec));
}

test "BareRegistry resolveBare は null target を一致部分検証より優先する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg");
    const json =
        \\{"exports":{"./*":{"import":null}}}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/package.json", .data = json });
    const root = try tmp.dir.realPathFileAlloc(io, "pkg", gpa);
    defer gpa.free(root);
    var reg: BareRegistry = .{ .gpa = gpa, .io = io };
    defer reg.deinit();
    const name = try gpa.dupe(u8, "left-pad");
    const package_root = try gpa.dupe(u8, root);
    try reg.by_name.put(gpa, name, .{ .package_root = package_root });

    // 一致部分は node_modules だが、target が null（非公開）なので
    // InvalidSpecifier ではなく BareNotFound。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/node_modules/x"));
}

test "BareRegistry resolveBare maps missing package.json to BareNotFound" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/index.js", .data = "export default 1;\n" });
    const root = try tmp.dir.realPathFileAlloc(io, "pkg", gpa);
    defer gpa.free(root);

    var reg: BareRegistry = .{ .gpa = gpa, .io = io };
    defer reg.deinit();
    const name = try gpa.dupe(u8, "left-pad");
    try reg.by_name.put(gpa, name, try resolvePackageForRegistry(gpa, io, root));
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad"));

    // registry 構築後に tree 自体が消えた場合も BareNotFound（直接 API は
    // PackageJsonMissing のまま）。
    try tmp.dir.deleteTree(io, "pkg");
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad"));
}
