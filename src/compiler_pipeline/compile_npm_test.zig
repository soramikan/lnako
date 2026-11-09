//! compile 経路で package 所有 ESM の bare npm import が lock/cache から
//! 解決されることの統合テスト（#54 の配線）。
//!
//! fixture は実 lock（`ensureLock`）と実 cache（tarball の publish）を作り、
//! network・Node・npm CLI を使わずに `compileInput` へ通す。

const std = @import("std");
const lnako = @import("lnako");
const compile_pipeline = @import("compile.zig");
const embedded_pipeline = @import("embedded.zig");
const compat_embedded = lnako.compat.embedded;

const npm_mod = lnako.package.npm;
const project_mod = lnako.package.project;
const sync_mod = lnako.package.sync;
const diag = lnako.package.diagnostics;
const npm_env = lnako.package.npm_env;
const npm_resolver = lnako.package.npm_resolver;
const test_sandbox = lnako.package.test_sandbox;

const testing = std.testing;

const TarFile = struct { path: []const u8, content: []const u8 };

const left_pad_tarball_files = [_]TarFile{
    .{ .path = "package/package.json", .content = "{\"name\":\"left-pad\",\"version\":\"1.0.0\",\"exports\":{\".\":\"./index.js\",\"./sub\":\"./sub.js\"}}" },
    .{ .path = "package/index.js", .content = "export default 'left-pad-index';\n" },
    .{ .path = "package/sub.js", .content = "export default 'left-pad-sub';\n" },
};

fn writeProject(temporary: *std.testing.TmpDir, io: std.Io) !void {
    // package 所有 ESM。bare npm の root 入口と exports サブパスを import する。
    try writeProjectWithNpm(temporary, io, "left-pad = \"^1.0.0\"",
        \\import pad from "left-pad";
        \\import sub from "left-pad/sub";
        \\export default { "meta": { "type": "const", "value": pad + sub } };
        \\
    );
}

/// `writeProject` の npm 依存行と plugin.mjs を差し替える版（#53 の
/// package.json 本格パース回帰テスト用）。
fn writeProjectWithNpm(
    temporary: *std.testing.TmpDir,
    io: std.Io,
    npm_dependency_line: []const u8,
    plugin_source: []const u8,
) !void {
    try temporary.dir.createDirPath(io, "app/esm");
    const manifest = try std.fmt.allocPrint(
        testing.allocator,
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\esm = {{ path = "esm" }}
        \\
        \\[dependencies.npm]
        \\{s}
        \\
    ,
        .{npm_dependency_line},
    );
    defer testing.allocator.free(manifest);
    try temporary.dir.writeFile(io, .{ .sub_path = "app/nako.toml", .data = manifest });
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/esm/nako.toml",
        .data =
        \\[package]
        \\name = "esm"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "main"
        \\esm = "plugin.mjs"
        \\
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/esm/plugin.mjs", .data = plugin_source });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/main.nako3", .data = "!「pkg:esm」を取り込む\n" });
}

/// 実 catalog から lock を作り cache を埋め、sync で `.nako/environment.json`
/// を公開する。compile は lock + cache だけを読む。
/// fixture の npm package（tarball 内容と identity）。
const TestPackage = struct {
    name: []const u8,
    version: []const u8,
    files: []const TarFile,
};

fn prepareLockAndCache(
    gpa: std.mem.Allocator,
    io: std.Io,
    app_root: []const u8,
    cache_root: []const u8,
) !void {
    return prepareLockAndCacheFor(gpa, io, app_root, cache_root, .{
        .name = "left-pad",
        .version = "1.0.0",
        .files = &left_pad_tarball_files,
    });
}

