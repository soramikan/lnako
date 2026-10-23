//! lock `npmInstances` の環境 materialize（#53）。
//!
//! - lock の `sha256`（tarball の SHA-256）と `url` から cache key を導出し、
//!   cache の raw archive を **lock の sha256 と照合してから** 展開する。
//!   cache の派生 tree は自己認証に過ぎないため信頼しない（artifact/http
//!   経路と同じ方針で、検証済み raw bytes から毎回 tree を作り直す）。
//! - 出力は `<gen>/deps/npm_<instance>`。dir 名は instance key から決定的に
//!   導出するので、lock と cache だけで offline 再構築できる。
//! - network・Node・npm CLI・lifecycle script は一切使わない。tarball が
//!   cache に無い場合は取得せず `not_found` 診断で失敗する（取得は
//!   `ensureLock` の resolve 経路の責務）。

const std = @import("std");
const cache = @import("cache.zig");
const environment = @import("environment.zig");
const fetch = @import("fetch.zig");
const lock_model = @import("lock_model.zig");
const materialize = @import("materialize.zig");
const npm_esm = @import("npm_esm.zig");
const unpack = @import("unpack.zig");

const Allocator = std.mem.Allocator;

/// instance dir 名の前置。package 名として有効な文字列は `_` を含めないため、
/// 世代 `deps/` 直下で package dir（`allocateDepsName`）と衝突しない。
pub const dir_prefix = "npm_";
/// dir 名に残す instance key の可読部分の上限（byte）。
const max_readable_bytes: usize = 64;

pub const Error = fetch.Error || error{FileSystem};

pub const Params = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    session: *fetch.Session,
    cache_store: *const cache.Store,
    /// 展開途中の tree を作る同期専有 workspace。
    workspace_dir: std.Io.Dir,
    /// `<gen>/deps`（公開先）。所有権は呼出し側（sync）にあり、ここでは閉じない。
    deps_dir: std.Io.Dir,
};

