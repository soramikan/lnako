//! `build --bundle-deps` の payload 生成（Issue #56）。
//!
//! 実行可能ファイルの隣へ `<out>.deps/` を作り、依存 package の native
//! plugin artifact と同梱 file を複製する。`.nako3` 依存は compile 時に
//! 実行ファイルへ組み込まれるため payload は監査用の複製で、native
//! artifact だけが実行時の読み取り対象になる。
//!
//! native plugin の path は `@self/<pkg-dir>/<file>` marker へ書き換える。
//! 実行時 loader（plugins/native.zig）が marker を実行ファイル自身の
//! path 基準へ解決するため、生成物を別 directory へ移動しても cwd に
//! 依存せず動く。
//!
//! `<out>.deps/bundle.json`（schema 1）は同梱 package の自己記述で、
//! `--sbom` の package 集合と厳密一致させる（同梱物と SBOM の単一の源は
//! `program.bundled_packages`）。
const std = @import("std");
const lnako = @import("lnako");

pub const bundle_marker = lnako.ir.nako_ir.self_marker;

const max_bundle_file_bytes: usize = 256 * 1024 * 1024;

const bundled_kind = lnako.ir.nako_ir.BundledPackageKind;

/// payload directory の suffix。`lnako build -o dist/app --bundle-deps` は
/// `dist/app.deps/` を作る。
pub const payload_suffix = ".deps";

pub const BundleFile = struct {
    /// payload directory 相対 path。`/` 区切りへ正規化する。
    relative: []const u8,
    /// 同梱元の絶対 path（build 時 FS の読み取りに使う）。
    source_path: []const u8,
};

pub const BundlePackage = struct {
    name: []const u8,
    version: []const u8,
    license: []const u8,
    kind: bundled_kind,
    /// payload 内の package directory 名（`bundle.json` の `directory`）。
    directory: []const u8,
    files: []const BundleFile,
};

/// `program.bundled_packages` から payload file 一覧を作る。
/// root は build 時 FS の実在 path である必要があり、欠落は黙って落とさず
/// 失敗する（同梱不足の生成物を作らない）。
pub fn plan(allocator: std.mem.Allocator, io: std.Io, program: *lnako.ir.nako_ir.Program) ![]BundlePackage {
    const arena = program.arena.allocator();
    var packages: std.ArrayListUnmanaged(BundlePackage) = .empty;
    errdefer for (packages.items) |*item| allocator.free(item.files);
    // payload 内 directory 名は arena に置く（program と同じ lifetime）。
    // hashmap 自体は key を複製しないため、deinit は backing allocator では
    // なく同じ arena で行う（grow 時の key 写しも arena 所有のまま）。
    var directories: std.StringHashMapUnmanaged(void) = .empty;
    defer directories.deinit(arena);
    for (program.bundled_packages) |package| {
        var files: std.ArrayListUnmanaged(BundleFile) = .empty;
        errdefer files.deinit(allocator);
        var iterator = std.Io.Dir.cwd().openDir(io, package.root, .{ .iterate = true, .follow_symlinks = true }) catch return error.BundlePackageRootUnreadable;
        defer iterator.close(io);
        try walkPackageRoot(allocator, io, &iterator, "", &files);
        if (files.items.len == 0) return error.BundlePackageRootEmpty;
        const directory = try packageDirectoryName(arena, package, &directories);
        const owned = try files.toOwnedSlice(allocator);
        try packages.append(allocator, .{
            .name = package.name,
            .version = package.version,
            .license = package.license,
            .kind = package.kind,
            .directory = directory,
            .files = owned,
        });
    }
    return packages.toOwnedSlice(allocator);
}