fn prepareLockAndCacheFor(
    gpa: std.mem.Allocator,
    io: std.Io,
    app_root: []const u8,
    cache_root: []const u8,
    package: TestPackage,
) !void {
    const body = try buildTarGz(gpa, package.files);
    defer gpa.free(body);
    const integrity = try npm_mod.integritySha512(gpa, body);
    defer gpa.free(integrity);
    const tarball_url = try std.fmt.allocPrint(gpa, "fixture://{s}-{s}.tgz", .{ package.name, package.version });
    defer gpa.free(tarball_url);

    var catalog: npm_mod.Catalog = .{};
    defer catalog.deinit(gpa);
    const versions = try gpa.alloc(npm_mod.VersionMeta, 1);
    defer gpa.free(versions);
    versions[0] = .{
        .version = package.version,
        .tarball_url = tarball_url,
        .integrity = integrity,
        .tarball_bytes = body,
    };
    try catalog.put(gpa, .{ .name = package.name, .versions = versions });

    var diagnostics = diag.List.init(gpa);
    defer diagnostics.deinit();
    var loaded = try project_mod.load(gpa, io, app_root, &diagnostics);
    defer loaded.deinit();
    var outcome = try project_mod.ensureLock(gpa, io, &loaded, &.{
        .cache_root = cache_root,
        .npm_catalog = &catalog,
        .compat_js = true,
    }, &diagnostics);
    defer outcome.deinit();
    try testing.expect(outcome.wrote);

    var synced = diag.List.init(gpa);
    defer synced.deinit();
    var report = try sync_mod.run(gpa, io, .{ .project_root = app_root, .cache_root = cache_root }, &synced);
    defer report.deinit();
    try testing.expect(!synced.hasErrors());
}

fn compileMain(gpa: std.mem.Allocator, io: std.Io, app_root: []const u8, cache_root: []const u8, stderr: *std.Io.Writer.Allocating) !?lnako.ir.nako_ir.Program {
    const main_path = try std.fs.path.join(gpa, &.{ app_root, "main.nako3" });
    defer gpa.free(main_path);
    return compile_pipeline.compileInput(gpa, io, main_path, .{
        .compat_js = true,
        .package_cache_root = cache_root,
    }, &stderr.writer);
}

test "compile は package 所有 ESM の bare npm import（サブパス含む）を lock/cache から解決する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);

    try writeProject(&temporary, io);
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", gpa);
    defer gpa.free(app_root);
    try prepareLockAndCache(gpa, io, app_root, cache_root);

    var stderr: std.Io.Writer.Allocating = .init(gpa);
    defer stderr.deinit();
    const program = (try compileMain(gpa, io, app_root, cache_root, &stderr)) orelse return error.UnexpectedCompileFailure;
    var compiled = program;
    defer compiled.deinit();

    var plugin_found = false;
    var root_found = false;
    var sub_found = false;
    for (compiled.javascript_modules) |module| {
        if (std.mem.endsWith(u8, module.path, "plugin.mjs")) {
            plugin_found = true;
            try testing.expect(module.is_plugin);
            try testing.expect(module.package_root != null);
            continue;
        }
        if (std.mem.endsWith(u8, module.path, "index.js")) {
            root_found = true;
            try testing.expect(std.mem.indexOf(u8, module.source, "left-pad-index") != null);
            // npm library は plugin ではなく package_root 所有。
            try testing.expect(!module.is_plugin);
            try testing.expect(module.package_root != null);
            continue;
        }
        if (std.mem.endsWith(u8, module.path, "sub.js")) {
            sub_found = true;
            try testing.expect(std.mem.indexOf(u8, module.source, "left-pad-sub") != null);
            try testing.expect(module.package_root != null);
        }
    }
    try testing.expect(plugin_found);
    try testing.expect(root_found);
    try testing.expect(sub_found);
}

test "build --compat-js の payload は npm import を起動時 compile へ復元する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);

    try writeProject(&temporary, io);
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", gpa);
    defer gpa.free(app_root);
    try prepareLockAndCache(gpa, io, app_root, cache_root);

    const main_path = try std.fs.path.join(gpa, &.{ app_root, "main.nako3" });
    defer gpa.free(main_path);
    const stub_path = try std.fs.path.join(gpa, &.{ app_root, "lnako-stub" });
    defer gpa.free(stub_path);
    const output_path = try std.fs.path.join(gpa, &.{ app_root, "out.bin" });
    defer gpa.free(output_path);
    try temporary.dir.writeFile(io, .{ .sub_path = "app/lnako-stub", .data = "EXE" });

    try embedded_pipeline.writeCompatExecutable(gpa, io, stub_path, main_path, output_path, .{}, cache_root);

    var package = (try compat_embedded.readExecutable(gpa, io, output_path)) orelse return error.UnexpectedEmbeddedPayload;
    defer package.deinit();
    // plugin.mjs の bare left-pad / left-pad/sub だけが payload に記録される
    //（nako3 の取り込み edge を npm binding として混入させない）。
    try testing.expectEqual(@as(usize, 2), package.npm_imports.len);

    // cache を消してから起動時 compile を通し、payload だけで復元できることを
    // 固定する（復元経路が cache を参照したら失敗する）。
    try temporary.dir.deleteTree(io, "cache");

    // 起動時と同じ provider + resolver で再コンパイルできる（cache/FS なし）。
    var stderr: std.Io.Writer.Allocating = .init(gpa);
    defer stderr.deinit();
    const program = (try compile_pipeline.compileInputWithProvider(gpa, package.entry_path, .{
        .compat_js = true,
        .forced_mode = package.forced_mode,
        .package_resolver = package.packageResolver(),
        .npm_module_resolver = package.npmModuleResolver(),
    }, &stderr.writer, package.sourceProvider())) orelse return error.UnexpectedCompileFailure;
    var compiled = program;
    defer compiled.deinit();

    var root_found = false;
    var sub_found = false;
    for (compiled.javascript_modules) |module| {
        if (std.mem.endsWith(u8, module.path, "index.js")) root_found = true;
        if (std.mem.endsWith(u8, module.path, "sub.js")) sub_found = true;
    }
    try testing.expect(root_found);
    try testing.expect(sub_found);
}