/// instance key から世代内の dir 名を作る。`[a-z0-9-_]` 以外は `-` へ畳み、
/// 衝突しないよう key の SHA-256 を後置する。結果は常に単一の規範 path
/// 成分（`/`・`.`・`..`・制御文字を含まない）。
pub fn instanceDirName(arena: Allocator, instance: lock_model.NpmInstance) Allocator.Error![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(instance.key, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    var readable: [max_readable_bytes]u8 = undefined;
    var len: usize = 0;
    for (instance.key) |byte| {
        if (len >= max_readable_bytes) break;
        const lower = std.ascii.toLower(byte);
        if (std.ascii.isAlphanumeric(lower) or lower == '-' or lower == '_') {
            readable[len] = lower;
        } else {
            readable[len] = '-';
        }
        len += 1;
    }
    const trimmed = std.mem.trim(u8, readable[0..len], "-_");
    if (trimmed.len == 0) return std.fmt.allocPrint(arena, "{s}{s}", .{ dir_prefix, hex[0..12] });
    return std.fmt.allocPrint(arena, "{s}{s}-{s}", .{ dir_prefix, trimmed, hex[0..12] });
}

/// `generation_rel`（`.nako/env/<gen>`）配下の instance tree の論理 path。
/// 消費側はこの helper で lock instance から環境内 path を再導出できる。
pub fn instanceRelPath(arena: Allocator, generation_rel: []const u8, instance: lock_model.NpmInstance) Allocator.Error![]u8 {
    const name = try instanceDirName(arena, instance);
    return std.fmt.allocPrint(arena, "{s}/deps/{s}", .{ generation_rel, name });
}

/// `instances` を世代 `deps/` へ materialize する。空なら何もしない。
/// 途中で失敗した場合、生成済みの tree は世代ごと破棄される（公開しない）。
///
/// 返り値は今回読んだ cache object key（`params.arena` 所有）。呼出し側は
/// これを sync の used-keys へ記録し、`sync --clean` が直後に参照 entry を
/// 消さないようにする。
pub fn materializeInstances(params: Params, instances: []const lock_model.NpmInstance) Error![]const []const u8 {
    if (instances.len == 0) return &.{};
    var used_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    for (instances) |instance| try materializeOne(params, instance, &used_keys);
    return used_keys.items;
}

fn materializeOne(
    params: Params,
    instance: lock_model.NpmInstance,
    used_keys: *std.ArrayListUnmanaged([]const u8),
) Error!void {
    const arena = params.arena;
    const dir_name = try instanceDirName(arena, instance);
    const archive = try readVerifiedArchive(params, instance, used_keys);
    defer params.gpa.free(archive);

    // 展開先は毎回作り直し、中断 residue を持ち越さない。
    const scratch_name = try std.fmt.allocPrint(arena, ".npm-tree-{s}", .{dir_name});
    environment.deleteTreeChecked(params.workspace_dir, params.io, scratch_name) catch {};
    params.workspace_dir.createDir(params.io, scratch_name, .default_dir) catch |err| return mapFs(err);
    var scratch = params.workspace_dir.openDir(params.io, scratch_name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapFs(err);
    defer {
        scratch.close(params.io);
        environment.deleteTreeChecked(params.workspace_dir, params.io, scratch_name) catch {};
    }
    if (looksLikeGzip(archive)) {
        // npm tarball は `package/` 前置を持つ（cache object と同じ strip）。
        unpack.extractTarGzInto(params.gpa, params.io, archive, scratch, .{ .strip_components = 1 }) catch |err| return mapUnpackError(params, err, instance.key);
    } else {
        // 非 gzip の fixture bytes は cache 側と同じく `blob` として置く。
        scratch.writeFile(params.io, .{ .sub_path = "blob", .data = archive }) catch |err| return mapFs(err);
    }

    // 同一世代内の再実行でも同じ結果になるようにする。
    environment.deleteTreeChecked(params.deps_dir, params.io, dir_name) catch {};
    params.deps_dir.createDirPath(params.io, dir_name) catch |err| return mapFs(err);
    var dest = params.deps_dir.openDir(params.io, dir_name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapFs(err);
    defer dest.close(params.io);
    _ = materialize.copyTreeFromDirs(params.gpa, params.io, &scratch, &dest, .{}) catch |err| return mapTreeError(params, err, instance.key);
}

/// lock の `sha256` と cache の raw archive を照合して bytes を返す。
/// 検証できない bytes は返さない（欠落・改竄はどちらも `not_found`）。
fn readVerifiedArchive(
    params: Params,
    instance: lock_model.NpmInstance,
    used_keys: *std.ArrayListUnmanaged([]const u8),
) Error![]const u8 {
    const sha256 = instance.sha256 orelse return params.session.fail(
        .invalid_source,
        .artifact,
        instance.key,
        "npm instance \"{s}\" has no sha256 in nako.lock",
        .{instance.key},
    );
    if (instance.url == null) return params.session.fail(
        .invalid_source,
        .artifact,
        instance.key,
        "npm instance \"{s}\" has no tarball url in nako.lock",
        .{instance.key},
    );
    const key = (npm_esm.cacheKeyForInstance(params.arena, instance) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    }) orelse return params.session.fail(
        .invalid_source,
        .artifact,
        instance.key,
        "npm instance \"{s}\" cannot be addressed in the cache from nako.lock",
        .{instance.key},
    );
    // tarball bytes は instance 単位で解放する（sync 全体 arena に載せない）。
    // cache key だけ used_keys 経由で arena に残す。
    const archive = params.cache_store.readVerifiedSourceArchive(params.gpa, key, sha256) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidKey => return params.session.fail(
            .invalid_source,
            .artifact,
            instance.key,
            "npm instance \"{s}\" has an invalid cache key",
            .{instance.key},
        ),
    };
    const bytes = archive orelse return params.session.fail(
        .not_found,
        .artifact,
        instance.key,
        "npm tarball for \"{s}\" is not in the cache; re-resolve dependencies while the registry is reachable",
        .{instance.key},
    );
    // `sync --clean` の keep list に載せる（直後に参照 entry を消さない）。
    try used_keys.append(params.arena, key);
    return bytes;
}

fn looksLikeGzip(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b;
}

fn mapFs(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.FileSystem,
    };
}

fn mapTreeError(params: Params, err: anyerror, subject: []const u8) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.SymlinkEncountered, error.UnsupportedEntry, error.NonCanonicalPath, error.DuplicatePath, error.CaseCollision => params.session.fail(.invalid_source, .artifact, subject, "npm package tree for \"{s}\" is not safe to materialize: {s}", .{ subject, @errorName(err) }),
        error.TooManyEntries, error.FileTooLarge, error.TreeTooLarge, error.TreeTooDeep => params.session.fail(.too_large, .artifact, subject, "npm package tree for \"{s}\" exceeds materialize limits: {s}", .{ subject, @errorName(err) }),
        else => error.FileSystem,
    };
}