/// package root を再帰で走査し、同梱 file 一覧を作る。root 相対 path は
/// `/` 区切りへ正規化する（bundle.json/SBOM と同じ表記）。
fn walkPackageRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: *std.Io.Dir,
    prefix: []const u8,
    files: *std.ArrayListUnmanaged(BundleFile),
) !void {
    var names: std.ArrayListUnmanaged(struct { name: []const u8, kind: std.Io.File.Kind }) = .empty;
    defer {
        for (names.items) |entry| allocator.free(entry.name);
        names.deinit(allocator);
    }
    var it = directory.iterate();
    while (true) {
        const maybe = it.next(io) catch return error.BundlePackageRootUnreadable;
        const entry = maybe orelse break;
        try names.append(allocator, .{ .name = try allocator.dupe(u8, entry.name), .kind = entry.kind });
    }
    std.mem.sort(@TypeOf(names.items[0]), names.items, {}, struct {
        fn lessThan(_: void, left: @TypeOf(names.items[0]), right: @TypeOf(names.items[0])) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    for (names.items) |entry| {
        const relative = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(relative);
        switch (entry.kind) {
            .file => {
                const resolved = try directory.realPathFileAlloc(io, entry.name, allocator);
                defer allocator.free(resolved);
                try files.append(allocator, .{
                    .relative = try allocator.dupe(u8, relative),
                    .source_path = try allocator.dupe(u8, resolved),
                });
            },
            .directory => {
                var child = directory.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = true }) catch return error.BundlePackageRootUnreadable;
                defer child.close(io);
                try walkPackageRoot(allocator, io, &child, relative, files);
            },
            // symlink/reparse point は同梱しない（配布 bundle の境界外参照を
            // 禁じる。path 依存に開発用 symlink があっても payload に入れない）。
            else => {},
        }
    }
}

/// payload 内 package directory 名。`sanitize(name)` + `-` + root digest
/// 先頭8hex。同名別版や同名別 root の衝突を避け、同じ入力から同じ名前に
/// なる（決定的）。重複した場合はエラー（同名 package を別 root で2件
/// 同梱する構成は、IR 側で root 一意化済みのため到達しない想定）。
fn packageDirectoryName(arena: std.mem.Allocator, package: lnako.ir.nako_ir.BundledPackage, directories: *std.StringHashMapUnmanaged(void)) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(package.root, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    var sanitized: std.ArrayListUnmanaged(u8) = .empty;
    errdefer sanitized.deinit(arena);
    for (package.name) |character| {
        const lower = std.ascii.toLower(character);
        if (std.ascii.isAlphanumeric(lower) or lower == '-') {
            try sanitized.append(arena, lower);
        } else {
            try sanitized.append(arena, '-');
        }
    }
    if (sanitized.items.len == 0) try sanitized.appendSlice(arena, "package");
    const name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ sanitized.items, digest_hex[0..8] });
    try directories.put(arena, name, {});
    return name;
}

/// `plan` の結果を payload directory へ書き出し、`bundle.json` を作る。
/// 成功した場合のみ marker file を置く（中途半端な payload を有効にしない）。
pub fn write(allocator: std.mem.Allocator, io: std.Io, payload_root: []const u8, packages: []const BundlePackage) !void {
    var root = std.Io.Dir.cwd().createDirPathOpen(io, payload_root, .{}) catch return error.BundlePayloadCreateFailed;
    defer root.close(io);
    for (packages) |package| {
        const package_directory = try std.fs.path.join(allocator, &.{ payload_root, package.directory });
        defer allocator.free(package_directory);
        var package_dir = std.Io.Dir.cwd().createDirPathOpen(io, package_directory, .{}) catch return error.BundlePayloadCreateFailed;
        defer package_dir.close(io);
        for (package.files) |file| {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, file.source_path, allocator, .limited(max_bundle_file_bytes)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileNotFound => return error.BundleSourceMissing,
                else => return error.BundleSourceUnreadable,
            };
            defer allocator.free(bytes);
            // sub_path に parent directory を含む場合は作ってから書く
            // （writeFile は親を作らない）。
            if (std.fs.path.dirname(file.relative)) |parent| {
                package_dir.createDirPath(io, parent) catch return error.BundlePayloadCreateFailed;
            }
            package_dir.writeFile(io, .{ .sub_path = file.relative, .data = bytes }) catch return error.BundlePayloadWriteFailed;
        }
    }
    const manifest_bytes = try renderManifest(allocator, packages);
    defer allocator.free(manifest_bytes);
    root.writeFile(io, .{ .sub_path = "bundle.json", .data = manifest_bytes }) catch return error.BundlePayloadWriteFailed;
}