/// cache の `source.archive` を全て壊す。世代 tree が有効なら compile は
/// cache を読まずに成功するはず（再検証・再展開の回避を観測する）。
fn tamperCacheArchives(cache_root: []const u8, io: std.Io) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, cache_root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, "source.archive")) continue;
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ cache_root, entry.path });
        defer testing.allocator.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "tampered-archive" });
        count += 1;
    }
    return count;
}

/// `app/.nako/env/<gen>/deps/npm_*`（sync が materialize した npm tree）の
/// 一時 dir 相対 path を集める（テストの fallback 経路の再現に使う）。
fn collectNpmTreePaths(
    temporary: *std.testing.TmpDir,
    io: std.Io,
    paths: *std.ArrayListUnmanaged([]u8),
) !void {
    var env = try temporary.dir.openDir(io, "app/.nako/env", .{ .iterate = true });
    defer env.close(io);
    var generations = env.iterate();
    while (try generations.next(io)) |generation| {
        if (generation.kind != .directory) continue;
        var generation_dir = env.openDir(io, generation.name, .{ .iterate = true }) catch continue;
        defer generation_dir.close(io);
        var deps = generation_dir.openDir(io, "deps", .{ .iterate = true }) catch continue;
        defer deps.close(io);
        var entries = deps.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (!std.mem.startsWith(u8, entry.name, npm_env.dir_prefix)) continue;
            try paths.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "app/.nako/env/{s}/deps/{s}", .{ generation.name, entry.name }));
        }
    }
}

fn freeNpmTreePaths(paths: *std.ArrayListUnmanaged([]u8)) void {
    for (paths.items) |path| testing.allocator.free(path);
    paths.deinit(testing.allocator);
}

/// `app/.nako/env/gen-*` の現行世代 dir 名を返す（1 件のみ想定）。
fn currentGenerationName(temporary: *std.testing.TmpDir, io: std.Io) ![]u8 {
    var env = try temporary.dir.openDir(io, "app/.nako/env", .{ .iterate = true });
    defer env.close(io);
    var iterator = env.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        return try testing.allocator.dupe(u8, entry.name);
    }
    return error.TestUnexpectedResult;
}

/// 公開済み世代 dir の canonical path（世代 tree の帰属判定に使う）。
fn generationDirReal(temporary: *std.testing.TmpDir, io: std.Io, gpa: std.mem.Allocator) ![:0]u8 {
    const generation = try currentGenerationName(temporary, io);
    defer testing.allocator.free(generation);
    const path = try std.fmt.allocPrint(gpa, "app/.nako/env/{s}", .{generation});
    defer gpa.free(path);
    return temporary.dir.realPathFileAlloc(io, path, gpa);
}

/// 世代 tree だけを除去する（cache には lock sha256 と一致する tarball が残る）。
fn removeNpmInstanceTrees(temporary: *std.testing.TmpDir, io: std.Io) !void {
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer freeNpmTreePaths(&paths);
    try collectNpmTreePaths(temporary, io, &paths);
    try testing.expect(paths.items.len > 0);
    for (paths.items) |path| try temporary.dir.deleteTree(io, path);
}

/// 世代 tree の provenance marker を `text` で上書きする（古い/不一致 tree の
/// 再現）。
fn rewriteNpmProvenance(temporary: *std.testing.TmpDir, io: std.Io, text: []const u8) !void {
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer freeNpmTreePaths(&paths);
    try collectNpmTreePaths(temporary, io, &paths);
    try testing.expect(paths.items.len > 0);
    for (paths.items) |path| {
        const marker_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, npm_env.provenance_file });
        defer testing.allocator.free(marker_path);
        try temporary.dir.writeFile(io, .{ .sub_path = marker_path, .data = text });
    }
}

