//! npm package の ESM 入口解決（#54）。
//!
//! - `package.json` の `exports` / `module` / `main` から入口 path を選ぶ
//! - `exports` のサブパスキー（`"./sub"`）と 1 個の `*` wildcard を解決する
//! - `node` / `browser` 条件は暗黙選択しない（明示要求が無い限り無視）
//! - bare specifier → lock `npmInstances` + cache tree への写像
//!
//! module_graph は層境界のためここを直接 import せず、`NpmModuleResolver`
//! コールバック経由で利用する。

const std = @import("std");
const cache_key = @import("cache_key.zig");
const cache_mod = @import("cache.zig");
const lock_model = @import("lock_model.zig");
const unpack = @import("unpack.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Error = error{
    PackageJsonMissing,
    PackageJsonInvalid,
    EntryNotFound,
    BareNotFound,
    CacheMiss,
    InvalidArchive,
    OutOfMemory,
};

/// package root 内で解決した ESM 入口。
pub const ResolvedEntry = struct {
    /// 入口ファイルの絶対 path（`.js` / `.mjs`）。
    path: []u8,
    /// npm package の root 絶対 path（`package.json` がある dir）。
    package_root: []u8,

    pub fn deinit(self: ResolvedEntry, gpa: Allocator) void {
        gpa.free(self.path);
        gpa.free(self.package_root);
    }
};

/// `package.json` の入口候補を選ぶ。条件オブジェクトでは `import` と
/// `default` だけを辿り、`node` / `browser` / `require` は選ばない。
pub fn pickEntryFromPackageJson(gpa: Allocator, package_json: []const u8) Error![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, package_json, .{}) catch return error.PackageJsonInvalid;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.PackageJsonInvalid,
    };

    if (root.get("exports")) |exports_v| {
        if (try pickExportsEntry(gpa, exports_v)) |entry| return entry;
    }
    if (root.get("module")) |v| {
        if (v == .string and v.string.len > 0) return try gpa.dupe(u8, v.string);
    }
    if (root.get("main")) |v| {
        if (v == .string and v.string.len > 0) return try gpa.dupe(u8, v.string);
    }
    return try gpa.dupe(u8, "index.js");
}

fn pickExportsEntry(gpa: Allocator, value: std.json.Value) Error!?[]u8 {
    return switch (value) {
        .array => |arr| blk: {
            // 配列 fallback: 先頭から解決できる target を採る。
            for (arr.items) |item| {
                if (try pickExportsEntry(gpa, item)) |entry| break :blk entry;
            }
            break :blk null;
        },
        .object => |obj| blk: {
            // まず "." キー（root export）。無ければ条件 map 自体を辿る。
            if (obj.get(".")) |dot| {
                break :blk try pickConditionTarget(gpa, dot);
            }
            break :blk try pickConditionTarget(gpa, value);
        },
        else => try pickConditionTarget(gpa, value),
    };
}

/// 条件オブジェクトを import → default の順で辿る。`node` / `browser` /
/// `require` は暗黙有効にしない。配列は先頭から解決できる要素を採る。
fn pickConditionTarget(gpa: Allocator, value: std.json.Value) Error!?[]u8 {
    return switch (value) {
        .string => |s| if (s.len == 0) null else try gpa.dupe(u8, s),
        .array => |arr| blk: {
            for (arr.items) |item| {
                if (try pickConditionTarget(gpa, item)) |entry| break :blk entry;
            }
            break :blk null;
        },
        .object => |obj| blk: {
            if (obj.get("import")) |imp| {
                if (try pickConditionTarget(gpa, imp)) |e| break :blk e;
            }
            if (obj.get("default")) |def| {
                if (try pickConditionTarget(gpa, def)) |e| break :blk e;
            }
            break :blk null;
        },
        else => null,
    };
}