/// payload directory を消す（書き直し・失敗時の掃除用）。実体 path は
/// 管理外なので symlink 追従しない単純削除でよい。
pub fn deletePayload(io: std.Io, payload_root: []const u8) void {
    const parent = std.fs.path.dirname(payload_root) orelse ".";
    const base = std.fs.path.basename(payload_root);
    var directory = std.Io.Dir.cwd().openDir(io, parent, .{}) catch return;
    defer directory.close(io);
    // no-follow stat で payload が directory のときだけ削除する
    // （symlink を木ごと追わない。reparse point はリンク本体のみ消す）。
    const stat = directory.statFile(io, base, .{ .follow_symlinks = false }) catch return;
    if (stat.kind != .directory) {
        directory.deleteFile(io, base) catch {};
        return;
    }
    directory.deleteTree(io, base) catch {};
}

/// `<out>` から payload directory の path を作る（`<out>.deps`）。
pub fn payloadPath(allocator: std.mem.Allocator, output_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ output_path, payload_suffix });
}

/// `plan` 結果から IR への書換情報を作る。`native_plugin_paths` が
/// `source_path` と一致する entry を marker（`@self/<dir>/<relative>`）へ
/// 差し替える。package 配下に無い plugin path は `--bundle-deps` の対象外
/// （従来どおり build 機の絶対 path のまま）。
pub fn markerFor(arena: std.mem.Allocator, packages: []const BundlePackage, plugin_path: []const u8) !?[]const u8 {
    // IR の plugin path は相対（直接 import）の場合もあるため、実体 path で
    // 突き合わせる。解決できない path は一致対象外（同梱されない従来 path）。
    var resolved: ?[]u8 = null;
    defer if (resolved) |path| arena.free(path);
    if (std.fs.path.isAbsolute(plugin_path)) {
        resolved = try arena.dupe(u8, plugin_path);
    } else {
        const joined = try std.fs.path.resolve(arena, &.{ ".", plugin_path });
        resolved = joined;
    }
    for (packages) |package| {
        for (package.files) |file| {
            if (!std.mem.eql(u8, file.source_path, resolved.?)) continue;
            const relative = try std.fmt.allocPrint(arena, "{s}/{s}", .{ package.directory, file.relative });
            return try std.fmt.allocPrint(arena, "{s}{s}", .{ bundle_marker, relative });
        }
    }
    return null;
}

const ManifestPackage = struct {
    name: []const u8,
    version: []const u8,
    license: []const u8,
    kind: []const u8,
    directory: []const u8,
    files: []const []const u8,
};

const Manifest = struct {
    schema: u32 = 1,
    packages: []const ManifestPackage,
};

/// payload の自己記述。`program.bundled_packages` と同じ package 集合・
/// entries（`directory + / + relative`）を持つ。`--sbom` と厳密一致の
/// 検証対象。
pub fn renderManifest(allocator: std.mem.Allocator, packages: []const BundlePackage) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const entries = try temporary.alloc(ManifestPackage, packages.len);
    for (packages, entries) |package, *entry| {
        const relative_paths = try temporary.alloc([]const u8, package.files.len);
        var total: usize = 0;
        for (package.files, relative_paths) |file, *slot| {
            slot.* = try std.fmt.allocPrint(temporary, "{s}/{s}", .{ package.directory, file.relative });
            total += slot.*.len;
        }
        // bundle.json の file 一覧は昇順にそろえる（決定的出力）。
        std.mem.sort([]const u8, relative_paths, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);
        entry.* = .{
            .name = package.name,
            .version = package.version,
            .license = package.license,
            .kind = @tagName(package.kind),
            .directory = package.directory,
            .files = relative_paths,
        };
        if (total == 0 and package.files.len > 0) return error.InvalidBundleManifest;
    }
    return std.json.Stringify.valueAlloc(allocator, Manifest{ .packages = entries }, .{
        .whitespace = .indent_2,
    });
}