/// scratch ではなく世代 `.nako/env/<gen>/deps/npm_*` の tree から解決したことを
/// 観測する。
fn assertNpmModulesFromGeneration(compiled: *const lnako.ir.nako_ir.Program, generation_root: []const u8) !void {
    var root_found = false;
    var sub_found = false;
    for (compiled.javascript_modules) |module| {
        // scratch（TMPDIR）ではなく公開済み世代 dir 配下の tree を指す。
        const from_generation = std.mem.startsWith(u8, module.path, generation_root) and
            std.mem.indexOf(u8, module.path, "npm_") != null;
        if (std.mem.endsWith(u8, module.path, "index.js")) {
            root_found = true;
            try testing.expect(from_generation);
        }
        if (std.mem.endsWith(u8, module.path, "sub.js")) {
            sub_found = true;
            try testing.expect(from_generation);
        }
    }
    try testing.expect(root_found);
    try testing.expect(sub_found);
}

/// `path` が scratch（`<scratch base>/lnako-npm-<16hex>/<cache key>/...`）配下
/// か。`.nako` 等の部分文字列ではなく、基点との path 境界と直下 component で
/// 判定する（`TMPDIR=/tmp/.nako-tests` のような基点名に `.nako` が含まれても
/// 誤判定しない）。
fn isScratchModulePath(scratch_base: []const u8, path: []const u8) bool {
    if (!npm_env.isStrictlyWithin(scratch_base, path)) return false;
    const relative = path[scratch_base.len + 1 ..];
    // Windows の realpath は `/`・`\` のどちらも返し得るため、単一 separator
    // ではなく `isSep` で最初の境界を探す（isStrictlyWithin と同じ規則）。
    const root_end = for (relative, 0..) |byte, index| {
        if (std.fs.path.isSep(byte)) break index;
    } else relative.len;
    const root_name = relative[0..root_end];
    if (!std.mem.startsWith(u8, root_name, npm_resolver.scratch_dir_prefix)) return false;
    // scratch dir 名は `<prefix><16 hex>`。prefix だけの同名 dir と区別する。
    const suffix = root_name[npm_resolver.scratch_dir_prefix.len..];
    if (suffix.len != npm_resolver.scratch_dir_hex_len) return false;
    for (suffix) |byte| {
        // 生成側は小文字 hex（bytesToHex(..., .lower)）なので大文字は認めない。
        if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

/// cache→scratch 経路（世代 tree を読まない）で解決したことを観測する。
/// scratch 基点は `npm_resolver` と同じ規則で canonical 化し、path 境界で
/// 所属を検証する（テスト専用の観測。機能の挙動は変えない）。
fn assertNpmModulesFromScratch(
    gpa: std.mem.Allocator,
    io: std.Io,
    compiled: *const lnako.ir.nako_ir.Program,
) !void {
    const scratch_base = (try npm_resolver.scratchBaseReal(gpa, io)) orelse return error.TestUnexpectedResult;
    defer gpa.free(scratch_base);
    var root_found = false;
    var sub_found = false;
    for (compiled.javascript_modules) |module| {
        if (std.mem.endsWith(u8, module.path, "index.js")) {
            root_found = true;
            try testing.expect(isScratchModulePath(scratch_base, module.path));
        }
        if (std.mem.endsWith(u8, module.path, "sub.js")) {
            sub_found = true;
            try testing.expect(isScratchModulePath(scratch_base, module.path));
        }
    }
    try testing.expect(root_found);
    try testing.expect(sub_found);
}

test "scratch 所属判定は path 境界を使い基点名の `.nako` 部分文字列に依存しない" {
    const gpa = testing.allocator;
    // TMPDIR が `/tmp/.nako-tests` のような実 dir を指す状況を再現する。
    const base = try std.fs.path.join(gpa, &.{ "tmp", ".nako-tests" });
    defer gpa.free(base);
    const sibling = try std.fmt.allocPrint(gpa, "{s}-other", .{base});
    defer gpa.free(sibling);

    const scratch_module = try std.fs.path.join(gpa, &.{ base, "lnako-npm-0123456789abcdef", "cachekey", "index.js" });
    defer gpa.free(scratch_module);
    try testing.expect(isScratchModulePath(base, scratch_module));

    // 基点名を prefix に持つだけの隣接 dir は境界外。
    const prefix_sibling = try std.fs.path.join(gpa, &.{ sibling, "lnako-npm-0123456789abcdef", "cachekey", "index.js" });
    defer gpa.free(prefix_sibling);
    try testing.expect(!isScratchModulePath(base, prefix_sibling));

    // `.nako` を含む世代 tree は scratch ではない。
    const generation_module = try std.fs.path.join(gpa, &.{ base, "app", ".nako", "env", "gen-1", "deps", "npm_x", "index.js" });
    defer gpa.free(generation_module);
    try testing.expect(!isScratchModulePath(base, generation_module));

    // 基点直下でも `lnako-npm-` 以外は scratch ではない。
    const other_module = try std.fs.path.join(gpa, &.{ base, "other", "index.js" });
    defer gpa.free(other_module);
    try testing.expect(!isScratchModulePath(base, other_module));

    // `<prefix><16 hex>` 以外の同名 dir は scratch ではない。
    const fake_scratch = try std.fs.path.join(gpa, &.{ base, "lnako-npm-not-a-hex", "cachekey", "index.js" });
    defer gpa.free(fake_scratch);
    try testing.expect(!isScratchModulePath(base, fake_scratch));
}

test "compile は世代 npm tree を cache より優先し cache なしでも解決する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);

    try writeProject(&temporary, io);
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", gpa);
    defer gpa.free(app_root);
    try prepareLockAndCache(gpa, io, app_root, cache_root);
    const generation_root = try generationDirReal(&temporary, io, gpa);
    defer gpa.free(generation_root);

    // (1) cache に tarball がある状態でも世代 tree を優先する（scratch への
    // 再展開をしない）。path が世代 dir 配下であることで観測する。
    {
        var stderr: std.Io.Writer.Allocating = .init(gpa);
        defer stderr.deinit();
        const program = (try compileMain(gpa, io, app_root, cache_root, &stderr)) orelse return error.UnexpectedCompileFailure;
        var compiled = program;
        defer compiled.deinit();
        try assertNpmModulesFromGeneration(&compiled, generation_root);
    }
    // (2) cache の archive を壊しても、世代 tree を優先するため compile は
    // 成功し続ける（cache の再検証・再展開をしていない）。
    {
        try testing.expect(try tamperCacheArchives(cache_root, io) > 0);
        var stderr: std.Io.Writer.Allocating = .init(gpa);
        defer stderr.deinit();
        const program = (try compileMain(gpa, io, app_root, cache_root, &stderr)) orelse return error.UnexpectedCompileFailure;
        var compiled = program;
        defer compiled.deinit();
        try assertNpmModulesFromGeneration(&compiled, generation_root);
    }
    // (3) cache root の path 自体が存在しなくても、公開済み世代 tree だけで
    // offline に解決できる（cache Store を開いていない）。
    {
        const missing_cache_root = try std.fs.path.join(gpa, &.{ app_root, "missing-cache" });
        defer gpa.free(missing_cache_root);
        var stderr: std.Io.Writer.Allocating = .init(gpa);
        defer stderr.deinit();
        const program = (try compileMain(gpa, io, app_root, missing_cache_root, &stderr)) orelse return error.UnexpectedCompileFailure;
        var compiled = program;
        defer compiled.deinit();
        try assertNpmModulesFromGeneration(&compiled, generation_root);
        try testing.expectError(error.FileNotFound, temporary.dir.access(io, "app/missing-cache", .{}));
    }
}

test "compile は世代 npm tree が無ければ cache から再構築する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);

    try writeProject(&temporary, io);
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", gpa);
    defer gpa.free(app_root);
    try prepareLockAndCache(gpa, io, app_root, cache_root);
    try removeNpmInstanceTrees(&temporary, io);

    var stderr: std.Io.Writer.Allocating = .init(gpa);
    defer stderr.deinit();
    const program = (try compileMain(gpa, io, app_root, cache_root, &stderr)) orelse return error.UnexpectedCompileFailure;
    var compiled = program;
    defer compiled.deinit();
    // 世代 tree ではなく cache→scratch 経路で解決したことを観測する。
    try assertNpmModulesFromScratch(gpa, io, &compiled);
}