/// `exports` のサブパスキーから target を選ぶ。exact 一致を優先し、無ければ
/// 1 個の `*` を持つ wildcard を prefix 最長優先で使う。未公開なら null。
fn pickExportsSubpath(gpa: Allocator, exports_v: std.json.Value, subpath: []const u8) Error!?[]u8 {
    const obj = switch (exports_v) {
        .object => |o| o,
        else => return null,
    };
    const want = try std.fmt.allocPrint(gpa, "./{s}", .{subpath});
    defer gpa.free(want);
    if (obj.get(want)) |target| {
        return try pickConditionTarget(gpa, target);
    }

    var best_prefix_len: usize = 0;
    var best_suffix_len: usize = 0;
    var best_target: ?std.json.Value = null;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, "./")) continue;
        const star = std.mem.indexOfScalar(u8, key, '*') orelse continue;
        // 置換対象の "*" は 1 個だけに制限する。
        if (std.mem.indexOfScalar(u8, key[star + 1 ..], '*') != null) continue;
        const prefix = key[0..star];
        const suffix = key[star + 1 ..];
        if (want.len < prefix.len + suffix.len) continue;
        if (!std.mem.startsWith(u8, want, prefix)) continue;
        if (!std.mem.endsWith(u8, want, suffix)) continue;
        // Node と同じく prefix が長いパターンを優先し、同長なら key が長い方。
        if (best_target != null) {
            if (prefix.len < best_prefix_len) continue;
            if (prefix.len == best_prefix_len and key.len <= best_prefix_len + best_suffix_len + 1) continue;
        }
        best_prefix_len = prefix.len;
        best_suffix_len = suffix.len;
        best_target = entry.value_ptr.*;
    }

    const target_value = best_target orelse return null;
    const target = (try pickConditionTarget(gpa, target_value)) orelse return null;
    defer gpa.free(target);
    const matched = want[best_prefix_len .. want.len - best_suffix_len];
    return try std.mem.replaceOwned(u8, gpa, target, "*", matched);
}

/// `exports` の target が package root 内の相対 path であることを検証する。
/// 絶対 path・親セグメント・`.` セグメント・`node_modules`・Windows の
/// ドライブレターへの参照を拒否する。
fn exportTargetIsContained(target: []const u8) bool {
    if (!std.mem.startsWith(u8, target, "./")) return false;
    const rel = target[2..];
    if (rel.len == 0) return false;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, rel, '\\') != null) return false;
    var segments = std.mem.splitScalar(u8, rel, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".")) return false;
        if (std.mem.eql(u8, segment, "..")) return false;
        if (std.ascii.eqlIgnoreCase(segment, "node_modules")) return false;
        // `./C:/evil.js` のような Windows ドライブレターは root 相対の
        // セグメントとして扱えないため拒否する。
        if (segment.len == 2 and segment[1] == ':' and std.ascii.isAlphabetic(segment[0])) return false;
    }
    return true;
}

/// `name/sub` の `sub` が安全な相対セグメント列か検証する。空セグメント・
/// `.` / `..`・NUL・バックスラッシュを拒否する。
fn subpathIsSafe(subpath: []const u8) bool {
    if (subpath.len == 0) return false;
    if (std.mem.indexOfScalar(u8, subpath, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, subpath, '\\') != null) return false;
    var segments = std.mem.splitScalar(u8, subpath, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".")) return false;
        if (std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

/// `<package_root>/package.json` を読む。エラーは入口解決の Error へ写す。
fn readPackageJson(gpa: Allocator, io: std.Io, package_root_abs: []const u8) Error![]u8 {
    const pj_path = try std.fs.path.join(gpa, &.{ package_root_abs, "package.json" });
    defer gpa.free(pj_path);
    return std.Io.Dir.cwd().readFileAlloc(io, pj_path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.PackageJsonMissing,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PackageJsonInvalid,
    };
}

/// package root dir から入口の絶対 path を返す。
pub fn resolveEntryInRoot(gpa: Allocator, io: std.Io, package_root_abs: []const u8) Error!ResolvedEntry {
    const root = try gpa.dupe(u8, package_root_abs);
    errdefer gpa.free(root);

    const pj_bytes = try readPackageJson(gpa, io, root);
    defer gpa.free(pj_bytes);

    const rel = try pickEntryFromPackageJson(gpa, pj_bytes);
    defer gpa.free(rel);
    const cleaned = stripLeadingDotSlash(rel);
    if (cleaned.len == 0 or std.mem.indexOfScalar(u8, cleaned, 0) != null) return error.EntryNotFound;
    // package root 外への escapes を拒否する（セグメント単位の `..` のみ。
    // `foo..bar.js` のようなファイル名は許可する）。
    if (std.mem.startsWith(u8, cleaned, "/")) return error.EntryNotFound;
    if (pathHasParentSegment(cleaned)) return error.EntryNotFound;

    const abs = try std.fs.path.join(gpa, &.{ root, cleaned });
    errdefer gpa.free(abs);
    // 実在確認（拡張子補完は index 系に限る）。
    if (fileExists(io, abs)) {
        return .{ .path = abs, .package_root = root };
    }
    gpa.free(abs);

    // main が拡張子無しのとき .js / .mjs を試す。
    for (&[_][]const u8{ ".js", ".mjs" }) |ext| {
        const with_ext = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ root, cleaned, ext });
        errdefer gpa.free(with_ext);
        if (fileExists(io, with_ext)) {
            return .{ .path = with_ext, .package_root = root };
        }
        gpa.free(with_ext);
    }
    return error.EntryNotFound;
}

