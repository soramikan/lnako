//! lock `npmInstances` と cache から `npm_esm.BareRegistry` を構築する（#54）。
//!
//! - network・Node・npm CLI は使わない。cache に lock の `sha256` と一致する
//!   tarball が無ければ `CacheMiss` で fail-closed。
//! - registry は bare name 単位。同一 name の複数 instance（lock context 別）は
//!   誤った版を黙って選ばないよう `AmbiguousInstances` で失敗する。
//! - cache の派生 `tree/` は entry marker の自己認証に過ぎず、lock 束縛を
//!   証明しない（`npm_env.zig` と同じ方針）。lock の `sha256` で raw archive
//!   を検証し、その bytes から private scratch へ tree を作り直す。
//! - scratch は TMPDIR 配下の一意 dir。`Prepared.deinit` で再帰削除する。
//!   path は realpath 化して保持する（`module_graph` の package 境界検査は
//!   canonical path 同士の比較のため）。
//! - scratch の寿命は compile 中のみ。IR/Program へは module source が dupe
//!   されるため、compile 後に npm 由来 module の path を開き直さない契約。
//! - instance の展開は bare name が要求されたときだけ行う。無関係な
//!   instance の cache 欠落で、cache 済みの package の解決を止めない。
//!
//! cache key と instance の対応は `npm_esm.cacheKeyForInstance`、instance の
//! 登録は `npm_esm.BareRegistry.registerInstance` を再利用する（key 計算を
//! 二重実装しない）。`buildFromInstances` は npm_esm 自身のテスト用に残る。