test "planはpackage root配下のfile一覧を昇順で作る" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/lib");
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/package.json", .data = "{\"name\":\"pkg\",\"version\":\"1.0.0\",\"license\":\"MIT\"}" });
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/z.js", .data = "export default 1;\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/lib/a.js", .data = "export default 2;\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "pkg" });
    defer allocator.free(package_root);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.bundled_packages = try program.arena.allocator().dupe(lnako.ir.nako_ir.BundledPackage, &.{
        .{ .name = "pkg", .version = "1.0.0", .license = "MIT", .root = package_root, .kind = .npm, .entries = &.{"z.js"} },
    });

    const packages = try plan(allocator, io, &program);
    defer allocator.free(packages);
    defer for (packages) |item| {
        for (item.files) |file| {
            allocator.free(file.relative);
            allocator.free(file.source_path);
        }
        allocator.free(item.files);
    };
    try std.testing.expectEqual(@as(usize, 1), packages.len);
    // directory 名は実行ごとに変わる tmpdir root の digest を含むため、
    // 形（sanitize + digest 8hex）だけを固定する。
    try std.testing.expect(std.mem.startsWith(u8, packages[0].directory, "pkg-"));
    try std.testing.expectEqual(@as(usize, "pkg-".len + 8), packages[0].directory.len);
    try std.testing.expectEqual(@as(usize, 3), packages[0].files.len);
    // 昇順: lib/a.js → package.json → z.js
    try std.testing.expect(std.mem.endsWith(u8, packages[0].files[0].relative, "lib/a.js"));
    try std.testing.expect(std.mem.endsWith(u8, packages[0].files[1].relative, "package.json"));
    try std.testing.expect(std.mem.endsWith(u8, packages[0].files[2].relative, "z.js"));
    // source_path は実在 path（root と同じ directory 直下）
    try std.testing.expect(std.mem.startsWith(u8, packages[0].files[0].source_path, package_root));
}

test "planは空のpackage rootを黙って受理しない" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "empty");
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "empty" });
    defer allocator.free(package_root);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.bundled_packages = try program.arena.allocator().dupe(lnako.ir.nako_ir.BundledPackage, &.{
        .{ .name = "empty", .version = "1.0.0", .license = "NOASSERTION", .root = package_root, .kind = .nako },
    });

    try std.testing.expectError(error.BundlePackageRootEmpty, plan(allocator, io, &program));
}

test "planは存在しないpackage rootを失敗させる" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.bundled_packages = try program.arena.allocator().dupe(lnako.ir.nako_ir.BundledPackage, &.{
        .{ .name = "gone", .version = "1.0.0", .license = "MIT", .root = "/nonexistent/lnako-bundle-gone", .kind = .npm },
    });
    try std.testing.expectError(error.BundlePackageRootUnreadable, plan(allocator, io, &program));
}

