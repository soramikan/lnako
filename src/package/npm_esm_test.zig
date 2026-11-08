//! `npm_esm` の package.json 本格パース（#53）回帰テスト。
//!
//! 期待値は Node 24.21.0 / 26.13.0 の実測（ESM import での解決結果と
//! ERR_INVALID_PACKAGE_CONFIG / ERR_PACKAGE_PATH_NOT_EXPORTED）に基づく。
//! サイズが大きいため `npm_esm.zig` の例外台帳（100 KB）から分離している。

const std = @import("std");
const testing = std.testing;
const npm_esm = @import("npm_esm.zig");

const pickEntryFromPackageJson = npm_esm.pickEntryFromPackageJson;
const resolveEntryInRoot = npm_esm.resolveEntryInRoot;
const resolveSubpathInRoot = npm_esm.resolveSubpathInRoot;

// --- #53 package.json 本格パース（Node 24.21.0 / 26.13.0 実測に基づく） ---

test "pickEntryFromPackageJson は name/type 非文字列を PackageJsonInvalid にする" {
    const gpa = testing.allocator;
    // Node 実測（v24/v26）: name/type が非文字列なら ERR_INVALID_PACKAGE_CONFIG。
    // どちらも exports より先に検証され、解決結果には到達しない。
    for ([_][]const u8{
        "{\"name\":5,\"exports\":\"./index.mjs\"}",
        "{\"name\":null,\"exports\":\"./index.mjs\"}",
        "{\"name\":[],\"exports\":\"./index.mjs\"}",
        "{\"type\":5,\"exports\":\"./index.mjs\"}",
        "{\"type\":false,\"exports\":\"./index.mjs\"}",
    }) |json| {
        try testing.expectError(error.PackageJsonInvalid, pickEntryFromPackageJson(gpa, json));
    }
    // 空文字 name と任意文字列 type は Node も受理する。
    const named = (try pickEntryFromPackageJson(gpa, "{\"name\":\"\",\"type\":\"unknown\",\"exports\":\"./index.mjs\"}")).?;
    defer named.deinit(gpa);
    try testing.expectEqualStrings("./index.mjs", named.target);
}

test "pickEntryFromPackageJson は BOM 付き package.json を受理する（Node 24/26 実測）" {
    const gpa = testing.allocator;
    const entry = (try pickEntryFromPackageJson(gpa, "\xEF\xBB\xBF{\"exports\":\"./dist/index.mjs\"}")).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("./dist/index.mjs", entry.target);
    try testing.expect(entry.from_exports);
}

test "pickEntryFromPackageJson は main/module 非文字列を無視する（Node 実測）" {
    const gpa = testing.allocator;
    // Node 実測: main が数値・null・配列なら無視して index.js へ落ちる。
    // `module` は Node が読まない lnako 拡張なので、同じく型不正は未指定扱い。
    const Case = struct { json: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .json = "{\"main\":5}", .expected = "index.js" },
        .{ .json = "{\"main\":null}", .expected = "index.js" },
        .{ .json = "{\"main\":[\"x.js\"]}", .expected = "index.js" },
        .{ .json = "{\"module\":5}", .expected = "index.js" },
        .{ .json = "{\"module\":false,\"main\":\"main.js\"}", .expected = "main.js" },
    };
    for (cases) |case| {
        const entry = (try pickEntryFromPackageJson(gpa, case.json)).?;
        defer entry.deinit(gpa);
        try testing.expectEqualStrings(case.expected, entry.target);
        try testing.expect(!entry.from_exports);
    }
}

test "pickEntryFromPackageJson は重複キーを後勝ちで解決する（Node 実測）" {
    const gpa = testing.allocator;
    // Node 実測: `{"exports":"./a.mjs","exports":"./b.mjs"}` は b.mjs。
    const entry = (try pickEntryFromPackageJson(gpa, "{\"exports\":\"./a.mjs\",\"exports\":\"./b.mjs\"}")).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("./b.mjs", entry.target);
    // 最後が非対応型なら exports 無し → main へ落ちる（後勝ちの一貫した結果）。
    const fallback = (try pickEntryFromPackageJson(gpa, "{\"exports\":\"./a.mjs\",\"exports\":5,\"main\":\"m.js\"}")).?;
    defer fallback.deinit(gpa);
    try testing.expectEqualStrings("m.js", fallback.target);
    try testing.expect(!fallback.from_exports);
}