const std = @import("std");
const builtin = @import("builtin");
const cache_mod = @import("cache.zig");
const environment = @import("environment.zig");
const fetch = @import("fetch.zig");
const lock_model = @import("lock_model.zig");
const npm_esm = @import("npm_esm.zig");
const unpack = @import("unpack.zig");
const module_graph = @import("../semantic/module_graph.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// scratch tree は他主体から書き換えられない 0700 で作る（POSIX）。
/// Windows は既定属性のまま。
const scratch_permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_dir
else
    .fromMode(0o700);

pub const Error = error{ CacheMiss, InvalidArchive, AmbiguousInstances, BareNotFound, Canceled, CacheUnavailable, ScratchUnavailable, OutOfMemory };

/// 遅延構築する npm registry。scratch と cache store を所有し、bare name が
/// 要求された instance だけを展開・登録する。
pub const Prepared = struct {
    gpa: Allocator,
    io: std.Io,
    instances: []const lock_model.NpmInstance,
    by_name: std.StringHashMapUnmanaged(usize) = .empty,
    scratch: Scratch,
    store: cache_mod.Store,
    registry: npm_esm.BareRegistry,
    extracted: std.StringHashMapUnmanaged(void) = .empty,
    /// name 単位の展開失敗（同一 name の再展開 I/O を避ける）。
    failed: std.StringHashMapUnmanaged(Error) = .empty,

    pub fn deinit(self: *Prepared) void {
        var failed_it = self.failed.iterator();
        while (failed_it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.failed.deinit(self.gpa);
        var extracted_it = self.extracted.iterator();
        while (extracted_it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.extracted.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
        self.registry.deinit();
        self.store.deinit();
        self.scratch.deinit();
        self.* = undefined;
    }

    /// 要求された bare name の instance だけを cache から展開して登録する。
    /// 失敗した name は記憶し、同じ欠落を毎回 I/O し直さない（他の name の
    /// 解決は妨げない）。
    fn ensureInstance(self: *Prepared, name: []const u8) Error!void {
        if (self.registry.by_name.contains(name)) return;
        if (self.failed.get(name)) |err| return err;
        const index = self.by_name.get(name) orelse return error.BareNotFound;
        const instance = self.instances[index];
        const tree = self.extractInstance(instance) catch |err| {
            const classified = classifyExtraction(err);
            if (classified != error.OutOfMemory and classified != error.Canceled) {
                // メモ化の失敗で元の分類をマスクしない（best-effort）。
                self.rememberFailure(name, classified) catch {};
            }
            return classified;
        };
        defer self.gpa.free(tree);
        self.registry.registerInstance(instance, tree) catch |err| {
            const classified = classifyExtraction(err);
            if (classified != error.OutOfMemory and classified != error.Canceled) {
                self.rememberFailure(name, classified) catch {};
            }
            return classified;
        };
    }

    fn rememberFailure(self: *Prepared, name: []const u8, err: Error) !void {
        if (self.failed.contains(name)) return;
        const key = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(key);
        try self.failed.put(self.gpa, key, err);
    }

    /// lock の sha256 で検証した archive を scratch の `<scratch>/<cache key>`
    /// へ展開し、tree root path を返す（呼出し側が free する）。
    fn extractInstance(self: *Prepared, instance: lock_model.NpmInstance) anyerror![]u8 {
        const key = (try npm_esm.cacheKeyForInstance(self.gpa, instance)) orelse return error.CacheMiss;
        defer self.gpa.free(key);
        // scratch の dir 名に使うため、単一の規範 path 成分であることを検証する
        // （cache key は hash 由来だが、lock 材料が変わっても書き込み面を守る）。
        if (!isSafeCacheKey(key)) return error.CacheMiss;
        if (self.extracted.contains(key)) return try std.fs.path.join(self.gpa, &.{ self.scratch.path, key });

        const sha256 = instance.sha256 orelse return error.CacheMiss;
        const bytes = (self.store.readVerifiedSourceArchive(self.gpa, key, sha256) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CacheMiss,
        }) orelse return error.CacheMiss;
        defer self.gpa.free(bytes);

        // 同一 key は `extracted` で早期 return するため、ここで既存 dir が
        // あるのは想定外（同一ユーザーの競合・残骸）。内容を検証できない dir を
        // package root として使わないよう fail-closed。
        self.scratch.dir.createDir(self.io, key, scratch_permissions) catch |err| switch (err) {
            error.PathAlreadyExists => return error.CacheMiss,
            else => return err,
        };
        {
            var tree = self.scratch.dir.openDir(self.io, key, .{ .iterate = true, .follow_symlinks = false }) catch |err| return err;
            defer tree.close(self.io);
            if (npm_esm.looksLikeGzip(bytes)) {
                // npm tarball は `package/` 前置を持つ（cache 公開時と同じ strip）。
                unpack.extractTarGzInto(self.gpa, self.io, bytes, tree, .{ .strip_components = 1 }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Canceled => return error.Canceled,
                    // tar/gzip の構造・安全検査の失敗だけを InvalidArchive に分類し、
                    // 書き込み I/O の失敗は呼出し側の CacheMiss へ委ねる。
                    error.InvalidArchive, error.UnsupportedEntry, error.SymlinkEncountered, error.NonCanonicalPath, error.DuplicatePath, error.CaseCollision, error.TooManyEntries, error.FileTooLarge, error.TreeTooLarge, error.TreeTooDeep => return error.InvalidArchive,
                    else => return err,
                };
            } else {
                // 非 gzip fixture は cache 公開時と同じく `blob` として置く
                // （package.json が無いため入口解決は `BareNotFound` になる）。
                tree.writeFile(self.io, .{ .sub_path = "blob", .data = bytes }) catch |err| return err;
            }
        }
        // put 成功後は map が key を所有するため、その後に fallible な処理を
        // 残さない（errdefer と deinit の二重解放を避ける）。
        const key_copy = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(key_copy);
        const tree_path = try std.fs.path.join(self.gpa, &.{ self.scratch.path, key });
        errdefer self.gpa.free(tree_path);
        try self.extracted.put(self.gpa, key_copy, {});
        return tree_path;
    }

    /// bare specifier を解決する。要求された name の instance だけを準備する。
    pub fn resolveBare(self: *Prepared, specifier: []const u8) anyerror!npm_esm.ResolvedEntry {
        const parsed = npm_esm.parseBareSpecifier(specifier) orelse return error.BareNotFound;
        try self.ensureInstance(parsed.name);
        return self.registry.resolveBare(specifier);
    }
};

pub const Scratch = struct {
    gpa: Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    dir: std.Io.Dir,
    name: []u8,
    /// canonical な絶対 path。
    path: []u8,

    pub fn deinit(self: *Scratch) void {
        self.dir.close(self.io);
        // best-effort: 削除に失敗しても(TMPDIR 側の残骸は)次回の一意名で
        // 再作成されるため、ここでは診断を出さない。
        environment.deleteTreeChecked(self.parent, self.io, self.name) catch {};
        self.parent.close(self.io);
        self.gpa.free(self.name);
        self.gpa.free(self.path);
        self.* = undefined;
    }
};

/// Resolver が保持する npm 解決の遅延状態。lock から抽出した instance と、
/// 初回 bare 解決時に構築する cache 由来 registry を持つ。
pub const State = struct {
    io: std.Io = undefined,
    /// Resolver の backing allocator。module_graph の callback allocator は
    /// load 中の一時 arena なので、registry はこの allocator で構築する。
    backing_allocator: Allocator = undefined,
    instances: []const lock_model.NpmInstance = &.{},
    cache_root: ?[]const u8 = null,
    prepared: ?Prepared = null,
    /// prepare（scratch/cache 構築・lock 名の曖昧さ等）の失敗を記憶し、以後の
    /// import で再試行しない。Prepared 段階の instance 単位の失敗は
    /// `Prepared.failed` が name ごとに保持する。
    failure: ?anyerror = null,

    /// lock の選択 profile から `npmInstances` を取り込む。`lock_root` は
    /// Resolver の arena に載っている parsed lock。`storage` は Resolver の
    /// arena（instance 文字列の寿命）、`backing_allocator` は registry/scratch
    /// 用の実 allocator（archive bytes を都度 free できる）を渡す。
    pub fn load(
        storage: Allocator,
        backing_allocator: Allocator,
        io: std.Io,
        lock_root: std.json.ObjectMap,
        profile: []const u8,
        cache_root: ?[]const u8,
    ) !State {
        return .{
            .io = io,
            .backing_allocator = backing_allocator,
            .instances = try collectInstances(storage, lock_root, profile),
            .cache_root = if (cache_root) |explicit| try storage.dupe(u8, explicit) else null,
        };
    }

    pub fn deinit(self: *State) void {
        if (self.prepared) |*prepared| prepared.deinit();
        self.* = undefined;
    }

    /// package 所有 JS の bare specifier を解決する callback を返す。
    pub fn moduleResolver(self: *State) module_graph.NpmModuleResolver {
        return .{ .context = self, .resolveFn = resolveCallback };
    }

    fn resolveCallback(
        context: *anyopaque,
        allocator: Allocator,
        importer_owner: ?[]const u8,
        importer_package_root: ?[]const u8,
        specifier: []const u8,
    ) anyerror!module_graph.ResolvedNpmModule {
        // flat な node_modules（hoisting）相当の name 単位解決。importer の
        // 宣言 scope 別解決は lock 側に情報が無く未対応（docs/TODO.md）。
        _ = importer_owner;
        _ = importer_package_root;
        const self: *State = @ptrCast(@alignCast(context));
        const entry = try self.resolveBare(allocator, specifier);
        return .{ .path = entry.path, .package_root = entry.package_root };
    }

    /// bare specifier を registry へ写す。network は使わず、cache に lock の
    /// sha256 と一致する tarball が無ければ fail-closed で error を返す。
    /// 返却した `path`/`package_root` は本関数に渡した `allocator` の所有で、
    /// 呼出し側へ移管する。`ResolvedEntry.deinit(同じ allocator)` でも等価。
    pub fn resolveBare(self: *State, allocator: Allocator, specifier: []const u8) !npm_esm.ResolvedEntry {
        if (self.instances.len == 0) return error.BareNotFound;
        if (self.failure) |err| return err;
        if (self.prepared == null) {
            self.prepared = prepare(self.backing_allocator, self.io, self.instances, self.cache_root) catch |err| {
                // 失敗した compile 中で scratch/cache の再構築を繰り返さない。
                self.failure = err;
                return err;
            };
        }
        const entry = self.prepared.?.resolveBare(specifier) catch |err| {
            // 解決不能（BareNotFound 等）は specifier 単位なので sticky にしない。
            if (isStickyFailure(err)) self.failure = err;
            return err;
        };
        defer entry.deinit(self.backing_allocator);
        // 呼出し側（module_graph）は自身の allocator で path/root を free する。
        const path = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(path);
        const package_root = try allocator.dupe(u8, entry.package_root);
        return .{ .path = path, .package_root = package_root };
    }
};

fn asObject(value: Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn get(object: std.json.ObjectMap, key: []const u8) ?Value {
    return object.get(key);
}

/// lock の選択 profile に対応する package map を選ぶ。環境検証と
/// npmInstances 抽出で同じ規則を使う（片側だけ変わって検証外の record を
/// 解決に使わないようにする）。
pub fn selectLockedPackages(lock_root: std.json.ObjectMap, profile: []const u8) !Value {
    const input = asObject(get(lock_root, "input") orelse return error.InvalidEnvironment) orelse return error.InvalidEnvironment;
    const input_profile = get(input, "profile") orelse return error.InvalidEnvironment;
    if (input_profile != .string) return error.InvalidEnvironment;
    if (get(lock_root, "profilePackages")) |profiles_value| {
        const profiles = asObject(profiles_value) orelse return error.InvalidEnvironment;
        if (profiles.get(profile)) |selected| return selected;
        if (std.mem.eql(u8, profile, input_profile.string)) return get(lock_root, "packages") orelse return error.InvalidEnvironment;
        return error.InvalidEnvironment;
    }
    if (!std.mem.eql(u8, profile, input_profile.string)) return error.InvalidEnvironment;
    return get(lock_root, "packages") orelse return error.InvalidEnvironment;
}

/// lock の選択 profile から `npmInstances` を集め、key 昇順へ正規化する。
/// 同一 instance が複数 package record に載っても key で dedupe する。
fn collectInstances(allocator: Allocator, lock_root: std.json.ObjectMap, profile: []const u8) ![]const lock_model.NpmInstance {
    const packages = asObject(try selectLockedPackages(lock_root, profile)) orelse return error.InvalidEnvironment;

    var seen = std.StringHashMap(usize).init(allocator);
    defer seen.deinit();
    var list: std.ArrayList(lock_model.NpmInstance) = .empty;
    var iterator = packages.iterator();
    while (iterator.next()) |entry| {
        const package = asObject(entry.value_ptr.*) orelse return error.InvalidEnvironment;
        const instances_value = get(package, "npmInstances") orelse continue;
        const instances = asObject(instances_value) orelse return error.InvalidEnvironment;
        var instance_iterator = instances.iterator();
        while (instance_iterator.next()) |instance_entry| {
            const key = instance_entry.key_ptr.*;
            const value = asObject(instance_entry.value_ptr.*) orelse return error.InvalidEnvironment;
            const name_value = get(value, "name") orelse return error.InvalidEnvironment;
            const version_value = get(value, "version") orelse return error.InvalidEnvironment;
            if (name_value != .string or version_value != .string) return error.InvalidEnvironment;
            const context_value = get(value, "context");
            if (context_value) |item| if (item != .string) return error.InvalidEnvironment;
            const sha_value = get(value, "sha256");
            if (sha_value) |item| if (item != .string) return error.InvalidEnvironment;
            const url_value = get(value, "url");
            if (url_value) |item| if (item != .string) return error.InvalidEnvironment;
            const parsed = lock_model.NpmInstance{
                .key = try allocator.dupe(u8, key),
                .name = try allocator.dupe(u8, name_value.string),
                .version = try allocator.dupe(u8, version_value.string),
                .context = if (context_value) |item| try allocator.dupe(u8, item.string) else null,
                .sha256 = if (sha_value) |item| try allocator.dupe(u8, item.string) else null,
                .url = if (url_value) |item| try allocator.dupe(u8, item.string) else null,
                .peer_dependencies = try collectPeers(allocator, get(value, "peerDependencies")),
            };
            if (seen.get(key)) |existing_index| {
                // 同一 key が複数 record に載る場合は内容（peer 含む）も
                // 一致していなければ環境と lock の齟齬として拒否する。
                if (!lock_model.npmInstanceEql(list.items[existing_index], parsed)) return error.InvalidEnvironment;
                continue;
            }
            try list.append(allocator, parsed);
            try seen.put(parsed.key, list.items.len - 1);
        }
    }
    std.mem.sort(lock_model.NpmInstance, list.items, {}, struct {
        fn lt(_: void, a: lock_model.NpmInstance, b: lock_model.NpmInstance) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
    return try list.toOwnedSlice(allocator);
}

fn collectPeers(allocator: Allocator, value: ?Value) ![]const lock_model.PeerDependency {
    const object = if (value) |item|
        asObject(item) orelse return error.InvalidEnvironment
    else
        return &.{};
    var list: std.ArrayList(lock_model.PeerDependency) = .empty;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const requirement = entry.value_ptr.*;
        if (requirement != .string) return error.InvalidEnvironment;
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .requirement = try allocator.dupe(u8, requirement.string),
        });
    }
    std.mem.sort(lock_model.PeerDependency, list.items, {}, struct {
        fn lt(_: void, a: lock_model.PeerDependency, b: lock_model.PeerDependency) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    return try list.toOwnedSlice(allocator);
}

/// `instances` の name 索引と scratch/cache を用意する。instance の展開は
/// 最初にその name が要求されたときに行う（無関係な instance の cache 欠落で
/// 解決を止めない）。`cache_root == null` は OS 標準 cache dir。
pub fn prepare(
    gpa: Allocator,
    io: std.Io,
    instances: []const lock_model.NpmInstance,
    cache_root: ?[]const u8,
) Error!Prepared {
    if (instances.len == 0) return error.BareNotFound;
    // registry は name 単位でしか解決できない。同一 name の複数 instance を
    // 先着順に黙って選ぶと別 context の版を混同し得るため fail-closed。
    var by_name: std.StringHashMapUnmanaged(usize) = .empty;
    errdefer by_name.deinit(gpa);
    for (instances, 0..) |instance, index| {
        const entry = try by_name.getOrPut(gpa, instance.name);
        if (entry.found_existing) return error.AmbiguousInstances;
        entry.value_ptr.* = index;
    }
    const root = if (cache_root) |explicit|
        try gpa.dupe(u8, explicit)
    else
        (try cache_mod.defaultRoot(gpa)) orelse return error.CacheMiss;
    defer gpa.free(root);

    var scratch = createScratch(gpa, io) catch |err| return mapScratchIo(err);
    errdefer scratch.deinit();

    var store = cache_mod.Store.open(gpa, io, root) catch |err| return mapCacheOpenIo(err);
    errdefer store.deinit();

    var registry = npm_esm.BareRegistry{ .gpa = gpa, .io = io };
    errdefer registry.deinit();
    return .{
        .gpa = gpa,
        .io = io,
        .instances = instances,
        .by_name = by_name,
        .scratch = scratch,
        .store = store,
        .registry = registry,
    };
}

fn classifyExtraction(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.InvalidArchive => error.InvalidArchive,
        else => error.CacheMiss,
    };
}

fn isStickyFailure(err: anyerror) bool {
    // 環境レベルの失敗だけを sticky にする。instance 単位の CacheMiss /
    // InvalidArchive は別 name の解決を妨げない（Prepared.failed が再展開を防ぐ）。
    return switch (err) {
        error.CacheUnavailable, error.ScratchUnavailable => true,
        else => false,
    };
}

fn mapScratchIo(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        // TMPDIR 不在・権限不足・一意名の枯渇。cache miss とは原因が異なる。
        else => error.ScratchUnavailable,
    };
}

fn mapCacheOpenIo(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.CacheUnavailable,
    };
}

/// TMPDIR（Windows は TEMP/TMP）配下に一意な scratch dir を作り、canonical
/// path を保持して返す。作成に失敗した場合、部分的な生成物は残さない。
fn createScratch(gpa: Allocator, io: std.Io) !Scratch {
    const base = (try tempBase(gpa)) orelse return error.FileSystem;
    defer gpa.free(base);

    var parent = try std.Io.Dir.openDirAbsolute(io, base, .{ .iterate = true });
    errdefer parent.close(io);

    var attempt: usize = 0;
    var name: ?[]u8 = null;
    while (attempt < 8) : (attempt += 1) {
        var random: [8]u8 = undefined;
        std.Io.random(io, &random);
        const hex = std.fmt.bytesToHex(random, .lower);
        var buf: [32]u8 = undefined;
        const candidate = try std.fmt.bufPrint(&buf, "lnako-npm-{s}", .{hex});
        parent.createDir(io, candidate, scratch_permissions) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        name = gpa.dupe(u8, candidate) catch |err| {
            environment.deleteTreeChecked(parent, io, candidate) catch {};
            return err;
        };
        break;
    }
    const owned_name = name orelse return error.PathAlreadyExists;
    errdefer gpa.free(owned_name);

    var dir = parent.openDir(io, owned_name, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
        environment.deleteTreeChecked(parent, io, owned_name) catch {};
        return err;
    };
    errdefer {
        dir.close(io);
        environment.deleteTreeChecked(parent, io, owned_name) catch {};
    }

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try dir.realPath(io, &path_buffer);
    const owned_path = try gpa.dupe(u8, path_buffer[0..path_len]);
    return .{
        .gpa = gpa,
        .io = io,
        .parent = parent,
        .dir = dir,
        .name = owned_name,
        .path = owned_path,
    };
}

fn tempBase(gpa: Allocator) Allocator.Error!?[]u8 {
    for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |name| {
        const value = (try fetch.envVar(gpa, name)) orelse continue;
        // `openDirAbsolute` は絶対 path を要求する。相対値を設定した環境で
        // assert させないよう、絶対 path だけを採用する。
        if (value.len != 0 and std.fs.path.isAbsolute(value)) return value;
        gpa.free(value);
    }
    if (builtin.os.tag == .windows) {
        // 環境変数が壊れていても、少なくとも per-user temp へフォールバックする。
        const profile = (try fetch.envVar(gpa, "USERPROFILE")) orelse return null;
        defer gpa.free(profile);
        if (!std.fs.path.isAbsolute(profile)) return null;
        return try std.fs.path.join(gpa, &.{ profile, "AppData", "Local", "Temp" });
    }
    return try gpa.dupe(u8, "/tmp");
}

/// cache key を scratch の単一 dir 名として使えるか。`cache.Store` の key
/// 規則（英数・`-`・`_`・`.`、128 byte 以下）より狭く、`.`/`..` と path
/// separator を明示的に拒否する。
fn isSafeCacheKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 128) return false;
    if (std.mem.eql(u8, key, ".") or std.mem.eql(u8, key, "..")) return false;
    for (key) |byte| {
        if (byte == '/' or byte == '\\' or byte == 0) return false;
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_sandbox = @import("test_sandbox.zig");

test "Prepared は要求された instance を cache から展開しサブパスを解決する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");

    const tarball = try buildTarGz(gpa, &.{
        .{ .path = "package/package.json", .content = "{\"exports\":{\".\":\"./index.js\",\"./sub\":\"./sub.js\"}}" },
        .{ .path = "package/index.js", .content = "export default 1;\n" },
        .{ .path = "package/sub.js", .content = "export default 2;\n" },
    });
    defer gpa.free(tarball);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tarball, &digest, .{});
    const sha256 = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer gpa.free(sha256);

    const url = "fixture://left-pad-1.0.0.tgz";
    const instance = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = try gpa.dupe(u8, sha256),
        .url = try gpa.dupe(u8, url),
    };
    defer {
        gpa.free(instance.sha256.?);
        gpa.free(instance.url.?);
    }

    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);
    var store = try cache_mod.Store.open(gpa, io, cache_root);
    defer store.deinit();
    const key = (try npm_esm.cacheKeyForInstance(gpa, instance)).?;
    defer gpa.free(key);
    try npm_esm.publishNpmTree(gpa, io, &store, key, tarball);

    var prepared = try prepare(gpa, io, &.{instance}, cache_root);
    var alive = true;
    defer if (alive) prepared.deinit();
    const scratch_path = try gpa.dupe(u8, prepared.scratch.path);
    defer gpa.free(scratch_path);
    const root = try prepared.resolveBare("left-pad");
    defer root.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, root.path, "index.js"));
    const sub = try prepared.resolveBare("left-pad/sub");
    defer sub.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, sub.path, "sub.js"));
    // deinit は scratch tree を残さない（TMPDIR の蓄積防止）。
    prepared.deinit();
    alive = false;
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, scratch_path, .{}));
}

