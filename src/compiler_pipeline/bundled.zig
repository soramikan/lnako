//! `--compat-js` 生成物へ source を同梱した package の記録（Issue #56）。
//!
//! module_graph は JS module ごとに `package_root` を持つが、package 単位の
//! 帰属（name/version/license）は持たない。生成物の ESM manifest と
//! `--sbom` 出力が同じ記録を読めるよう、compile 直後に一度だけ package root
//! を一意化して metadata を読む。読み取りは build 時 FS に対するもので、
//! 生成物の実行時には不要（source は manifest に収録済み）。
//!
//! パッケージ仕様 v1 の同梱物（`.npkg` の展開先）は `nako.toml` ではなく、
//! 検証済みの `NAKO-PKG/METADATA.toml` を package の正本として持つ。npm 由来
//! の package は従来どおり `package.json` を読む。
const std = @import("std");
const lnako = @import("lnako");
const v1_metadata = lnako.package.v1_metadata;

/// `--bundle-deps` で `.nako3` 依存（source-only / native plugin）も収集する
/// 拡張モード。CLI が `--bundle-deps` 指定時だけ立てる（既存の compat AOT
/// 経路では JS modules だけを収集する現状を変えない）。
pub var bundle_deps_enabled: bool = false;

const max_package_metadata_bytes: usize = 1024 * 1024;

/// v1 配布物の package root を示す正本 metadata の位置。展開済み `.npkg` は
/// `NAKO-PKG/` の制御 file と payload だけを収録し、`nako.toml` は持たない。
const v1_metadata_dir = "NAKO-PKG";
const v1_metadata_name = "METADATA.toml";

/// 宣言 license が無い package の SPDX 表現。SBOM では「未主張」を意味し、
/// 空文字（= 不明な状態を隠す）とは区別する。
pub const unknown_license = "NOASSERTION";

/// `program.javascript_modules` の package root を一意化し、package 単位の
/// metadata を `program.bundled_packages` へ記録する。
///
/// `bundle_deps` が有効な場合は `.nako3` 依存（source-only / native plugin
/// 含む）も同梱対象にする。module_graph は `.nako3` package module を
/// `module_paths` と `package_root` でしか保持しないため、帰属は
/// `module_paths[i]` が `package_root` 配下にあるかで判定する（JS modules
/// の attribution 規約と同じ境界判定）。必要な manifest が無い root は、
/// 黙って同梱物から落とさず `error.MissingBundledPackageMetadata` で
/// 失敗する。
pub fn collect(allocator: std.mem.Allocator, io: std.Io, program: *lnako.ir.nako_ir.Program) !void {
    return collectForProject(allocator, io, program, null);
}

/// `project_root` は `--bundle-deps` の同梱対象から除外する project 自身の
/// root（null は境界なし）。project の entry やローカル module は
/// `module_paths` に絶対 path で載るため、境界が無いと project 自身の
/// `nako.toml` が package として同梱され、project 全体（`.nako/`・秘密
/// file 含む）が payload へ漏れる。
pub fn collectForProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    program: *lnako.ir.nako_ir.Program,
    project_root: ?[]const u8,
) !void {
    const bundle_nako3 = bundle_deps_enabled;
    if (program.javascript_modules.len == 0 and (!bundle_nako3 or program.module_paths.len == 0)) {
        program.bundled_packages = &.{};
        return;
    }
    const arena = program.arena.allocator();
    var packages: std.ArrayListUnmanaged(Builder) = .empty;
    defer packages.deinit(allocator);
    // 途中で失敗した場合も、既に集めた package の entry list を解放する。
    errdefer for (packages.items) |*builder| builder.entries.deinit(allocator);
    var roots: std.StringHashMapUnmanaged(usize) = .empty;
    defer roots.deinit(allocator);

    for (program.javascript_modules) |module| {
        if (module.package_attributions.len == 0) {
            // 帰属を持たない古い/合成 IR は代表 root だけを unknown として扱う。
            const root = module.package_root orelse continue;
            if (root.len == 0) continue;
            if (relativeEntry(root, module.path)) |entry| try registerRoot(allocator, arena, &roots, &packages, root, .unknown, entry);
            continue;
        }
        for (module.package_attributions) |attribution| {
            if (attribution.root.len == 0) continue;
            const origin: Origin = if (attribution.npm) .npm else .nako;
            const entry: ?[]const u8 = relativeEntry(attribution.root, module.path);
            try registerRoot(allocator, arena, &roots, &packages, attribution.root, origin, entry);
        }
    }

    // `--bundle-deps`: `.nako3` 依存 package（source-only / native plugin）を
    // 収集する。module_paths の package module は package root 配下にある
    // ので、JS attribution と同じ境界判定で root 相対 path を作る。native
    // plugin は `native_plugin_paths` から root 配下のものを拾う（実行時に
    // payload へ複製される artifact）。
    if (bundle_nako3) {
        for (program.module_paths) |module_path| {
            try registerNako3Root(allocator, io, arena, &roots, &packages, module_path, project_root);
        }
        for (program.native_plugin_paths) |plugin_path| {
            try registerNako3Root(allocator, io, arena, &roots, &packages, plugin_path, project_root);
        }
    }

    if (packages.items.len == 0) {
        program.bundled_packages = &.{};
        return;
    }

    const collected = try arena.alloc(lnako.ir.nako_ir.BundledPackage, packages.items.len);
    for (packages.items, collected) |*builder, *destination| {
        const metadata = try readMetadata(allocator, arena, io, builder.root, builder.origin);
        std.mem.sort([]const u8, builder.entries.items, {}, lessThanString);
        var previous: ?[]const u8 = null;
        var unique: usize = 0;
        for (builder.entries.items) |entry| {
            if (previous) |last| if (std.mem.eql(u8, last, entry)) continue;
            builder.entries.items[unique] = entry;
            unique += 1;
            previous = entry;
        }
        const entries = try arena.alloc([]const u8, unique);
        for (builder.entries.items[0..unique], entries) |entry, *destination_entry| destination_entry.* = entry;
        destination.* = .{
            .name = metadata.name,
            .version = metadata.version,
            .license = metadata.license,
            .root = try arena.dupe(u8, builder.root),
            .kind = metadata.kind,
            .entries = entries,
        };
    }
    for (packages.items) |*builder| builder.entries.deinit(allocator);
    program.bundled_packages = collected;
}