test "compile は世代 tree の provenance が lock と食い違えば cache から解決する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);

    try writeProject(&temporary, io);
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", gpa);
    defer gpa.free(app_root);
    try prepareLockAndCache(gpa, io, app_root, cache_root);
    // 世代 tree は残したまま marker だけ古い sha256 へ差し替える。
    try rewriteNpmProvenance(&temporary, io, "sha256:1111111111111111111111111111111111111111111111111111111111111111\n");

    var stderr: std.Io.Writer.Allocating = .init(gpa);
    defer stderr.deinit();
    const program = (try compileMain(gpa, io, app_root, cache_root, &stderr)) orelse return error.UnexpectedCompileFailure;
    var compiled = program;
    defer compiled.deinit();
    try assertNpmModulesFromScratch(gpa, io, &compiled);
}

test "compile は世代 npm tree も cache も無ければ fail-closed にする（network 取得をしない）" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    try temporary.dir.createDirPath(io, "empty-cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);
    const empty_cache_root = try temporary.dir.realPathFileAlloc(io, "empty-cache", gpa);
    defer gpa.free(empty_cache_root);

    try writeProject(&temporary, io);
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", gpa);
    defer gpa.free(app_root);
    try prepareLockAndCache(gpa, io, app_root, cache_root);
    try removeNpmInstanceTrees(&temporary, io);

    // lock と environment は有効なまま、世代 npm tree と cache の両方が無い。
    // bare import は module_graph の fail-closed 診断になり、compile は成功しない。
    // 診断は instance 単位（name/version/cache key を 1 行で示す）に更新
    // 済み（#54）。
    var stderr: std.Io.Writer.Allocating = .init(gpa);
    defer stderr.deinit();
    try testing.expect((try compileMain(gpa, io, app_root, empty_cache_root, &stderr)) == null);
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "npm instance left-pad@1.0.0") != null);
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "cache key:") != null);
}