test "Prepared は要求された instance の cache 欠落を fail-closed にする" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "empty-cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "empty-cache", gpa);
    defer gpa.free(cache_root);

    const instance = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .url = "fixture://left-pad-1.0.0.tgz",
    };
    var prepared = try prepare(gpa, io, &.{instance}, cache_root);
    defer prepared.deinit();
    try testing.expectError(error.CacheMiss, prepared.resolveBare("left-pad"));
}

test "Prepared は lock の sha256 と一致しない cache archive を拒否する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");

    const good = try buildTarGz(gpa, &.{
        .{ .path = "package/package.json", .content = "{\"exports\":{\".\":\"./index.js\"}}" },
        .{ .path = "package/index.js", .content = "export default 1;\n" },
    });
    defer gpa.free(good);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(good, &digest, .{});
    const sha256 = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer gpa.free(sha256);
    const instance = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = sha256,
        .url = "fixture://left-pad-1.0.0.tgz",
    };

    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);
    var store = try cache_mod.Store.open(gpa, io, cache_root);
    defer store.deinit();
    const key = (try npm_esm.cacheKeyForInstance(gpa, instance)).?;
    defer gpa.free(key);
    // 同じ content key に別 bytes を公開する（cache 改ざん相当）。
    try npm_esm.publishNpmTree(gpa, io, &store, key, "tampered-tarball");

    var prepared = try prepare(gpa, io, &.{instance}, cache_root);
    defer prepared.deinit();
    try testing.expectError(error.CacheMiss, prepared.resolveBare("left-pad"));
}