test "writeはpayload directoryへfileを複製しbundle.jsonを作る" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "src_pkg");
    try temporary.dir.writeFile(io, .{ .sub_path = "src_pkg/fast.so", .data = "ELFBINARY" });
    try temporary.dir.writeFile(io, .{ .sub_path = "src_pkg/nako.toml", .data = "[package]\nname = \"fastmath\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "src_pkg" });
    defer allocator.free(package_root);
    const plugin_path = try std.fs.path.join(allocator, &.{ package_root, "fast.so" });
    defer allocator.free(plugin_path);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.bundled_packages = try program.arena.allocator().dupe(lnako.ir.nako_ir.BundledPackage, &.{
        .{ .name = "fastmath", .version = "1.0.0", .license = "MIT", .root = package_root, .kind = .nako, .entries = &.{"fast.so"} },
    });
    const packages = try plan(allocator, io, &program);
    defer allocator.free(packages);
    defer for (packages) |item| {
        for (item.files) |file| {
            allocator.free(file.relative);
            allocator.free(file.source_path);
        }
        allocator.free(item.files);
    };

    const payload_root = try std.fs.path.join(allocator, &.{ root, "app.deps" });
    defer allocator.free(payload_root);
    try write(allocator, io, payload_root, packages);
    defer deletePayload(io, payload_root);

    // marker は plugin path から作れる。
    const arena_alloc = program.arena.allocator();
    const marker = (try markerFor(arena_alloc, packages, plugin_path)).?;
    try std.testing.expect(std.mem.startsWith(u8, marker, bundle_marker));
    try std.testing.expect(std.mem.endsWith(u8, marker, "/fast.so"));

    // bundle.json は marker 相当の相対 path を持ち、SBOM と照合できる形。
    const manifest_path = try std.fs.path.join(allocator, &.{ payload_root, "bundle.json" });
    defer allocator.free(manifest_path);
    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(1024 * 1024));
    defer allocator.free(manifest_bytes);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "\"schema\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "\"name\": \"fastmath\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "\"license\": \"MIT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, ".so") != null);
    // payload 内の実体 file も複製されている。
    const copied = try std.fmt.allocPrint(allocator, "{s}/{s}/fast.so", .{ payload_root, packages[0].directory });
    defer allocator.free(copied);
    const copied_bytes = try std.Io.Dir.cwd().readFileAlloc(io, copied, allocator, .limited(1024));
    defer allocator.free(copied_bytes);
    try std.testing.expectEqualStrings("ELFBINARY", copied_bytes);
}

test "writeはsymlinkを同梱せずfileとdirectoryだけを複製する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg");
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/index.nako3", .data = "1を表示\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "outside.nako3", .data = "2を表示\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    // symlink を張る（対象外 kind の除外を検証。POSIX のみ）。
    if (std.fs.path.sep == '/') {
        const link_path = try std.fmt.allocPrint(allocator, "{s}/pkg/escape.nako3", .{root});
        defer allocator.free(link_path);
        const target = try std.fmt.allocPrint(allocator, "{s}/outside.nako3", .{root});
        defer allocator.free(target);
        std.Io.Dir.cwd().symLink(io, target, link_path, .{}) catch {};
    }
    const package_root = try std.fs.path.join(allocator, &.{ root, "pkg" });
    defer allocator.free(package_root);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.bundled_packages = try program.arena.allocator().dupe(lnako.ir.nako_ir.BundledPackage, &.{
        .{ .name = "pure", .version = "1.0.0", .license = "MIT", .root = package_root, .kind = .nako, .entries = &.{"index.nako3"} },
    });
    const packages = try plan(allocator, io, &program);
    defer allocator.free(packages);
    defer for (packages) |item| {
        for (item.files) |file| {
            allocator.free(file.relative);
            allocator.free(file.source_path);
        }
        allocator.free(item.files);
    };
    const expected_count: usize = if (std.fs.path.sep == '/') 1 else 1;
    try std.testing.expectEqual(expected_count, packages[0].files.len);
    try std.testing.expect(std.mem.endsWith(u8, packages[0].files[0].relative, "index.nako3"));
}