fn mapUnpackError(params: Params, err: anyerror, subject: []const u8) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.InvalidArchive, error.UnsupportedEntry, error.SymlinkEncountered, error.NonCanonicalPath, error.DuplicatePath, error.CaseCollision => params.session.fail(.invalid_source, .artifact, subject, "npm tarball for \"{s}\" is not safe to extract: {s}", .{ subject, @errorName(err) }),
        error.TooManyEntries, error.FileTooLarge, error.TreeTooLarge, error.TreeTooDeep => params.session.fail(.too_large, .artifact, subject, "npm tarball for \"{s}\" exceeds extraction limits: {s}", .{ subject, @errorName(err) }),
        else => error.FileSystem,
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_sandbox = @import("test_sandbox.zig");
const diag = @import("diagnostics.zig");

/// `package/` 前置を持つ npm tarball（tar.gz）を作る。registry の配布形式と
/// 同じ shape を fixture でも再現するため、unpack/cache 側の strip 契約を
/// そのまま検証できる。
fn buildNpmTarball(
    gpa: Allocator,
    name: []const u8,
    version: []const u8,
    entry_file: []const u8,
    entry_bytes: []const u8,
) ![]u8 {
    const package_json = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"version\":\"{s}\",\"main\":\"{s}\"}}", .{ name, version, entry_file });
    defer gpa.free(package_json);

    var tar_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer tar_buffer.deinit();
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &tar_buffer.writer };
    try tar_writer.setRoot("package");
    try tar_writer.writeFileBytes("package.json", package_json, .{});
    try tar_writer.writeFileBytes(entry_file, entry_bytes, .{});
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

/// 世代・workspace・cache・session を 1 つずつ持つ fixture。
const Harness = struct {
    temporary: std.testing.TmpDir,
    store: cache.Store,
    cache_root: [:0]u8,
    workspace: std.Io.Dir,
    deps: std.Io.Dir,
    session: fetch.Session,
    diagnostics: diag.List,
    arena_impl: std.heap.ArenaAllocator,

    fn init() !Harness {
        const io = testing.io;
        const gpa = testing.allocator;
        var temporary = test_sandbox.tmpDir(.{});
        errdefer temporary.cleanup();
        try temporary.dir.createDirPath(io, "cache");
        const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
        errdefer gpa.free(cache_root);
        var store = try cache.Store.open(gpa, io, cache_root);
        errdefer store.deinit();
        // workspace は cache の staging ではなく、同期専有 dir として用意する。
        try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps");
        try temporary.dir.createDirPath(io, ".nako/work");
        const workspace = try temporary.dir.openDir(io, ".nako/work", .{ .iterate = true, .follow_symlinks = false });
        errdefer workspace.close(io);
        const deps = try temporary.dir.openDir(io, ".nako/env/gen-test/deps", .{ .iterate = true, .follow_symlinks = false });
        errdefer deps.close(io);
        return .{
            .temporary = temporary,
            .store = store,
            .cache_root = cache_root,
            .workspace = workspace,
            .deps = deps,
            // network 禁止で materialize が通信しないことを担保する。
            .session = fetch.Session.init(gpa, io, .{ .offline = true }),
            .diagnostics = diag.List.init(gpa),
            .arena_impl = std.heap.ArenaAllocator.init(gpa),
        };
    }

    fn deinit(self: *Harness) void {
        self.session.deinit();
        self.diagnostics.deinit();
        self.arena_impl.deinit();
        self.deps.close(testing.io);
        self.workspace.close(testing.io);
        self.store.deinit();
        testing.allocator.free(self.cache_root);
        self.temporary.cleanup();
    }

    fn params(self: *Harness) Params {
        // diagnostics は self の最終位置を指す必要があるため、init ではなく
        // ここで配線する（戻り値コピーの pointer を残さない）。
        self.session.diagnostics = &self.diagnostics;
        return .{
            .gpa = testing.allocator,
            .arena = self.arena_impl.allocator(),
            .io = testing.io,
            .session = &self.session,
            .cache_store = &self.store,
            .workspace_dir = self.workspace,
            .deps_dir = self.deps,
        };
    }

    /// `cacheKeyForInstance` が導出する key へ tarball を公開する（resolve 後の
    /// cache 状態を再現する）。
    fn publish(self: *Harness, instance: lock_model.NpmInstance, bytes: []const u8) !void {
        const key = (try npm_esm.cacheKeyForInstance(testing.allocator, instance)).?;
        defer testing.allocator.free(key);
        try npm_esm.publishNpmTree(testing.allocator, testing.io, &self.store, key, bytes);
    }

    /// 世代内の実体 path（`.` 区切りで temporary.dir 相対）。
    fn depsPath(self: *Harness, arena: Allocator, rel: []const u8) ![]u8 {
        _ = self;
        return std.fmt.allocPrint(arena, ".nako/env/gen-test/deps/{s}", .{rel});
    }
};