test "prepare は同一 name の複数 instance を AmbiguousInstances で拒否する" {
    const a = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .url = "fixture://left-pad-1.0.0.tgz",
    };
    const b = lock_model.NpmInstance{
        .key = "left-pad@2.0.0",
        .name = "left-pad",
        .version = "2.0.0",
        .sha256 = "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        .url = "fixture://left-pad-2.0.0.tgz",
    };
    try testing.expectError(error.AmbiguousInstances, prepare(testing.allocator, testing.io, &.{ a, b }, "/nonexistent"));
}

test "無関係な instance の cache 欠落は要求された package の解決を止めない" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");

    const tarball = try buildTarGz(gpa, &.{
        .{ .path = "package/package.json", .content = "{\"exports\":{\".\":\"./index.js\"}}" },
        .{ .path = "package/index.js", .content = "export default 1;\n" },
    });
    defer gpa.free(tarball);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tarball, &digest, .{});
    const sha256 = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer gpa.free(sha256);
    const cached = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = sha256,
        .url = "fixture://left-pad-1.0.0.tgz",
    };
    const missing = lock_model.NpmInstance{
        .key = "missing@1.0.0",
        .name = "missing",
        .version = "1.0.0",
        .sha256 = "sha256:2222222222222222222222222222222222222222222222222222222222222222",
        .url = "fixture://missing-1.0.0.tgz",
    };

    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);
    var store = try cache_mod.Store.open(gpa, io, cache_root);
    defer store.deinit();
    const key = (try npm_esm.cacheKeyForInstance(gpa, cached)).?;
    defer gpa.free(key);
    try npm_esm.publishNpmTree(gpa, io, &store, key, tarball);

    var prepared = try prepare(gpa, io, &.{ cached, missing }, cache_root);
    defer prepared.deinit();
    // cache 済みの left-pad は、無関係な missing の欠落に影響されない。
    const entry = try prepared.resolveBare("left-pad");
    defer entry.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, entry.path, "index.js"));
    try testing.expectError(error.CacheMiss, prepared.resolveBare("missing"));
}