test "compile は世代 dir が symlink なら世代 tree を使わず cache から解決する" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);
    try writeProject(&temporary, io);
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", gpa);
    defer gpa.free(app_root);
    try prepareLockAndCache(gpa, io, app_root, cache_root);

    // 公開済み世代 dir を project 内の別 dir へ移し、元 path を symlink にする。
    // 環境検証は realpath 追従で通るが、openGenerationDeps の各段 no-follow
    // open は世代 dir を開けないため世代 tree を使わない（cache へ fallback）。
    const generation = try currentGenerationName(&temporary, io);
    defer testing.allocator.free(generation);
    const gen_from = try std.fmt.allocPrint(gpa, "app/.nako/env/{s}", .{generation});
    defer gpa.free(gen_from);
    const env_sub = try std.fmt.allocPrint(gpa, "env/{s}", .{generation});
    defer gpa.free(env_sub);
    const env_real_sub = try std.fmt.allocPrint(gpa, "env-real/{s}", .{generation});
    defer gpa.free(env_real_sub);
    const link_target = try std.fmt.allocPrint(gpa, "../env-real/{s}", .{generation});
    defer gpa.free(link_target);
    try temporary.dir.createDirPath(io, "app/.nako/env-real");
    var nako_dir = try temporary.dir.openDir(io, "app/.nako", .{});
    defer nako_dir.close(io);
    try std.Io.Dir.rename(nako_dir, env_sub, nako_dir, env_real_sub, io);
    temporary.dir.symLink(io, link_target, gen_from, .{ .is_directory = true }) catch return error.SkipZigTest;

    var stderr: std.Io.Writer.Allocating = .init(gpa);
    defer stderr.deinit();
    const program = (try compileMain(gpa, io, app_root, cache_root, &stderr)) orelse return error.UnexpectedCompileFailure;
    var compiled = program;
    defer compiled.deinit();
    try assertNpmModulesFromScratch(gpa, io, &compiled);
}

// ---------------------------------------------------------------------------
// #53 package.json 本格パース: interpreter compile と AOT 埋め込み（起動時
// 再コンパイル）が同じ入口解決になることの回帰テスト。
// ---------------------------------------------------------------------------