test "pickEntryFromPackageJson は不正 JSON を PackageJsonInvalid にする" {
    const gpa = testing.allocator;
    // Node 実測（v24/v26）: JSON として不正・root 非 object は
    // ERR_INVALID_PACKAGE_CONFIG。
    for ([_][]const u8{
        "{\"exports\":\"./index.mjs\",",
        "[]",
        "\"hi\"",
        "",
    }) |json| {
        try testing.expectError(error.PackageJsonInvalid, pickEntryFromPackageJson(gpa, json));
    }
}

test "resolveEntryInRoot は legacy main 解決で index.js へフォールバックする" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Node 実測（v24/v26）: main の候補が無い・ディレクトリ・"."・空文字の
    // いずれも最終的に index.js が解決される。module は Node が読まない
    // lnako 拡張で、こちらも存在しない候補は main → index.js へ進む。
    const Case = struct { json: []const u8, files: []const []const u8, expect: []const u8 };
    const cases = [_]Case{
        .{ .json = "{\"main\":\"missing.js\"}", .files = &.{"index.js"}, .expect = "index.js" },
        .{ .json = "{\"main\":5}", .files = &.{"index.js"}, .expect = "index.js" },
        .{ .json = "{\"main\":\"lib\"}", .files = &.{"lib/index.js"}, .expect = "lib/index.js" },
        .{ .json = "{\"main\":\"lib/\"}", .files = &.{"lib/index.js"}, .expect = "lib/index.js" },
        .{ .json = "{\"main\":\".\"}", .files = &.{"index.js"}, .expect = "index.js" },
        .{ .json = "{\"main\":\"\"}", .files = &.{"index.js"}, .expect = "index.js" },
        .{ .json = "{\"main\":\"./\"}", .files = &.{"index.js"}, .expect = "index.js" },
        .{ .json = "{\"main\":\"././\"}", .files = &.{"index.js"}, .expect = "index.js" },
        // 区切りのみの絶対 path も Node は index.js へフォールバックする。
        .{ .json = "{\"main\":\"/\"}", .files = &.{"index.js"}, .expect = "index.js" },
        .{ .json = "{\"main\":\"//\"}", .files = &.{"index.js"}, .expect = "index.js" },
        // 末尾 separator はディレクトリ指定。`lib.js` があっても `lib/` の
        // index.js を優先し、無ければ index.js へ落ちる（Node 実測）。
        .{ .json = "{\"main\":\"lib/\"}", .files = &.{ "lib.js", "index.js" }, .expect = "index.js" },
        .{ .json = "{\"main\":\"lib/main\"}", .files = &.{"lib/main.js"}, .expect = "lib/main.js" },
        .{ .json = "{\"module\":\"missing.mjs\",\"main\":\"main.js\"}", .files = &.{"main.js"}, .expect = "main.js" },
        .{ .json = "{\"module\":\"mjs\",\"main\":\"main.js\"}", .files = &.{"mjs/index.js"}, .expect = "mjs/index.js" },
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases, 0..) |case, index| {
        var dir_name_buf: [32]u8 = undefined;
        const dir_name = try std.fmt.bufPrint(&dir_name_buf, "pkg{d}", .{index});
        try tmp.dir.createDirPath(io, dir_name);
        const pj_path = try std.fmt.allocPrint(gpa, "{s}/package.json", .{dir_name});
        defer gpa.free(pj_path);
        try tmp.dir.writeFile(io, .{ .sub_path = pj_path, .data = case.json });
        for (case.files) |file| {
            const file_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_name, file });
            defer gpa.free(file_path);
            if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |slash| {
                try tmp.dir.createDirPath(io, file_path[0..slash]);
            }
            try tmp.dir.writeFile(io, .{ .sub_path = file_path, .data = "export default 1;\n" });
        }
        const root = try tmp.dir.realPathFileAlloc(io, dir_name, gpa);
        defer gpa.free(root);
        const resolved = try resolveEntryInRoot(gpa, io, root);
        defer resolved.deinit(gpa);
        try testing.expect(std.mem.endsWith(u8, resolved.path, case.expect));
    }
}