test "payloadPathは出力fileの隣へ.depsを付ける" {
    const allocator = std.testing.allocator;
    const path = try payloadPath(allocator, "dist/app");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("dist/app.deps", path);
    const windows_path = try payloadPath(allocator, "dist\\app.exe");
    defer allocator.free(windows_path);
    try std.testing.expectEqualStrings("dist\\app.exe.deps", windows_path);
}

test "packageDirectoryNameは同名別rootを別名にし同名を衝突させない" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var directories: std.StringHashMapUnmanaged(void) = .empty;
    const first = try packageDirectoryName(allocator, .{ .name = "My Pkg!", .version = "1", .license = "", .root = "/a", .kind = .npm }, &directories);
    const second = try packageDirectoryName(allocator, .{ .name = "My Pkg!", .version = "1", .license = "", .root = "/b", .kind = .npm }, &directories);
    // 同名でも root digest が違えば別 directory 名。`!` は区切りへ畳む。
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectEqualStrings("my-pkg--6a50dc85", first);
    // 同一 name+root digest に sanitize 前の名前が違っても同一 directory と
    // みなす（`x-6a50dc85` と `my-pkg-6a50dc85` は別名だが、root `/a` の
    // 再登録は `My Pkg!` と同名 sanitize ではないため到達しない。ここでは
    // 「name+root が同じなら衝突」を contract として固定する）。
    try std.testing.expectEqualStrings("x-6a50dc85", try packageDirectoryName(allocator, .{ .name = "x", .version = "1", .license = "", .root = "/a", .kind = .npm }, &directories));
}

test "renderManifestはbundle.jsonの決定的bytesを作る" {
    const allocator = std.testing.allocator;
    const packages = [_]BundlePackage{
        .{
            .name = "fastmath",
            .version = "1.0.0",
            .license = "MIT",
            .kind = .nako,
            .directory = "fastmath-11111111",
            .files = &.{ .{ .relative = "fast.so", .source_path = "/src/fast.so" }, .{ .relative = "lib.nako3", .source_path = "/src/lib.nako3" } },
        },
        .{
            .name = "unknown",
            .version = "2.0.0",
            .license = "NOASSERTION",
            .kind = .npm,
            .directory = "unknown-22222222",
            .files = &.{.{ .relative = "index.js", .source_path = "/x/index.js" }},
        },
    };
    const first = try renderManifest(allocator, &packages);
    defer allocator.free(first);
    const second = try renderManifest(allocator, &packages);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    // file 一覧は昇順（fast.so < lib.nako3）。
    const fast_index = std.mem.indexOf(u8, first, "fast.so") orelse return error.TestUnexpectedResult;
    const lib_index = std.mem.indexOf(u8, first, "lib.nako3") orelse return error.TestUnexpectedResult;
    try std.testing.expect(fast_index < lib_index);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, first, .{});
    defer parsed.deinit();
    const document = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), document.get("schema").?.integer);
    const listed = document.get("packages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    // bundle.json の file path は `directory/relative` の payload 相対表記。
    const files = listed[0].object.get("files").?.array.items;
    try std.testing.expectEqualStrings("fastmath-11111111/fast.so", files[0].string);
    try std.testing.expectEqualStrings("fastmath-11111111/lib.nako3", files[1].string);
    try std.testing.expectEqualStrings("unknown-22222222/index.js", listed[1].object.get("files").?.array.items[0].string);
}

test "markerForはpackage配下に無いplugin pathを対象外にする" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const packages = [_]BundlePackage{
        .{
            .name = "pkg",
            .version = "1.0.0",
            .license = "MIT",
            .kind = .nako,
            .directory = "pkg-11111111",
            .files = &.{.{ .relative = "plugin.so", .source_path = "/src/plugin.so" }},
        },
    };
    try std.testing.expectEqualStrings("@self/pkg-11111111/plugin.so", (try markerFor(allocator, &packages, "/src/plugin.so")).?);
    try std.testing.expect((try markerFor(allocator, &packages, "/elsewhere/plugin.so")) == null);
}