fn stripLeadingDotSlash(path: []const u8) []const u8 {
    var p = path;
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    return p;
}

/// package root から `exports` のサブパス入口を解決する。`subpath` は
/// `name/sub` の `sub`（先頭 `./` 無し）。未公開・不正な target は
/// `BareNotFound`、target ファイル欠落は `EntryNotFound`。
pub fn resolveSubpathInRoot(
    gpa: Allocator,
    io: std.Io,
    package_root_abs: []const u8,
    subpath: []const u8,
) Error!ResolvedEntry {
    if (!subpathIsSafe(subpath)) return error.BareNotFound;
    const root = try gpa.dupe(u8, package_root_abs);
    errdefer gpa.free(root);

    const pj_bytes = try readPackageJson(gpa, io, root);
    defer gpa.free(pj_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, pj_bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PackageJsonInvalid,
    };
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.PackageJsonInvalid,
    };

    const exports_v = root_obj.get("exports") orelse return error.BareNotFound;
    const target = (try pickExportsSubpath(gpa, exports_v, subpath)) orelse return error.BareNotFound;
    defer gpa.free(target);
    if (!exportTargetIsContained(target)) return error.BareNotFound;

    const abs = try std.fs.path.join(gpa, &.{ root, target[2..] });
    errdefer gpa.free(abs);
    // exports の target は拡張子補完しない（Node の exports と同じく厳密 path）。
    if (!fileExists(io, abs)) return error.EntryNotFound;
    return .{ .path = abs, .package_root = root };
}

fn pathHasParentSegment(path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return true;
    }
    return false;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// bare name → 解決済み入口。同一 context の instance 集合を保持する。
pub const BareRegistry = struct {
    gpa: Allocator,
    io: std.Io,
    /// bare name → ResolvedEntry（arena ではなく gpa 所有）。
    by_name: std.StringHashMapUnmanaged(ResolvedEntry) = .empty,
    /// package_root 絶対 path → bare name（npm 内 bare の context 復元用）。
    root_to_name: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *BareRegistry) void {
        var it = self.by_name.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.by_name.deinit(self.gpa);
        var rit = self.root_to_name.iterator();
        while (rit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.root_to_name.deinit(self.gpa);
        self.* = undefined;
    }

    /// lock の npmInstances と cache から registry を構築する。
    /// `tree_path_for` は instance の cache tree 絶対 path を返す（null = 欠落）。
    pub fn buildFromInstances(
        gpa: Allocator,
        io: std.Io,
        instances: []const lock_model.NpmInstance,
        tree_path_for: *const fn (ctx: *anyopaque, gpa: Allocator, instance: lock_model.NpmInstance) anyerror!?[]u8,
        ctx: *anyopaque,
    ) Error!BareRegistry {
        var reg: BareRegistry = .{ .gpa = gpa, .io = io };
        errdefer reg.deinit();
        for (instances) |inst| {
            if (reg.by_name.contains(inst.name)) continue;
            const tree = (tree_path_for(ctx, gpa, inst) catch return error.CacheMiss) orelse return error.CacheMiss;
            defer gpa.free(tree);
            const entry = resolveEntryInRoot(gpa, io, tree) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.EntryNotFound,
            };
            const name_key = try gpa.dupe(u8, inst.name);
            errdefer gpa.free(name_key);
            try reg.by_name.put(gpa, name_key, entry);
            const root_key = try gpa.dupe(u8, entry.package_root);
            errdefer gpa.free(root_key);
            const name_val = try gpa.dupe(u8, inst.name);
            errdefer gpa.free(name_val);
            try reg.root_to_name.put(gpa, root_key, name_val);
        }
        return reg;
    }

    /// bare specifier を解決する。返却の path/root は caller が `deinit` する。
    /// `name` は package root 入口、`name/sub` / `@scope/name/sub` は
    /// `package.json` の `exports` サブパス入口から解決する。
    pub fn resolveBare(self: *const BareRegistry, specifier: []const u8) Error!ResolvedEntry {
        const parsed = parseBareSpecifier(specifier) orelse return error.BareNotFound;
        const entry = self.by_name.get(parsed.name) orelse return error.BareNotFound;
        if (parsed.subpath.len == 0) {
            const path = try self.gpa.dupe(u8, entry.path);
            errdefer self.gpa.free(path);
            return .{
                .path = path,
                .package_root = try self.gpa.dupe(u8, entry.package_root),
            };
        }
        return resolveSubpathInRoot(self.gpa, self.io, entry.package_root, parsed.subpath);
    }
};