/// 同梱 package の依存出自。npm instance か path 依存の nako package かで
/// 読む manifest と purl を変える。
const Origin = enum { npm, nako, unknown };

fn registerRoot(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    roots: *std.StringHashMapUnmanaged(usize),
    packages: *std.ArrayListUnmanaged(Builder),
    root: []const u8,
    origin: Origin,
    entry: ?[]const u8,
) !void {
    const get_or_put = try roots.getOrPut(allocator, root);
    if (!get_or_put.found_existing) {
        get_or_put.value_ptr.* = packages.items.len;
        try packages.append(allocator, .{ .root = root, .origin = origin });
    } else if (packages.items[get_or_put.value_ptr.*].origin == .unknown and origin != .unknown) {
        packages.items[get_or_put.value_ptr.*].origin = origin;
    }
    const index = get_or_put.value_ptr.*;
    if (entry) |value| {
        try packages.items[index].entries.append(allocator, try normalizedEntry(arena, value));
    }
}

const Builder = struct {
    root: []const u8,
    origin: Origin = .unknown,
    entries: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// `.nako3` / native plugin module の path から所属 package root を探して
/// 登録する。module path から上へ辿り、`NAKO-PKG/METADATA.toml` を持つ最初の
/// directory を package root とする（`package_owner` 付き import edge の
/// PackageInheritance.root と同じ「最内 package root」規約）。root が見つから
/// ない module（project 自身の entry や直接 path import）は同梱対象外。
fn registerNako3Root(
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    roots: *std.StringHashMapUnmanaged(usize),
    packages: *std.ArrayListUnmanaged(Builder),
    module_path: []const u8,
    project_root: ?[]const u8,
) !void {
    const root = try findPackageRoot(arena, io, module_path, project_root) orelse return;
    // project 自身の root は同梱対象外（境界チェックの二重防御）。
    if (project_root) |boundary| {
        if (samePath(io, arena, root, boundary)) return;
    }
    const entry = relativeEntry(root, module_path) orelse return;
    try registerRoot(allocator, arena, roots, packages, root, .nako, entry);
}

/// 2 つの path が同一 directory を指すか。末尾 separator を無視した字句
/// 比較に加え、実体 path での比較も行う。`/tmp` と `/private/tmp` の
/// ように symlink を挟むと同じ directory でも字句が異なるため、字句一致
/// だけで判定すると project 境界を見落として project 全体を同梱する。
fn samePath(io: std.Io, arena: std.mem.Allocator, left: []const u8, right: []const u8) bool {
    var a = left;
    var b = right;
    while (a.len > 1 and (a[a.len - 1] == '/' or a[a.len - 1] == std.fs.path.sep)) a = a[0 .. a.len - 1];
    while (b.len > 1 and (b[b.len - 1] == '/' or b[b.len - 1] == std.fs.path.sep)) b = b[0 .. b.len - 1];
    if (std.mem.eql(u8, a, b)) return true;
    // realpath での比較。解決できない（削除済み等）場合は字句判定に委ねる。
    const real_a = std.Io.Dir.cwd().realPathFileAlloc(io, a, arena) catch return false;
    const real_b = std.Io.Dir.cwd().realPathFileAlloc(io, b, arena) catch return false;
    return std.mem.eql(u8, real_a, real_b);
}

/// `module_path` から上へ辿り、v1 配布物の正本 `NAKO-PKG/METADATA.toml` を
/// 持つ最内 directory を返す。見つからなければ null。directory の読み取り
/// 失敗は package root の不在と同じ扱いにする（上へ継続）。
///
/// 旧形式の `nako.toml` は探索しない。v1 の package root は展開済み
/// payload であり、project 自身の v1 `nako.toml` は境界として除外する。
fn findPackageRoot(
    arena: std.mem.Allocator,
    io: std.Io,
    module_path: []const u8,
    project_root: ?[]const u8,
) !?[]const u8 {
    var directory = std.fs.path.dirname(module_path) orelse return null;
    while (true) {
        // project 自身の root に達したら打ち切る。境界が無いと monorepo root
        // や $HOME のような無関係な祖先 dir を package root として拾い、
        // その木全体を payload へ複製してしまう。
        if (project_root) |boundary| {
            if (samePath(io, arena, directory, boundary)) return null;
        }
        if (try packageMetadataExists(arena, io, directory)) return directory;
        const parent = std.fs.path.dirname(directory) orelse return null;
        if (parent.len == directory.len) return null;
        directory = parent;
    }
}

/// package root の正本 metadata の存在確認。`--bundle-deps` なしでは呼ばれない。
fn packageMetadataExists(arena: std.mem.Allocator, io: std.Io, directory: []const u8) !bool {
    const path = try std.fs.path.join(arena, &.{ directory, v1_metadata_dir, v1_metadata_name });
    return fileExists(io, path);
}

/// 通常 file として開けるか。directory 等は不在として扱う。
fn fileExists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// `arena` に所有を移した metadata。`temporary` は parse/書式化の一時領域で、
/// 返却前に解放できる。
const Metadata = struct {
    name: []const u8,
    version: []const u8,
    license: []const u8,
    kind: lnako.ir.nako_ir.BundledPackageKind,
};

/// 出自に応じて読む metadata を選ぶ。`unknown`（owner 不明）は従来どおり
/// package.json → v1 METADATA.toml の順で試す。
fn readMetadata(temporary: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, root: []const u8, origin: Origin) !Metadata {
    switch (origin) {
        .npm => return readPackageJson(temporary, arena, io, root),
        .nako => return readV1Metadata(temporary, arena, io, root),
        .unknown => {
            if (readPackageJson(temporary, arena, io, root)) |metadata| {
                return metadata;
            } else |err| switch (err) {
                error.MissingBundledPackageMetadata => {},
                else => return err,
            }
            return readV1Metadata(temporary, arena, io, root);
        },
    }
}

fn readPackageJson(temporary: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, root: []const u8) !Metadata {
    const bytes = (try readOptionalFile(temporary, io, root, "package.json")) orelse return error.MissingBundledPackageMetadata;
    defer temporary.free(bytes);
    var manifest = lnako.package.package_json.parse(temporary, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PackageJsonInvalid => return error.InvalidBundledPackageJson,
    };
    defer manifest.deinit();
    return .{
        .name = try arena.dupe(u8, manifest.name orelse ""),
        .version = try arena.dupe(u8, manifest.version orelse ""),
        .license = try packageLicense(arena, manifest.license_declared, manifest.license_alternatives),
        .kind = .npm,
    };
}

/// v1 配布物の正本 `NAKO-PKG/METADATA.toml` を読む。`[package]` の
/// `id`（`@scope/name` を含む）・`version`・`license` をそのまま同梱物の
/// 帰属にする。旧 `nako.toml` は v1 の package root には存在せず、読み替え
/// もしない（旧形式の復活をしない）。
fn readV1Metadata(temporary: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, root: []const u8) !Metadata {
    const path = try std.fs.path.join(temporary, &.{ root, v1_metadata_dir, v1_metadata_name });
    defer temporary.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, temporary, .limited(max_package_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingBundledPackageMetadata,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BundledPackageMetadataUnreadable,
    };
    defer temporary.free(bytes);
    var parsed = v1_metadata.parse(temporary, bytes, arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // 旧 `schemaVersion` 形式もここで拒否し、v1 正本として読み替えない。
        else => return error.InvalidBundledPackageMetadata,
    };
    defer parsed.document.deinit();
    return .{
        .name = try arena.dupe(u8, parsed.model.package.id),
        .version = try arena.dupe(u8, parsed.model.package.version),
        .license = try arena.dupe(u8, declaredLicense(parsed.model.package.license)),
        .kind = .nako,
    };
}

/// 宣言 license を 1 つの式へ。`license` が無い旧形式は `licenses` 配列の
/// 全選択肢を ` OR ` で連結する（選択肢を落とさない。SPDX 式として不正なら
/// SBOM 側が NOASSERTION へ正規化する）。
fn packageLicense(arena: std.mem.Allocator, declared: ?[]const u8, alternatives: []const []const u8) ![]const u8 {
    if (declared) |value| return arena.dupe(u8, declaredLicense(value));
    if (alternatives.len == 0) return arena.dupe(u8, unknown_license);
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    for (alternatives, 0..) |alternative, index| {
        if (index > 0) try buffer.appendSlice(arena, " OR ");
        try buffer.appendSlice(arena, alternative);
    }
    return buffer.toOwnedSlice(arena);
}

fn readOptionalFile(allocator: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8) !?[]u8 {
    const path = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_package_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        error.OutOfMemory => error.OutOfMemory,
        else => error.BundledPackageMetadataUnreadable,
    };
}