/// Node 実測（24.21.0 / 26.13.0）に基づく package.json。`node` 条件は
/// 暗黙有効化しないため `import` が選ばれ、`default` / `node` / `main` は
/// 使われない。`*` サブパスと exact サブパスも含める。
const edge_package_files = [_]TarFile{
    .{ .path = "package/package.json", .content =
    \\{"name":"edge-pkg","version":"2.0.0","type":"module",
    \\ "main":"legacy/index.js",
    \\ "exports":{
    \\   ".":{"node":"./node/index.js","import":"./esm/index.js","default":"./cjs/index.js"},
    \\   "./feature/*":"./esm/feature/*.js",
    \\   "./exact":"./esm/exact.js"}}
    },
    .{ .path = "package/esm/index.js", .content = "export default 'edge-root';\n" },
    .{ .path = "package/esm/feature/a.js", .content = "export default 'edge-feature-a';\n" },
    .{ .path = "package/esm/exact.js", .content = "export default 'edge-exact';\n" },
    .{ .path = "package/cjs/index.js", .content = "export default 'edge-cjs';\n" },
    .{ .path = "package/node/index.js", .content = "export default 'edge-node';\n" },
    .{ .path = "package/legacy/index.js", .content = "export default 'edge-legacy';\n" },
};

const edge_plugin_source =
    \\import root from "edge-pkg";
    \\import feature from "edge-pkg/feature/a";
    \\import exact from "edge-pkg/exact";
    \\export default { "meta": { "type": "const", "value": root + feature + exact } };
    \\
;

fn writeEdgeProject(temporary: *std.testing.TmpDir, io: std.Io) !void {
    try writeProjectWithNpm(temporary, io, "edge-pkg = \"^2.0.0\"", edge_plugin_source);
}

const EdgeModules = struct {
    root: bool = false,
    feature: bool = false,
    exact: bool = false,
    cjs: bool = false,
    node: bool = false,
    legacy: bool = false,
};

fn inspectEdgeModules(program: *const lnako.ir.nako_ir.Program) EdgeModules {
    var found = EdgeModules{};
    for (program.javascript_modules) |module| {
        if (std.mem.indexOf(u8, module.source, "edge-root") != null) found.root = true;
        if (std.mem.indexOf(u8, module.source, "edge-feature-a") != null) found.feature = true;
        if (std.mem.indexOf(u8, module.source, "edge-exact") != null) found.exact = true;
        if (std.mem.indexOf(u8, module.source, "edge-cjs") != null) found.cjs = true;
        if (std.mem.indexOf(u8, module.source, "edge-node") != null) found.node = true;
        if (std.mem.indexOf(u8, module.source, "edge-legacy") != null) found.legacy = true;
    }
    return found;
}

fn expectEdgeResolution(modules: EdgeModules) !void {
    // `exports` の import 条件・`*` サブパス・exact サブパスだけが解決され、
    // node 条件 / default / legacy main は選ばれない。
    try testing.expect(modules.root);
    try testing.expect(modules.feature);
    try testing.expect(modules.exact);
    try testing.expect(!modules.cjs);
    try testing.expect(!modules.node);
    try testing.expect(!modules.legacy);
}

test "package.json 本格パース: interpreter compile と AOT 埋め込みが同じ入口を解決する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);

    try writeEdgeProject(&temporary, io);
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", gpa);
    defer gpa.free(app_root);
    try prepareLockAndCacheFor(gpa, io, app_root, cache_root, .{
        .name = "edge-pkg",
        .version = "2.0.0",
        .files = &edge_package_files,
    });

    // (1) interpreter 経路（`lnako run --compat-js` と同じ compileInput）。
    {
        var stderr: std.Io.Writer.Allocating = .init(gpa);
        defer stderr.deinit();
        const program = (try compileMain(gpa, io, app_root, cache_root, &stderr)) orelse return error.UnexpectedCompileFailure;
        var compiled = program;
        defer compiled.deinit();
        try expectEdgeResolution(inspectEdgeModules(&compiled));
    }

    // (2) AOT 経路。`build --compat-js` は生成時に解決した npm binding を
    // payload へ埋め込み、起動時の再コンパイルでは cache/FS を読まない。
    const main_path = try std.fs.path.join(gpa, &.{ app_root, "main.nako3" });
    defer gpa.free(main_path);
    const stub_path = try std.fs.path.join(gpa, &.{ app_root, "lnako-stub" });
    defer gpa.free(stub_path);
    const output_path = try std.fs.path.join(gpa, &.{ app_root, "out.bin" });
    defer gpa.free(output_path);
    try temporary.dir.writeFile(io, .{ .sub_path = "app/lnako-stub", .data = "EXE" });
    try embedded_pipeline.writeCompatExecutable(gpa, io, stub_path, main_path, output_path, .{}, cache_root);

    var package = (try compat_embedded.readExecutable(gpa, io, output_path)) orelse return error.UnexpectedEmbeddedPayload;
    defer package.deinit();
    // root / features/a / exact の 3 解決だけが payload に記録される。
    try testing.expectEqual(@as(usize, 3), package.npm_imports.len);

    // cache と世代 deps（`.nako`）を消しても、payload の解決対応表だけで
    // 同じ入口を復元できる（起動時再コンパイルは cache/FS に依存しない）。
    try temporary.dir.deleteTree(io, "cache");
    try temporary.dir.deleteTree(io, "app/.nako");
    var stderr: std.Io.Writer.Allocating = .init(gpa);
    defer stderr.deinit();
    const program = (try compile_pipeline.compileInputWithProvider(gpa, package.entry_path, .{
        .compat_js = true,
        .forced_mode = package.forced_mode,
        .package_resolver = package.packageResolver(),
        .npm_module_resolver = package.npmModuleResolver(),
    }, &stderr.writer, package.sourceProvider())) orelse return error.UnexpectedCompileFailure;
    var compiled = program;
    defer compiled.deinit();
    try expectEdgeResolution(inspectEdgeModules(&compiled));
}