/// bare specifier を package 名とサブパスへ分解したもの。
pub const BareSpecifier = struct {
    /// `@scope/name` または `name`。
    name: []const u8,
    /// `name/sub` の `sub`（先頭 `./` 無し）。root 入口なら空。
    subpath: []const u8,
};

/// bare specifier を分解する。相対 path・絶対 path・traversal・空セグメントは
/// bare ではない（null）。
pub fn parseBareSpecifier(specifier: []const u8) ?BareSpecifier {
    if (specifier.len == 0 or specifier[0] == '.' or specifier[0] == '/') return null;
    if (std.mem.indexOfScalar(u8, specifier, 0) != null) return null;
    if (std.mem.indexOfScalar(u8, specifier, '\\') != null) return null;

    var name_end: usize = specifier.len;
    if (specifier[0] == '@') {
        const scope_slash = std.mem.indexOfScalar(u8, specifier[1..], '/') orelse return null;
        const name_start = 1 + scope_slash + 1;
        if (name_start >= specifier.len) return null;
        if (specifier[name_start] == '/') return null;
        name_end = if (std.mem.indexOfScalar(u8, specifier[name_start..], '/')) |sub| name_start + sub else specifier.len;
    } else if (std.mem.indexOfScalar(u8, specifier, '/')) |slash| {
        name_end = slash;
    }
    if (name_end == 0) return null;

    if (name_end == specifier.len) return .{ .name = specifier, .subpath = "" };
    const subpath = specifier[name_end + 1 ..];
    if (!subpathIsSafe(subpath)) return null;
    return .{ .name = specifier[0..name_end], .subpath = subpath };
}

/// cache key を npm integrity + url から作る（npm.zig の publish と同じ材料）。
pub fn cacheKeyForInstance(gpa: Allocator, instance: lock_model.NpmInstance) Allocator.Error!?[]u8 {
    const integrity = instance.sha256 orelse return null;
    const url = instance.url orelse return null;
    return try cache_key.artifactKey(gpa, "npm", integrity, url);
}

/// npm-tarball bytes を cache object の tree へ展開する（strip `package/`）。
/// 非 gzip 入力は raw `tree/blob` に落とす（fixture 互換）。
pub fn publishNpmTree(
    gpa: Allocator,
    io: std.Io,
    store: *const cache_mod.Store,
    key: []const u8,
    bytes: []const u8,
) !void {
    var staging = try store.openStaging(key);
    var staging_open = true;
    defer if (staging_open) staging.close(io);
    try staging.createDir(io, "tree", .default_dir);
    try staging.writeFile(io, .{ .sub_path = "source.archive", .data = bytes });
    var tree = try staging.openDir(io, "tree", .{ .iterate = true, .follow_symlinks = false });
    var tree_open = true;
    defer if (tree_open) tree.close(io);

    if (looksLikeGzip(bytes)) {
        unpack.extractTarGzInto(gpa, io, bytes, tree, .{ .strip_components = 1 }) catch return error.InvalidArchive;
    } else {
        try tree.writeFile(io, .{ .sub_path = "blob", .data = bytes });
    }
    tree.close(io);
    tree_open = false;
    staging.close(io);
    staging_open = false;
    try store.publishStaging(key);
}