/// 宣言値として使えない空文字は SPDX の NOASSERTION へ正規化する。
fn declaredLicense(declared: ?[]const u8) []const u8 {
    const value = declared orelse return unknown_license;
    return if (value.len == 0) unknown_license else value;
}

/// entry の区切りを manifest/SBOM の表記に揃えて `/` にする。Windows の
/// module path から作った entry も platform 非依存な表記へ揃え、生成物や
/// SBOM の内容が OS で変わらないようにする。
fn normalizedEntry(allocator: std.mem.Allocator, entry: []const u8) ![]const u8 {
    // POSIX の `\\` は区切りではなくファイル名の文字なので変換しない。
    if (std.fs.path.sep != '\\' or std.mem.indexOfScalar(u8, entry, '\\') == null) return allocator.dupe(u8, entry);
    const normalized = try allocator.alloc(u8, entry.len);
    for (entry, normalized) |byte, *destination| destination.* = if (byte == '\\') '/' else byte;
    return normalized;
}

/// `path` が `root` 直下にある場合の root 相対 path。
/// 区切りは元 path のまま（Windows では `\\`）。entries は manifest と SBOM の
/// 表示専用で、同じ platform の module path と同じ表記になる。
fn relativeEntry(root: []const u8, path: []const u8) ?[]const u8 {
    if (path.len <= root.len or !std.mem.startsWith(u8, path, root)) return null;
    // 共通 prefix の兄弟 directory（`leftpad` と `leftpad2`）を誤帰属させない
    // ため、root 境界の直後が platform の区切りであることを要求する
    // （POSIX の `\\` は正当なファイル名文字なので境界にしない）。
    // module_graph の `pathWithinRoot` と同じ判定。
    if (path[root.len] != std.fs.path.sep) return null;
    const rest = path[root.len + 1 ..];
    if (rest.len == 0) return null;
    return rest;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// テスト用: v1 配布物の正本 metadata を `root/NAKO-PKG/METADATA.toml` へ書く。
fn writeV1Metadata(temporary: *std.testing.TmpDir, io: std.Io, root: []const u8, text: []const u8) !void {
    const directory = try std.fs.path.join(std.testing.allocator, &.{ root, v1_metadata_dir });
    defer std.testing.allocator.free(directory);
    try temporary.dir.createDirPath(io, directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, v1_metadata_dir, v1_metadata_name });
    defer std.testing.allocator.free(path);
    try temporary.dir.writeFile(io, .{ .sub_path = path, .data = text });
}

