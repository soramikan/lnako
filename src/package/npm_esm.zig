//! npm package の ESM 入口解決（#54）。
//!
//! - `package.json` の `exports` / `module` / `main` から入口 path を選ぶ
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
        .string => |s| if (s.len == 0) null else try gpa.dupe(u8, s),
        .object => |obj| blk: {
            // まず "." キー（root export）。無ければ条件 map 自体を辿る。
            if (obj.get(".")) |dot| {
                break :blk try pickExportsEntry(gpa, dot);
            }
            // 条件オブジェクト: import → default のみ。node/browser は無視。
            if (obj.get("import")) |imp| {
                if (try pickExportsEntry(gpa, imp)) |e| break :blk e;
            }
            if (obj.get("default")) |def| {
                if (try pickExportsEntry(gpa, def)) |e| break :blk e;
            }
            break :blk null;
        },
        else => null,
    };
}

/// package root dir から入口の絶対 path を返す。
pub fn resolveEntryInRoot(gpa: Allocator, io: std.Io, package_root_abs: []const u8) Error!ResolvedEntry {
    const root = try gpa.dupe(u8, package_root_abs);
    errdefer gpa.free(root);

    const pj_path = try std.fs.path.join(gpa, &.{ root, "package.json" });
    defer gpa.free(pj_path);
    const pj_bytes = std.Io.Dir.cwd().readFileAlloc(io, pj_path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.PackageJsonMissing,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PackageJsonInvalid,
    };
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
    /// 第一波は package root 入口のみ（`name/subpath` は拒否）。
    pub fn resolveBare(self: *const BareRegistry, specifier: []const u8) Error!ResolvedEntry {
        const name = barePackageName(specifier) orelse return error.BareNotFound;
        // サブパス付き（`lodash/fp` や `@scope/pkg/sub`）は未対応。
        if (name.len != specifier.len) return error.BareNotFound;
        const entry = self.by_name.get(name) orelse return error.BareNotFound;
        return .{
            .path = try self.gpa.dupe(u8, entry.path),
            .package_root = try self.gpa.dupe(u8, entry.package_root),
        };
    }
};

/// bare specifier から package 名を切り出す。`@scope/name` または `name`。
/// サブパスがある場合も name 部分だけ返す（呼び出し側が長さ比較で検出）。
fn barePackageName(specifier: []const u8) ?[]const u8 {
    if (specifier.len == 0 or specifier[0] == '.' or specifier[0] == '/') return null;
    if (specifier[0] == '@') {
        const slash = std.mem.indexOfScalar(u8, specifier[1..], '/') orelse return null;
        const rest = specifier[1 + slash + 1 ..];
        if (rest.len == 0) return null;
        if (std.mem.indexOfScalar(u8, rest, '/')) |sub| {
            return specifier[0 .. 1 + slash + 1 + sub];
        }
        return specifier;
    }
    if (std.mem.indexOfScalar(u8, specifier, '/')) |slash| {
        return specifier[0..slash];
    }
    return specifier;
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