fn looksLikeGzip(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "pickEntryFromPackageJson exports string" {
    const gpa = testing.allocator;
    const entry = try pickEntryFromPackageJson(gpa, "{\"exports\":\"dist/index.mjs\"}");
    defer gpa.free(entry);
    try testing.expectEqualStrings("dist/index.mjs", entry);
}

test "pickEntryFromPackageJson exports import condition ignores node" {
    const gpa = testing.allocator;
    const json =
        \\{"exports":{".":{"node":"./node.js","import":"./esm.mjs","default":"./default.js"}}}
    ;
    const entry = try pickEntryFromPackageJson(gpa, json);
    defer gpa.free(entry);
    try testing.expectEqualStrings("./esm.mjs", entry);
}

test "pickEntryFromPackageJson does not pick browser alone" {
    const gpa = testing.allocator;
    const json =
        \\{"exports":{".":{"browser":"./browser.js","require":"./cjs.js"}}}
    ;
    // import/default が無いので exports は不採用 → module/main/index
    const entry = try pickEntryFromPackageJson(gpa, json);
    defer gpa.free(entry);
    try testing.expectEqualStrings("index.js", entry);
}

test "pickEntryFromPackageJson module field" {
    const gpa = testing.allocator;
    const entry = try pickEntryFromPackageJson(gpa, "{\"module\":\"lib/mod.mjs\",\"main\":\"lib/mod.js\"}");
    defer gpa.free(entry);
    try testing.expectEqualStrings("lib/mod.mjs", entry);
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

test "pathHasParentSegment rejects only segment .." {
    try testing.expect(!pathHasParentSegment("dist/foo..bar.js"));
    try testing.expect(!pathHasParentSegment("index.js"));
    try testing.expect(pathHasParentSegment("../x.js"));
    try testing.expect(pathHasParentSegment("a/../b.js"));
    try testing.expect(pathHasParentSegment(".."));
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
    const entry = try resolveEntryInRoot(gpa, io, pkg_root);
    try reg.by_name.put(gpa, name, entry);

    const got = try reg.resolveBare("left-pad");
    defer got.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, got.path, "index.js"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("missing"));
}

/// テスト用: `dir/package.json` と root 入口、追加ファイルを作り registry へ登録する。
fn makeTestRegistry(
    gpa: Allocator,
    io: std.Io,
    tmp: *testing.TmpDir,
    dir: []const u8,
    name: []const u8,
    package_json: []const u8,
    files: []const struct { path: []const u8, data: []const u8 },
) !BareRegistry {
    try tmp.dir.createDirPath(io, dir);
    const pj = try std.fs.path.join(gpa, &.{ dir, "package.json" });
    defer gpa.free(pj);
    try tmp.dir.writeFile(io, .{ .sub_path = pj, .data = package_json });
    const root_index = try std.fs.path.join(gpa, &.{ dir, "index.js" });
    defer gpa.free(root_index);
    try tmp.dir.writeFile(io, .{ .sub_path = root_index, .data = "export default 1;\n" });
    for (files) |f| {
        const path = try std.fs.path.join(gpa, &.{ dir, f.path });
        defer gpa.free(path);
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            try tmp.dir.createDirPath(io, path[0..slash]);
        }
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = f.data });
    }
    const root = try tmp.dir.realPathFileAlloc(io, dir, gpa);
    defer gpa.free(root);
    var reg: BareRegistry = .{ .gpa = gpa, .io = io };
    errdefer reg.deinit();
    const key = try gpa.dupe(u8, name);
    errdefer gpa.free(key);
    const entry = try resolveEntryInRoot(gpa, io, root);
    try reg.by_name.put(gpa, key, entry);
    return reg;
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
    try testing.expect(std.mem.endsWith(u8, got.path, "dist/sub.mjs"));
    try testing.expect(std.mem.endsWith(u8, got.package_root, "pkg"));
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
    try testing.expect(std.mem.endsWith(u8, got.path, "dist/client.mjs"));
    // 深いサブパスも同じキー解決で扱える。
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
    try testing.expect(std.mem.endsWith(u8, cond.path, "esm.mjs"));

    const def = try reg.resolveBare("left-pad/default-only");
    defer def.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, def.path, "default.js"));

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

test "BareRegistry resolveBare rejects traversal export targets" {
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

    for ([_][]const u8{
        "left-pad/up",
        "left-pad/nested-up",
        "left-pad/abs",
        "left-pad/node-modules",
        "left-pad/upper-node-modules",
        "left-pad/bare-target",
        "left-pad/dot",
    }) |spec| {
        try testing.expectError(error.BareNotFound, reg.resolveBare(spec));
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
    try testing.expect(std.mem.endsWith(u8, root.path, "esm.mjs"));
    try testing.expect(std.mem.endsWith(u8, root.package_root, "pkg"));
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
    try testing.expect(std.mem.endsWith(u8, foo.path, "src/foo.mjs"));

    // 具体的な prefix のパターンを優先する。
    const bar = try reg.resolveBare("left-pad/features/bar");
    defer bar.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, bar.path, "feat/bar.mjs"));
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
    try testing.expect(std.mem.endsWith(u8, got.path, "esm.mjs"));
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

    // wildcard は複数セグメントにも一致し、全 `*` を置換する。
    const deep = try reg.resolveBare("left-pad/features/a/b");
    defer deep.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, deep.path, "feat/a/b.mjs"));

    // trailing slash target（空セグメント）は拒否。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/slash"));
    // Windows ドライブレター target は拒否。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/drive"));
    // wildcard の空マッチで target が `./` になる形は拒否。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/ab"));
}