test "package.json 不正は interpreter compile と AOT 埋め込みの両経路で拒否される" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);

    // name/version は identity 検査を通るが exports のキーが混在している
    // package.json（Node 実測: ERR_INVALID_PACKAGE_CONFIG）。
    const broken_files = [_]TarFile{
        .{ .path = "package/package.json", .content =
        \\{"name":"edge-bad","version":"1.0.0",
        \\ "exports":{".":"./index.js","./sub":"./sub.js","import":"./esm.mjs"}}
        },
        .{ .path = "package/index.js", .content = "export default 1;\n" },
        .{ .path = "package/sub.js", .content = "export default 2;\n" },
        .{ .path = "package/esm.mjs", .content = "export default 3;\n" },
    };
    try writeProjectWithNpm(&temporary, io, "edge-bad = \"^1.0.0\"",
        \\import sub from "edge-bad/sub";
        \\export default { "meta": { "type": "const", "value": sub } };
        \\
    );
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", gpa);
    defer gpa.free(app_root);
    try prepareLockAndCacheFor(gpa, io, app_root, cache_root, .{
        .name = "edge-bad",
        .version = "1.0.0",
        .files = &broken_files,
    });

    // interpreter: package.json 不正として fail-closed の診断になる。
    {
        var stderr: std.Io.Writer.Allocating = .init(gpa);
        defer stderr.deinit();
        try testing.expect((try compileMain(gpa, io, app_root, cache_root, &stderr)) == null);
        // subpath 解決の失敗は instance 展開の成功後なので、instance 単位の
        // cache miss 診断ではなく汎用文言のまま（#54 は instance 展開の
        // 失敗だけを instance 単位で示す）。
        try testing.expect(std.mem.indexOf(u8, stderr.written(), "静的に解決できない取り込み指定") != null);
    }

    // AOT: 生成時の graph 解決も同じ理由で失敗し、生成物を残さない。
    {
        const main_path = try std.fs.path.join(gpa, &.{ app_root, "main.nako3" });
        defer gpa.free(main_path);
        const stub_path = try std.fs.path.join(gpa, &.{ app_root, "lnako-stub" });
        defer gpa.free(stub_path);
        const output_path = try std.fs.path.join(gpa, &.{ app_root, "out.bin" });
        defer gpa.free(output_path);
        try temporary.dir.writeFile(io, .{ .sub_path = "app/lnako-stub", .data = "EXE" });
        try testing.expectError(
            error.InvalidCompatSourceGraph,
            embedded_pipeline.writeCompatExecutable(gpa, io, stub_path, main_path, output_path, .{}, cache_root),
        );
        try testing.expectError(error.FileNotFound, temporary.dir.access(io, "app/out.bin", .{}));
    }
}

/// tar entry を gzip 圧縮した byte 列を作る（`provider_test.zig` と同じ手法）。
fn buildTarGz(gpa: std.mem.Allocator, files: []const TarFile) ![]u8 {
    var tar_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer tar_buffer.deinit();
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &tar_buffer.writer };
    for (files) |file| try tar_writer.writeFileBytes(file.path, file.content, .{});
    try tar_writer.finishPedantically();

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.ensureUnusedCapacity(64);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&out.writer, &window_buf, .gzip, .default);
    try compress.writer.writeAll(tar_buffer.written());
    try compress.finish();
    return try out.toOwnedSlice();
}