/// テスト用: universal v1 package の同一性を持つ正本 metadata を組み立てる。
fn v1UniversalMetadata(allocator: std.mem.Allocator, id: []const u8, version: []const u8, license: []const u8, entry: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\schema_version = 1
        \\
        \\[package]
        \\id = "{s}"
        \\version = "{s}"
        \\license = "{s}"
        \\
        \\[artifact]
        \\kind = "universal"
        \\runtimes = ["lnako", "cnako", "wnako"]
        \\
        \\[exports]
        \\"." = {{ entry = "{s}" }}
        \\
    , .{ id, version, license, entry });
}

test "同梱packageのname/version/licenseと解決済みentryを収集する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "npm_left-pad");
    try temporary.dir.createDirPath(io, "packages/leftpad");
    try temporary.dir.writeFile(io, .{
        .sub_path = "npm_left-pad/package.json",
        .data = "{\"name\":\"left-pad\",\"version\":\"1.0.0\",\"license\":\"MIT\",\"main\":\"index.js\"}",
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "npm_left-pad/index.js", .data = "export default 1;\n" });
    const nako_metadata = try v1UniversalMetadata(allocator, "@example/leftpad", "1.2.3", "MIT", "plugin.mjs");
    defer allocator.free(nako_metadata);
    try writeV1Metadata(&temporary, io, "packages/leftpad", nako_metadata);
    try temporary.dir.writeFile(io, .{ .sub_path = "packages/leftpad/plugin.mjs", .data = "export default {};\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const npm_root = try std.fs.path.join(allocator, &.{ root, "npm_left-pad" });
    defer allocator.free(npm_root);
    const nako_root = try std.fs.path.join(allocator, &.{ root, "packages", "leftpad" });
    defer allocator.free(nako_root);
    const npm_entry = try std.fs.path.join(allocator, &.{ npm_root, "index.js" });
    defer allocator.free(npm_entry);
    const nako_entry = try std.fs.path.join(allocator, &.{ nako_root, "plugin.mjs" });
    defer allocator.free(nako_entry);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    const arena = program.arena.allocator();
    program.javascript_modules = try arena.dupe(lnako.ir.nako_ir.JavaScriptModule, &.{
        .{ .path = npm_entry, .source = "export default 1;\n", .package_root = npm_root },
        .{ .path = nako_entry, .source = "export default {};\n", .package_root = nako_root },
        .{ .path = "/not/bundled/root.mjs", .source = "export default 0;\n" },
    });

    try collect(allocator, io, &program);
    try std.testing.expectEqual(@as(usize, 2), program.bundled_packages.len);
    const npm_package = program.bundled_packages[0];
    try std.testing.expectEqualStrings("left-pad", npm_package.name);
    try std.testing.expectEqualStrings("1.0.0", npm_package.version);
    try std.testing.expectEqualStrings("MIT", npm_package.license);
    try std.testing.expectEqual(lnako.ir.nako_ir.BundledPackageKind.npm, npm_package.kind);
    try std.testing.expectEqual(@as(usize, 1), npm_package.entries.len);
    try std.testing.expectEqualStrings("index.js", npm_package.entries[0]);
    const nako_package = program.bundled_packages[1];
    // v1 の package id は scope を落とさずそのまま記録する。
    try std.testing.expectEqualStrings("@example/leftpad", nako_package.name);
    try std.testing.expectEqualStrings("1.2.3", nako_package.version);
    try std.testing.expectEqual(lnako.ir.nako_ir.BundledPackageKind.nako, nako_package.kind);
    try std.testing.expectEqualStrings("plugin.mjs", nako_package.entries[0]);
}

test "license宣言の無い同梱packageはNOASSERTIONとして記録する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "npm_nolicense");
    try temporary.dir.writeFile(io, .{
        .sub_path = "npm_nolicense/package.json",
        .data = "{\"name\":\"nolicense\",\"version\":\"2.0.0\"}",
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "npm_nolicense/index.js", .data = "export default 2;\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "npm_nolicense" });
    defer allocator.free(package_root);
    const entry = try std.fs.path.join(allocator, &.{ package_root, "index.js" });
    defer allocator.free(entry);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.javascript_modules = try program.arena.allocator().dupe(lnako.ir.nako_ir.JavaScriptModule, &.{
        .{ .path = entry, .source = "export default 2;\n", .package_root = package_root },
    });

    try collect(allocator, io, &program);
    try std.testing.expectEqual(@as(usize, 1), program.bundled_packages.len);
    try std.testing.expectEqualStrings(unknown_license, program.bundled_packages[0].license);
}

test "metadataの無いpackage rootは同梱物から黙って落とさない" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "orphan");
    try temporary.dir.writeFile(io, .{ .sub_path = "orphan/index.js", .data = "export default 3;\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "orphan" });
    defer allocator.free(package_root);
    const entry = try std.fs.path.join(allocator, &.{ package_root, "index.js" });
    defer allocator.free(entry);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.javascript_modules = try program.arena.allocator().dupe(lnako.ir.nako_ir.JavaScriptModule, &.{
        .{ .path = entry, .source = "export default 3;\n", .package_root = package_root },
    });

    try std.testing.expectError(error.MissingBundledPackageMetadata, collect(allocator, io, &program));
}

test "relativeEntryは共通prefixの兄弟directoryを誤帰属させない" {
    const allocator = std.testing.allocator;
    const root = try platformPath(allocator, "/pkg/leftpad");
    defer allocator.free(root);
    const inside = try platformPath(allocator, "/pkg/leftpad/index.js");
    defer allocator.free(inside);
    const sibling = try platformPath(allocator, "/pkg/leftpad2/index.js");
    defer allocator.free(sibling);
    const trailing = try platformPath(allocator, "/pkg/leftpad/");
    defer allocator.free(trailing);
    try std.testing.expectEqualStrings("index.js", relativeEntry(root, inside).?);
    // `leftpad2` は `leftpad` の配下ではない（区切り境界を要求する）。
    try std.testing.expect(relativeEntry(root, sibling) == null);
    try std.testing.expect(relativeEntry(root, root) == null);
    try std.testing.expect(relativeEntry(trailing, inside) == null);
}

test "依存の出自がnpmならpackage.jsonだけを読む" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "both");
    try temporary.dir.writeFile(io, .{
        .sub_path = "both/package.json",
        .data = "{\"name\":\"npm-name\",\"version\":\"9.9.9\",\"license\":\"ISC\"}",
    });
    // v1 metadata が同居していても、npm 由来の package は package.json を読む
    // （既存の npm 経路を変えない）。
    const v1_text = try v1UniversalMetadata(allocator, "@example/nako-name", "1.0.0", "MIT", "index.js");
    defer allocator.free(v1_text);
    try writeV1Metadata(&temporary, io, "both", v1_text);
    try temporary.dir.writeFile(io, .{ .sub_path = "both/index.js", .data = "export default 1;\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "both" });
    defer allocator.free(package_root);
    const entry = try std.fs.path.join(allocator, &.{ package_root, "index.js" });
    defer allocator.free(entry);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    const attributions = try program.arena.allocator().alloc(lnako.ir.nako_ir.PackageAttribution, 1);
    attributions[0] = .{ .root = package_root, .npm = true };
    program.javascript_modules = try program.arena.allocator().dupe(lnako.ir.nako_ir.JavaScriptModule, &.{
        .{ .path = entry, .source = "export default 1;\n", .package_root = package_root, .package_attributions = attributions },
    });

    try collect(allocator, io, &program);
    try std.testing.expectEqual(lnako.ir.nako_ir.BundledPackageKind.npm, program.bundled_packages[0].kind);
    try std.testing.expectEqualStrings("npm-name", program.bundled_packages[0].name);
    try std.testing.expectEqualStrings("ISC", program.bundled_packages[0].license);
}

test "依存の出自がpathならpackage.jsonがあってもv1正本METADATA.tomlを読む" {
    // path 依存に開発用 package.json があっても、npm の name/version/license を
    // 同梱物の帰属として記録しない（CodeRabbit Major/Minor 回帰）。旧
    // nako.toml が同居していても v1 の正本を優先する。
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "plugin");
    try temporary.dir.writeFile(io, .{
        .sub_path = "plugin/package.json",
        .data = "{\"name\":\"dev-tooling\",\"version\":\"9.9.9\",\"license\":\"GPL-3.0\"}",
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "plugin/nako.toml",
        .data = "[package]\nname = \"legacy-name\"\nversion = \"0.0.1\"\nlicense = \"GPL-3.0\"\n",
    });
    const v1_text = try v1UniversalMetadata(allocator, "@example/leftpad", "1.0.0", "MIT", "plugin.mjs");
    defer allocator.free(v1_text);
    try writeV1Metadata(&temporary, io, "plugin", v1_text);
    try temporary.dir.writeFile(io, .{ .sub_path = "plugin/plugin.mjs", .data = "export default {};\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "plugin" });
    defer allocator.free(package_root);
    const entry = try std.fs.path.join(allocator, &.{ package_root, "plugin.mjs" });
    defer allocator.free(entry);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    const attributions = try program.arena.allocator().alloc(lnako.ir.nako_ir.PackageAttribution, 1);
    attributions[0] = .{ .root = package_root, .npm = false };
    program.javascript_modules = try program.arena.allocator().dupe(lnako.ir.nako_ir.JavaScriptModule, &.{
        .{ .path = entry, .source = "export default {};\n", .package_root = package_root, .package_attributions = attributions },
    });

    try collect(allocator, io, &program);
    try std.testing.expectEqual(@as(usize, 1), program.bundled_packages.len);
    try std.testing.expectEqual(lnako.ir.nako_ir.BundledPackageKind.nako, program.bundled_packages[0].kind);
    try std.testing.expectEqualStrings("@example/leftpad", program.bundled_packages[0].name);
    try std.testing.expectEqualStrings("1.0.0", program.bundled_packages[0].version);
    try std.testing.expectEqualStrings("MIT", program.bundled_packages[0].license);
}

test "同じmoduleを共有する全package rootを収集する" {
    // 入れ子の package が同一 ESM file を export しても、代表 root だけで
    // 打ち切らず全帰属を manifest/SBOM へ載せる（CodeRabbit Minor 回帰）。
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "outer");
    try temporary.dir.createDirPath(io, "outer/vendor/inner");
    const outer_text = try v1UniversalMetadata(allocator, "@example/outer", "1.0.0", "MIT", "shared.mjs");
    defer allocator.free(outer_text);
    try writeV1Metadata(&temporary, io, "outer", outer_text);
    const inner_text = try v1UniversalMetadata(allocator, "@example/inner", "2.0.0", "Apache-2.0", "shared.mjs");
    defer allocator.free(inner_text);
    try writeV1Metadata(&temporary, io, "outer/vendor/inner", inner_text);
    try temporary.dir.writeFile(io, .{ .sub_path = "outer/shared.mjs", .data = "export default 1;\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const outer_root = try std.fs.path.join(allocator, &.{ root, "outer" });
    defer allocator.free(outer_root);
    const inner_root = try std.fs.path.join(allocator, &.{ outer_root, "vendor", "inner" });
    defer allocator.free(inner_root);
    const shared = try std.fs.path.join(allocator, &.{ outer_root, "shared.mjs" });
    defer allocator.free(shared);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    const attributions = try program.arena.allocator().alloc(lnako.ir.nako_ir.PackageAttribution, 2);
    attributions[0] = .{ .root = outer_root, .npm = false };
    attributions[1] = .{ .root = inner_root, .npm = false };
    program.javascript_modules = try program.arena.allocator().dupe(lnako.ir.nako_ir.JavaScriptModule, &.{
        .{ .path = shared, .source = "export default 1;\n", .package_root = outer_root, .package_attributions = attributions },
    });

    try collect(allocator, io, &program);
    try std.testing.expectEqual(@as(usize, 2), program.bundled_packages.len);
    // 登録順は module の attribution 順（outer → inner）。両方が揃うことを固定。
    try std.testing.expectEqualStrings("@example/outer", program.bundled_packages[0].name);
    try std.testing.expectEqualStrings("@example/inner", program.bundled_packages[1].name);
}

test "旧nako.tomlだけのpackage rootはv1同梱metadataとして扱わない" {
    // 旧 manifest は v1 の package root には存在しない。読み替えて同梱を
    // 復活させず、metadata 不在として fail-closed にする。
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "legacy");
    try temporary.dir.writeFile(io, .{
        .sub_path = "legacy/nako.toml",
        .data = "[package]\nname = \"legacy\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n",
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "legacy/plugin.mjs", .data = "export default {};\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "legacy" });
    defer allocator.free(package_root);
    const entry = try std.fs.path.join(allocator, &.{ package_root, "plugin.mjs" });
    defer allocator.free(entry);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.javascript_modules = try program.arena.allocator().dupe(lnako.ir.nako_ir.JavaScriptModule, &.{
        .{ .path = entry, .source = "export default {};\n", .package_root = package_root },
    });

    try std.testing.expectError(error.MissingBundledPackageMetadata, collect(allocator, io, &program));
}

test "旧schemaVersionのMETADATA.tomlはv1正本として読み替えない" {
    // v1 の正本は snake_case の `schema_version = 1`。旧配布物の
    // `schemaVersion` 形式を受理して旧経路を復活させない。
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try writeV1Metadata(&temporary, io, "old",
        \\schemaVersion = 1
        \\
        \\[package]
        \\name = "old"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
    );
    try temporary.dir.writeFile(io, .{ .sub_path = "old/plugin.mjs", .data = "export default {};\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "old" });
    defer allocator.free(package_root);
    const entry = try std.fs.path.join(allocator, &.{ package_root, "plugin.mjs" });
    defer allocator.free(entry);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.javascript_modules = try program.arena.allocator().dupe(lnako.ir.nako_ir.JavaScriptModule, &.{
        .{ .path = entry, .source = "export default {};\n", .package_root = package_root },
    });

    try std.testing.expectError(error.InvalidBundledPackageMetadata, collect(allocator, io, &program));
}

test "bundle-depsはv1 source/native rootを認識しproject境界を越えない" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    // project 自身は v1 local `nako.toml` を持つ。これは package root の
    // 目印ではないため、project 配下のローカル module は同梱対象外。
    try temporary.dir.createDirPath(io, "app/src");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data = "schema_version = 1\n[package]\nid = \"@app/main\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n",
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/src/local.nako3", .data = "1を表示\n" });
    const generation = "app/.nako/v1/generations/gen-test/packages";
    const source_package = generation ++ "/source";
    const native_package = generation ++ "/native";
    const source_text = try v1UniversalMetadata(allocator, "@example/source", "2.1.0", "Apache-2.0", "src/main.nako3");
    defer allocator.free(source_text);
    try writeV1Metadata(&temporary, io, source_package, source_text);
    try writeV1Metadata(&temporary, io, native_package,
        \\schema_version = 1
        \\
        \\[package]
        \\id = "@example/native"
        \\version = "0.3.0"
        \\license = "MIT"
        \\
        \\[artifact]
        \\kind = "native-source"
        \\runtimes = ["lnako"]
        \\
        \\[artifact.native]
        \\abi_version = 1
        \\
        \\[exports]
        \\"." = { entry = "lib/plugin.so" }
        \\
    );
    try temporary.dir.createDirPath(io, source_package ++ "/src");
    try temporary.dir.writeFile(io, .{ .sub_path = source_package ++ "/src/main.nako3", .data = "1を表示\n" });
    try temporary.dir.createDirPath(io, native_package ++ "/lib");
    try temporary.dir.writeFile(io, .{ .sub_path = native_package ++ "/lib/plugin.so", .data = "native" });

    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const project_root = try std.fs.path.join(allocator, &.{ root, "app" });
    defer allocator.free(project_root);
    const source_root = try std.fs.path.join(allocator, &.{ root, "app", ".nako", "v1", "generations", "gen-test", "packages", "source" });
    defer allocator.free(source_root);
    const native_root = try std.fs.path.join(allocator, &.{ root, "app", ".nako", "v1", "generations", "gen-test", "packages", "native" });
    defer allocator.free(native_root);
    const source_module = try std.fs.path.join(allocator, &.{ source_root, "src", "main.nako3" });
    defer allocator.free(source_module);
    const native_module = try std.fs.path.join(allocator, &.{ native_root, "lib", "plugin.so" });
    defer allocator.free(native_module);
    const local_module = try std.fs.path.join(allocator, &.{ project_root, "src", "local.nako3" });
    defer allocator.free(local_module);

    const previous = bundle_deps_enabled;
    bundle_deps_enabled = true;
    defer bundle_deps_enabled = previous;

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    const arena = program.arena.allocator();
    program.module_paths = try arena.dupe([]const u8, &.{ source_module, local_module });
    program.native_plugin_paths = try arena.dupe([]const u8, &.{native_module});

    try collectForProject(allocator, io, &program, project_root);
    try std.testing.expectEqual(@as(usize, 2), program.bundled_packages.len);
    const source_package_result = program.bundled_packages[0];
    try std.testing.expectEqualStrings("@example/source", source_package_result.name);
    try std.testing.expectEqualStrings("2.1.0", source_package_result.version);
    try std.testing.expectEqualStrings("Apache-2.0", source_package_result.license);
    try std.testing.expectEqual(lnako.ir.nako_ir.BundledPackageKind.nako, source_package_result.kind);
    try std.testing.expectEqual(@as(usize, 1), source_package_result.entries.len);
    try std.testing.expectEqualStrings("src/main.nako3", source_package_result.entries[0]);
    const native_package_result = program.bundled_packages[1];
    try std.testing.expectEqualStrings("@example/native", native_package_result.name);
    try std.testing.expectEqual(@as(usize, 1), native_package_result.entries.len);
    try std.testing.expectEqualStrings("lib/plugin.so", native_package_result.entries[0]);
    // project 自身のローカル module は境界で除外される。
    for (program.bundled_packages) |package| {
        for (package.entries) |entry| {
            try std.testing.expect(!std.mem.eql(u8, entry, "src/local.nako3"));
        }
    }
}

test "旧形式licenses配列の全選択肢をOR式として保持する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "npm_legacy");
    try temporary.dir.writeFile(io, .{
        .sub_path = "npm_legacy/package.json",
        .data = "{\"name\":\"legacy\",\"version\":\"1.0.0\",\"licenses\":[\"MIT\",{\"type\":\"Apache-2.0\"}]}",
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "npm_legacy/index.js", .data = "export default 1;\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "npm_legacy" });
    defer allocator.free(package_root);
    const entry = try std.fs.path.join(allocator, &.{ package_root, "index.js" });
    defer allocator.free(entry);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    const attributions = try program.arena.allocator().alloc(lnako.ir.nako_ir.PackageAttribution, 1);
    attributions[0] = .{ .root = package_root, .npm = true };
    program.javascript_modules = try program.arena.allocator().dupe(lnako.ir.nako_ir.JavaScriptModule, &.{
        .{ .path = entry, .source = "export default 1;\n", .package_root = package_root, .package_attributions = attributions },
    });

    try collect(allocator, io, &program);
    try std.testing.expectEqualStrings("MIT OR Apache-2.0", program.bundled_packages[0].license);
}

test "壊れたpackage.jsonは黙ってNOASSERTIONにせず失敗する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "broken");
    try temporary.dir.writeFile(io, .{ .sub_path = "broken/package.json", .data = "{not json" });
    try temporary.dir.writeFile(io, .{ .sub_path = "broken/index.js", .data = "export default 1;\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "broken" });
    defer allocator.free(package_root);
    const entry = try std.fs.path.join(allocator, &.{ package_root, "index.js" });
    defer allocator.free(entry);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.javascript_modules = try program.arena.allocator().dupe(lnako.ir.nako_ir.JavaScriptModule, &.{
        .{ .path = entry, .source = "export default 1;\n", .package_root = package_root },
    });

    try std.testing.expectError(error.InvalidBundledPackageJson, collect(allocator, io, &program));
}

test "同一rootのentryは重複を除いて昇順にそろえる" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "pkg/lib");
    try temporary.dir.writeFile(io, .{
        .sub_path = "pkg/package.json",
        .data = "{\"name\":\"pkg\",\"version\":\"1.0.0\",\"license\":\"MIT\"}",
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/z.js", .data = "export default 1;\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "pkg/lib/a.js", .data = "export default 2;\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "pkg" });
    defer allocator.free(package_root);
    const z_entry = try std.fs.path.join(allocator, &.{ package_root, "z.js" });
    defer allocator.free(z_entry);
    const a_entry = try std.fs.path.join(allocator, &.{ package_root, "lib", "a.js" });
    defer allocator.free(a_entry);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.javascript_modules = try program.arena.allocator().dupe(lnako.ir.nako_ir.JavaScriptModule, &.{
        .{ .path = z_entry, .source = "export default 1;\n", .package_root = package_root },
        .{ .path = a_entry, .source = "export default 2;\n", .package_root = package_root },
        .{ .path = z_entry, .source = "export default 1;\n", .package_root = package_root },
    });

    try collect(allocator, io, &program);
    try std.testing.expectEqual(@as(usize, 1), program.bundled_packages.len);
    try std.testing.expectEqual(@as(usize, 2), program.bundled_packages[0].entries.len);
    try std.testing.expectEqualStrings("lib/a.js", program.bundled_packages[0].entries[0]);
    try std.testing.expectEqualStrings("z.js", program.bundled_packages[0].entries[1]);
}

test "entryの区切りはplatform非依存に正規化する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("lib/a.js", try normalizedEntry(allocator, "lib/a.js"));
    if (std.fs.path.sep == '\\') {
        // Windows の module path から来た entry も `/` へ揃える。
        try std.testing.expectEqualStrings("lib/a.js", try normalizedEntry(allocator, "lib\\a.js"));
    } else {
        // POSIX の `\\` はファイル名の文字なので変換しない。
        try std.testing.expectEqualStrings("lib\\a.js", try normalizedEntry(allocator, "lib\\a.js"));
    }
    try std.testing.expectEqualStrings("index.js", try normalizedEntry(allocator, "index.js"));
}

/// テスト用: `/` 区切りの文字列を実行 platform の区切りへ変換する。
fn platformPath(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const path = try allocator.dupe(u8, text);
    if (std.fs.path.sep == '\\') for (path) |*byte| {
        if (byte.* == '/') byte.* = '\\';
    };
    return path;
}