test "resolveEntryInRoot はディレクトリ候補の package.json main を読まない（Node 実測）" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Node 24.21.0 / 26.13.0 実測: ESM の legacy main は `<候補>/index.js` を
    // 見るが、`<候補>/package.json` の main は再帰解決しない。
    // `main:"lib"` + `lib/package.json {"main":"deep.js"}` は
    // `lib/index.js`（存在すれば）を選び、無ければ root の index.js へ落ちる。
    const cases = [_]struct { files: []const []const u8, expect: []const u8 }{
        .{ .files = &.{ "lib/package.json", "lib/deep.js", "lib/index.js" }, .expect = "lib/index.js" },
        .{ .files = &.{ "lib/package.json", "lib/deep.js" }, .expect = "index.js" },
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases, 0..) |case, index| {
        var dir_name_buf: [32]u8 = undefined;
        const dir_name = try std.fmt.bufPrint(&dir_name_buf, "dirpj{d}", .{index});
        try tmp.dir.createDirPath(io, dir_name);
        const pj_path = try std.fmt.allocPrint(gpa, "{s}/package.json", .{dir_name});
        defer gpa.free(pj_path);
        try tmp.dir.writeFile(io, .{ .sub_path = pj_path, .data = "{\"main\":\"lib\"}" });
        const root_index_path = try std.fmt.allocPrint(gpa, "{s}/index.js", .{dir_name});
        defer gpa.free(root_index_path);
        try tmp.dir.writeFile(io, .{ .sub_path = root_index_path, .data = "export default 3;\n" });
        for (case.files) |file| {
            const file_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_name, file });
            defer gpa.free(file_path);
            if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |slash| {
                try tmp.dir.createDirPath(io, file_path[0..slash]);
            }
            const body = if (std.mem.endsWith(u8, file, "package.json"))
                "{\"main\":\"deep.js\"}"
            else
                "export default 1;\n";
            try tmp.dir.writeFile(io, .{ .sub_path = file_path, .data = body });
        }
        const root = try tmp.dir.realPathFileAlloc(io, dir_name, gpa);
        defer gpa.free(root);
        const resolved = try resolveEntryInRoot(gpa, io, root);
        defer resolved.deinit(gpa);
        try testing.expect(std.mem.endsWith(u8, resolved.path, case.expect));
    }
}

test "resolveEntryInRoot の index.js フォールバックは厳密 path だけを見る" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Node の index フォールバックは index.js / index.json / index.node のみで、
    // `index.js.js` や `index.js/index.js` のような補完はしない。
    const Case = struct { files: []const []const u8, expect_error: bool };
    const cases = [_]Case{
        .{ .files = &.{"index.js.js"}, .expect_error = true },
        .{ .files = &.{"index.js/index.js"}, .expect_error = true },
        .{ .files = &.{"index.js"}, .expect_error = false },
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases, 0..) |case, index| {
        var dir_name_buf: [32]u8 = undefined;
        const dir_name = try std.fmt.bufPrint(&dir_name_buf, "idx{d}", .{index});
        try tmp.dir.createDirPath(io, dir_name);
        const pj_path = try std.fmt.allocPrint(gpa, "{s}/package.json", .{dir_name});
        defer gpa.free(pj_path);
        try tmp.dir.writeFile(io, .{ .sub_path = pj_path, .data = "{}" });
        for (case.files) |file| {
            const file_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_name, file });
            defer gpa.free(file_path);
            if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |slash| {
                try tmp.dir.createDirPath(io, file_path[0..slash]);
            }
            try tmp.dir.writeFile(io, .{ .sub_path = file_path, .data = "export default 1;\n" });
        }
        const root = try tmp.dir.realPathFileAlloc(io, dir_name, gpa);
        defer gpa.free(root);
        if (case.expect_error) {
            try testing.expectError(error.EntryNotFound, resolveEntryInRoot(gpa, io, root));
        } else {
            const resolved = try resolveEntryInRoot(gpa, io, root);
            defer resolved.deinit(gpa);
            try testing.expect(std.mem.endsWith(u8, resolved.path, "index.js"));
        }
    }
}

test "resolveEntryInRoot は exports 空配列で root を非公開にする" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Node 実測: exports: [] は root を公開せず、main / index.js へ落ちない。
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{\"exports\":[],\"main\":\"main.js\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.js", .data = "export default 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "index.js", .data = "export default 2;\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try testing.expectError(error.EntryNotFound, resolveEntryInRoot(gpa, io, root));
}