fn testInstance(arena: Allocator, gpa: Allocator, bytes: []const u8) !lock_model.NpmInstance {
    const sha = try fetch.sha256Hex(gpa, bytes);
    defer gpa.free(sha);
    return .{
        .key = try arena.dupe(u8, "escape@1.2.3"),
        .name = try arena.dupe(u8, "escape"),
        .version = try arena.dupe(u8, "1.2.3"),
        .sha256 = try std.fmt.allocPrint(arena, "sha256:{s}", .{sha}),
        .url = try arena.dupe(u8, "fixture://escape-1.2.3.tgz"),
    };
}

test "npm_env instanceDirName は決定的な規範 path 成分を作る" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const scoped: lock_model.NpmInstance = .{ .key = "@scope/pkg@1.0.0#ctx-a", .name = "@scope/pkg", .version = "1.0.0" };
    const first = try instanceDirName(arena, scoped);
    const second = try instanceDirName(arena, scoped);
    try testing.expectEqualStrings(first, second);
    // `/`・`@`・`#` は畳み込まれ、単一成分として扱える。
    try testing.expect(std.mem.indexOfAny(u8, first, "/ .@#\\") == null);
    try testing.expect(std.mem.startsWith(u8, first, dir_prefix));

    // key が違えば dir 名も必ず違う（可読部が衝突しても hash で分離）。
    const plain: lock_model.NpmInstance = .{ .key = "scope-pkg@1.0.0-ctx-a", .name = "scope-pkg", .version = "1.0.0-ctx-a" };
    const other = try instanceDirName(arena, plain);
    try testing.expect(!std.mem.eql(u8, first, other));

    // 可読部を持たない key でも空にならない。
    const blank: lock_model.NpmInstance = .{ .key = "@@@", .name = "@@@", .version = "1.0.0" };
    const blank_dir = try instanceDirName(arena, blank);
    try testing.expect(std.mem.startsWith(u8, blank_dir, dir_prefix));
    try testing.expect(blank_dir.len > dir_prefix.len);

    const rel = try instanceRelPath(arena, ".nako/env/gen-1", scoped);
    try testing.expectEqualStrings(".nako/env/gen-1/deps/", rel[0..".nako/env/gen-1/deps/".len]);
    try testing.expect(std.mem.endsWith(u8, rel, first));
}

test "npm_env は cache の tarball を世代 deps/ へ展開し package/ 前置を落とす" {
    var h = try Harness.init();
    defer h.deinit();
    const gpa = testing.allocator;
    const arena = h.arena_impl.allocator();

    const tarball = try buildNpmTarball(gpa, "escape", "1.2.3", "index.mjs", "export default 1;\n");
    defer gpa.free(tarball);
    const instance = try testInstance(arena, gpa, tarball);
    try h.publish(instance, tarball);

    const params = h.params();
    const used_keys = try materializeInstances(params, &.{instance});

    // used-keys は `sync --clean` の keep list 用（lock から再導出できる key）。
    const expected_key = (try npm_esm.cacheKeyForInstance(arena, instance)).?;
    try testing.expectEqual(@as(usize, 1), used_keys.len);
    try testing.expectEqualStrings(expected_key, used_keys[0]);

    const dir_name = try instanceDirName(arena, instance);
    const entry_rel = try std.fmt.allocPrint(arena, "{s}/index.mjs", .{dir_name});
    const entry_path = try h.depsPath(arena, entry_rel);
    const entry_bytes = try h.temporary.dir.readFileAlloc(testing.io, entry_path, gpa, .unlimited);
    defer gpa.free(entry_bytes);
    try testing.expectEqualStrings("export default 1;\n", entry_bytes);

    // package.json も root 直下へ来る（`package/` 成分が残っていない）。
    const pj_rel = try std.fmt.allocPrint(arena, "{s}/package.json", .{dir_name});
    const pj_path = try h.depsPath(arena, pj_rel);
    const pj_bytes = try h.temporary.dir.readFileAlloc(testing.io, pj_path, gpa, .unlimited);
    defer gpa.free(pj_bytes);
    try testing.expect(std.mem.indexOf(u8, pj_bytes, "\"escape\"") != null);
    const nested_rel = try std.fmt.allocPrint(arena, "{s}/package", .{dir_name});
    const nested_path = try h.depsPath(arena, nested_rel);
    try testing.expectError(error.FileNotFound, h.temporary.dir.access(testing.io, nested_path, .{}));

    // 再実行しても同じ path に同じ内容で収束する（idempotent）。
    const again = h.params();
    _ = try materializeInstances(again, &.{instance});
    const again_bytes = try h.temporary.dir.readFileAlloc(testing.io, entry_path, gpa, .unlimited);
    defer gpa.free(again_bytes);
    try testing.expectEqualStrings("export default 1;\n", again_bytes);
}