test "State は最初の失敗を保持し、再試行しない" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "empty-cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "empty-cache", gpa);
    defer gpa.free(cache_root);

    const instance = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .url = "fixture://left-pad-1.0.0.tgz",
    };
    var state = State{
        .io = io,
        .backing_allocator = gpa,
        .instances = &.{instance},
        .cache_root = cache_root,
    };
    defer state.deinit();
    try testing.expectError(error.CacheMiss, state.resolveBare(gpa, "left-pad"));
    // 2 回目は再構築せず、最初の失敗分類をそのまま返す。
    try testing.expectError(error.CacheMiss, state.resolveBare(gpa, "left-pad"));
}

test "State は無関係な instance の CacheMiss 後も cache 済み package を解決する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");

    const tarball = try buildTarGz(gpa, &.{
        .{ .path = "package/package.json", .content = "{\"exports\":{\".\":\"./index.js\"}}" },
        .{ .path = "package/index.js", .content = "export default 1;\n" },
    });
    defer gpa.free(tarball);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tarball, &digest, .{});
    const sha256 = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer gpa.free(sha256);
    const cached = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = sha256,
        .url = "fixture://left-pad-1.0.0.tgz",
    };
    const missing = lock_model.NpmInstance{
        .key = "aaa-missing@1.0.0",
        .name = "aaa-missing",
        .version = "1.0.0",
        .sha256 = "sha256:3333333333333333333333333333333333333333333333333333333333333333",
        .url = "fixture://aaa-missing-1.0.0.tgz",
    };

    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);
    var store = try cache_mod.Store.open(gpa, io, cache_root);
    defer store.deinit();
    const key = (try npm_esm.cacheKeyForInstance(gpa, cached)).?;
    defer gpa.free(key);
    try npm_esm.publishNpmTree(gpa, io, &store, key, tarball);

    var state = State{
        .io = io,
        .backing_allocator = gpa,
        .instances = &.{ missing, cached },
        .cache_root = cache_root,
    };
    defer state.deinit();
    // 欠落 instance を先に解決しても、sticky にせず別 name は解決できる。
    try testing.expectError(error.CacheMiss, state.resolveBare(gpa, "aaa-missing"));
    const entry = try state.resolveBare(gpa, "left-pad");
    defer entry.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, entry.path, "index.js"));
}

test "非 gzip fixture は blob として展開され入口解決は BareNotFound になる" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");

    const bytes = "not-a-tarball";
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const sha256 = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer gpa.free(sha256);
    const instance = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = sha256,
        .url = "fixture://left-pad-1.0.0.tgz",
    };

    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);
    var store = try cache_mod.Store.open(gpa, io, cache_root);
    defer store.deinit();
    const key = (try npm_esm.cacheKeyForInstance(gpa, instance)).?;
    defer gpa.free(key);
    try npm_esm.publishNpmTree(gpa, io, &store, key, bytes);
    var state = State{
        .io = io,
        .backing_allocator = gpa,
        .instances = &.{instance},
        .cache_root = cache_root,
    };
    defer state.deinit();
    // package.json が無いため root 入口は公開されない（安全側）。
    try testing.expectError(error.BareNotFound, state.resolveBare(gpa, "left-pad"));
}

/// tar entry を gzip 圧縮した byte 列を作る（`provider_test.zig` と同じ手法）。
fn buildTarGz(gpa: Allocator, files: []const struct { path: []const u8, content: []const u8 }) ![]u8 {
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