test "resolveEntryInRoot は lnako 拡張として .mjs を補完する（Node は補完しない）" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Node 24.21.0 / 26.13.0 実測: legacy main の拡張補完は .js/.json/.node のみで、
    // `.mjs` と `<候補>/index.mjs` は試行しない（ERR_MODULE_NOT_FOUND）。
    // lnako は ESM 専用の意図的拡張として .mjs も補完する（docs/TODO.md）。
    const Case = struct { json: []const u8, files: []const []const u8, expect: []const u8 };
    const cases = [_]Case{
        .{ .json = "{\"main\":\"lib/main\"}", .files = &.{"lib/main.mjs"}, .expect = "lib/main.mjs" },
        .{ .json = "{\"main\":\"lib\"}", .files = &.{"lib/index.mjs"}, .expect = "lib/index.mjs" },
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases, 0..) |case, index| {
        var dir_name_buf: [32]u8 = undefined;
        const dir_name = try std.fmt.bufPrint(&dir_name_buf, "mjs{d}", .{index});
        try tmp.dir.createDirPath(io, dir_name);
        const pj_path = try std.fmt.allocPrint(gpa, "{s}/package.json", .{dir_name});
        defer gpa.free(pj_path);
        try tmp.dir.writeFile(io, .{ .sub_path = pj_path, .data = case.json });
        for (case.files) |file| {
            const file_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_name, file });
            defer gpa.free(file_path);
            if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |slash| {
                try tmp.dir.createDirPath(io, file_path[0..slash]);
            }
            try tmp.dir.writeFile(io, .{ .sub_path = file_path, .data = "export default 1;\n" });
        }
        const root = try tmp.dir.realPathFileAlloc(io, dir_name, gpa);
        defer gpa.free(root);
        const resolved = try resolveEntryInRoot(gpa, io, root);
        defer resolved.deinit(gpa);
        try testing.expect(std.mem.endsWith(u8, resolved.path, case.expect));
    }
}

test "resolveEntryInRoot は root 外を指す main/module を PackageJsonInvalid にする" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Node の legacy main 解決は package root 外も解決し得るが、lnako は
    // 安全側で fail-closed にする。分類は exports の不正 target と同じ
    // PackageJsonInvalid（旧実装の単一候補時代は EntryNotFound）。
    for ([_][]const u8{
        "{\"main\":\"../evil.js\"}",
        "{\"main\":\"a/../../evil.js\"}",
        "{\"module\":\"../evil.js\",\"main\":\"main.js\"}",
        "{\"main\":\"/tmp/evil.js\"}",
        "{\"main\":\"C:/evil.js\"}",
    }) |json| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = json });
        try tmp.dir.writeFile(io, .{ .sub_path = "index.js", .data = "export default 1;\n" });
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);
        try testing.expectError(error.PackageJsonInvalid, resolveEntryInRoot(gpa, io, root));
    }
}

test "resolveEntryInRoot は exports があるとき legacy main へフォールバックしない" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Node 実測（v24/v26）: exports の root target が欠けていても main や
    // index.js は使わない（ERR_MODULE_NOT_FOUND）。
    try tmp.dir.writeFile(io, .{
        .sub_path = "package.json",
        .data = "{\"exports\":{\".\":\"./missing.mjs\"},\"main\":\"main.js\"}",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.js", .data = "export default 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "index.js", .data = "export default 2;\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try testing.expectError(error.EntryNotFound, resolveEntryInRoot(gpa, io, root));
}

test "resolveSubpathInRoot は package.json の name/type 不正を PackageJsonInvalid にする" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Node 実測（v24/v26）: name/type 非文字列はサブパス解決でも
    // ERR_INVALID_PACKAGE_CONFIG が先に返る。
    for ([_][]const u8{
        "{\"name\":5,\"exports\":{\"./sub\":\"./sub.mjs\"}}",
        "{\"type\":5,\"exports\":{\"./sub\":\"./sub.mjs\"}}",
    }) |json| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "pkg");
        try tmp.dir.writeFile(io, .{ .sub_path = "pkg/package.json", .data = json });
        try tmp.dir.writeFile(io, .{ .sub_path = "pkg/sub.mjs", .data = "export default 1;\n" });
        const root = try tmp.dir.realPathFileAlloc(io, "pkg", gpa);
        defer gpa.free(root);
        try testing.expectError(error.PackageJsonInvalid, resolveSubpathInRoot(gpa, io, root, "sub"));
    }
}