test "npm_env は再同期で同じ世代 path を使う" {
    var h = try Harness.init();
    defer h.deinit();
    const gpa = testing.allocator;
    const arena = h.arena_impl.allocator();

    const tarball = try buildNpmTarball(gpa, "escape", "1.2.3", "index.js", "module.exports = 1;\n");
    defer gpa.free(tarball);
    const instance = try testInstance(arena, gpa, tarball);
    try h.publish(instance, tarball);

    const first = h.params();
    _ = try materializeInstances(first, &.{instance});
    const dir_name = try instanceDirName(arena, instance);

    // 世代 dir を差し替えても instance key から同じ dir 名を再導出できる。
    const second = h.params();
    _ = try materializeInstances(second, &.{instance});
    try testing.expectEqualStrings(dir_name, try instanceDirName(arena, instance));
    const rel = try instanceRelPath(arena, ".nako/env/gen-test", instance);
    const stem = try std.fmt.allocPrint(arena, ".nako/env/gen-test/deps/{s}", .{dir_prefix});
    try testing.expect(std.mem.startsWith(u8, rel, stem));
}

test "npm_env は cache 欠落を not_found として診断する" {
    var h = try Harness.init();
    defer h.deinit();
    const gpa = testing.allocator;
    const arena = h.arena_impl.allocator();

    const tarball = try buildNpmTarball(gpa, "escape", "1.2.3", "index.mjs", "x\n");
    defer gpa.free(tarball);
    // 何も publish しない。
    const instance = try testInstance(arena, gpa, tarball);

    const params = h.params();
    try testing.expectError(error.NotFound, materializeInstances(params, &.{instance}));
    const failure = h.session.lastFailure() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(fetch.FailureKind.not_found, failure.kind);
    try testing.expect(std.mem.indexOf(u8, failure.message, "not in the cache") != null);
}

test "npm_env は lock の sha256 と食い違う cache bytes を materialize しない" {
    var h = try Harness.init();
    defer h.deinit();
    const gpa = testing.allocator;
    const arena = h.arena_impl.allocator();

    const expected = try buildNpmTarball(gpa, "escape", "1.2.3", "index.mjs", "expected\n");
    defer gpa.free(expected);
    const tampered = try buildNpmTarball(gpa, "escape", "1.2.3", "index.mjs", "tampered\n");
    defer gpa.free(tampered);
    const instance = try testInstance(arena, gpa, expected);
    // lock の sha256 が指す key に、別内容の tarball を置く（cache 改竄相当）。
    try h.publish(instance, tampered);

    const params = h.params();
    try testing.expectError(error.NotFound, materializeInstances(params, &.{instance}));
    const dir_name = try instanceDirName(arena, instance);
    const entry_rel = try std.fmt.allocPrint(arena, "{s}", .{dir_name});
    const entry_path = try h.depsPath(arena, entry_rel);
    try testing.expectError(error.FileNotFound, h.temporary.dir.access(testing.io, entry_path, .{}));
}

test "npm_env は sha256・url を持たない instance を invalid_source にする" {
    var h = try Harness.init();
    defer h.deinit();
    const arena = h.arena_impl.allocator();

    const no_sha: lock_model.NpmInstance = .{ .key = "a@1.0.0", .name = "a", .version = "1.0.0", .url = "fixture://a.tgz" };
    const params = h.params();
    try testing.expectError(error.InvalidSource, materializeInstances(params, &.{no_sha}));

    const no_url: lock_model.NpmInstance = .{
        .key = "b@1.0.0",
        .name = "b",
        .version = "1.0.0",
        .sha256 = try arena.dupe(u8, "sha256:0000000000000000000000000000000000000000000000000000000000000000"),
    };
    try testing.expectError(error.InvalidSource, materializeInstances(params, &.{no_url}));
}
