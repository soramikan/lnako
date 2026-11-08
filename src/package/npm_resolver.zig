//! lock `npmInstances` と cache から `npm_esm.BareRegistry` を構築する（#54）。
//!
//! - network・Node・npm CLI は使わない。cache に lock の `sha256` と一致する
//!   tarball が無ければ `CacheMiss` で fail-closed。
//! - registry は bare name 単位。同一 name の複数 instance（lock context 別）は
//!   誤った版を黙って選ばないよう `AmbiguousInstances` で失敗する。
//! - package 環境が公開済み世代（`.nako/env/<gen>`）を持つ場合、sync が
//!   materialize した `<gen>/deps/npm_<instance>` を優先して使う（#54 env
//!   materialize 連携）。tree 直下の provenance marker が lock の `sha256` と
//!   一致する時だけ再利用し、cache の再検証・scratch への再展開を行わない。
//!   marker が無い・古い・不一致なら下記の cache 経路へ fallback する。
//! - cache の派生 `tree/` は entry marker の自己認証に過ぎず、lock 束縛を
//!   証明しない（`npm_env.zig` と同じ方針）。lock の `sha256` で raw archive
//!   を検証し、その bytes から private scratch へ tree を作り直す。
//! - scratch は TMPDIR 配下の一意 dir。`Prepared.deinit` で再帰削除する。
//!   path は realpath 化して保持する（`module_graph` の package 境界検査は
//!   canonical path 同士の比較のため）。世代 tree は環境の所有物なので
//!   `Prepared.deinit` では削除しない。
//! - scratch の寿命は compile 中のみ。IR/Program へは module source が dupe
//!   されるため、compile 後に npm 由来 module の path を開き直さない契約。
//! - instance の展開は bare name が要求されたときだけ行う。無関係な
//!   instance の cache 欠落で、cache 済みの package の解決を止めない。
//! - 信頼境界: 世代 tree は sync が lock の `sha256` で検証した archive から
//!   materialize した環境スナップショットで、environment.json の
//!   `lockSha256` が lock と世代を束縛する。compile は nako package source と
//!   同じく公開世代を信頼し、tree 内容の digest は再計算しない（cache archive
//!   を再読すると「再展開を避ける」という本連携の目的と矛盾する）。
//!   provenance marker は sync 由来の識別子（lock instance の sha256）で
//!   あって暗号的な内容完全性の証明ではない。書き込み可能性は
//!   `import_resolver` が package tree と同じ `project_trust` の ACL 検査で
//!   enforce する。
//!
//! cache key と instance の対応は `npm_esm.cacheKeyForInstance`、instance の
//! 登録は `npm_esm.BareRegistry.registerInstance`、世代 tree の path と
//! provenance は `npm_env` の helper を再利用する（導出の二重実装をしない）。
//! `buildFromInstances` は npm_esm 自身のテスト用に残る。

const std = @import("std");
const builtin = @import("builtin");
const cache_mod = @import("cache.zig");
const environment = @import("environment.zig");
const fetch = @import("fetch.zig");
const lock_model = @import("lock_model.zig");
const npm_env = @import("npm_env.zig");
const npm_esm = @import("npm_esm.zig");
const package_json_mod = @import("package_json.zig");
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

/// scratch dir 名の前置。scratch は `<base>/lnako-npm-<hex>` に作られるため、
/// 所属判定（テスト含む）はこの定義を単一の源として path component を照合する。
pub const scratch_dir_prefix = "lnako-npm-";
/// scratch dir 名の hex 部分の長さ（`createScratch` の 8 byte random を小文字
/// hex 化した長さ）。判定側が名前の形を検証する時の単一の源。
pub const scratch_dir_hex_len: usize = scratch_random_bytes * 2;
/// scratch dir 名に使う乱数 byte 数。
const scratch_random_bytes = 8;

/// 世代 tree の identity 検査で読む `package.json` の上限。
const max_package_json_bytes: usize = 1024 * 1024;

pub const Error = error{ CacheMiss, InvalidArchive, AmbiguousInstances, BareNotFound, Canceled, CacheUnavailable, ScratchUnavailable, OutOfMemory };

/// 遅延構築する npm registry。bare name が要求された instance だけを展開・
/// 登録し、cache store と scratch は cache 経路へ fallback した時だけ遅延生成
/// する（世代 tree だけで完結する場合は cache dir・TMPDIR を触らない）。
pub const Prepared = struct {
    gpa: Allocator,
    io: std.Io,
    instances: []const lock_model.NpmInstance,
    /// 公開済み環境の `<gen>/deps` dir ハンドル。import_resolver が
    /// project→`.nako`→`env`→`<gen>`→`deps` を各段 no-follow で開いて固定し、
    /// tree の特定・検証もこのハンドル相対で行う（load 直後の中間 path
    /// 差し替えに左右されない）。返却後の module 読みは package source と
    /// 同じ path 解決で、load 時の ACL 検査と project 所有権を信頼する。
    /// null なら世代 tree を使わず cache だけから構築する。所有は State。
    generation_deps: ?std.Io.Dir = null,
    /// cache 展開へ fallback した時だけ開く root（呼出し側所有）。null は
    /// OS 標準 cache dir。
    cache_root: ?[]const u8 = null,
    by_name: std.StringHashMapUnmanaged(usize) = .empty,
    /// 世代 tree で解決できない instance を cache から展開する時だけ作る。
    scratch: ?Scratch = null,
    store: ?cache_mod.Store = null,
    registry: npm_esm.BareRegistry,
    extracted: std.StringHashMapUnmanaged(void) = .empty,
    /// name 単位の展開失敗（同一 name の再展開 I/O を避ける）。
    failed: std.StringHashMapUnmanaged(Error) = .empty,

    pub fn deinit(self: *Prepared) void {
        // generation_deps は State 所有。ここでは閉じない（二重 close 防止）。
        var failed_it = self.failed.iterator();
        while (failed_it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.failed.deinit(self.gpa);
        var extracted_it = self.extracted.iterator();
        while (extracted_it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.extracted.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
        self.registry.deinit();
        if (self.store) |*store| store.deinit();
        if (self.scratch) |*scratch| scratch.deinit();
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
    /// へ展開し、tree root path を返す（呼出し側が free する）。公開済み世代の
    /// materialize 済み tree を再利用できる場合は cache を読まずにその path を
    /// 返す。
    fn extractInstance(self: *Prepared, instance: lock_model.NpmInstance) anyerror![]u8 {
        if (try self.reusedGenerationTree(instance)) |tree| return tree;
        const key = (try npm_esm.cacheKeyForInstance(self.gpa, instance)) orelse return error.CacheMiss;
        defer self.gpa.free(key);
        // scratch の dir 名に使うため、単一の規範 path 成分であることを検証する
        // （cache key は hash 由来だが、lock 材料が変わっても書き込み面を守る）。
        if (!isSafeCacheKey(key)) return error.CacheMiss;
        const sha256 = instance.sha256 orelse return error.CacheMiss;
        // 既に scratch へ展開済みの key は archive を読み直さない。
        if (self.extracted.contains(key)) {
            const scratch = self.scratch orelse return error.CacheMiss;
            return try std.fs.path.join(self.gpa, &.{ scratch.path, key });
        }
        // ここから先だけが cache/scratch を必要とする（世代 tree だけで解決
        // できた場合は TMPDIR も cache dir も触らない）。
        const store = try self.ensureStore();
        const bytes = (store.readVerifiedSourceArchive(self.gpa, key, sha256) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CacheMiss,
        }) orelse return error.CacheMiss;
        defer self.gpa.free(bytes);
        const scratch = try self.ensureScratch();

        // 同一 key は `extracted` で早期 return するため、ここで既存 dir が
        // あるのは想定外（同一ユーザーの競合・残骸）。内容を検証できない dir を
        // package root として使わないよう fail-closed。
        scratch.dir.createDir(self.io, key, scratch_permissions) catch |err| switch (err) {
            error.PathAlreadyExists => return error.CacheMiss,
            else => return err,
        };
        // 展開・書き込み・map 登録の途中で OOM/Canceled 等が起きても、
        // 空の `<key>` dir を残さない。残すと再要求時に createDir が
        // PathAlreadyExists となり、元の失敗が CacheMiss に化ける。
        errdefer scratch.dir.deleteTree(self.io, key) catch {};
        {
            var tree = scratch.dir.openDir(self.io, key, .{ .iterate = true, .follow_symlinks = false }) catch |err| return err;
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
        const tree_path = try std.fs.path.join(self.gpa, &.{ scratch.path, key });
        errdefer self.gpa.free(tree_path);
        try self.extracted.put(self.gpa, key_copy, {});
        return tree_path;
    }

    /// cache store を必要になった時だけ開く（世代 tree だけで解決できる
    /// compile は cache dir の存在・TMPDIR に依存しない）。
    fn ensureStore(self: *Prepared) Error!*cache_mod.Store {
        if (self.store == null) {
            const root = if (self.cache_root) |explicit|
                explicit
            else
                (cache_mod.defaultRoot(self.gpa) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                }) orelse return error.CacheUnavailable;
            defer if (self.cache_root == null) self.gpa.free(root);
            self.store = cache_mod.Store.open(self.gpa, self.io, root) catch |err| return mapCacheOpenIo(err);
        }
        return &self.store.?;
    }

    /// 展開用 scratch を必要になった時だけ作る。
    fn ensureScratch(self: *Prepared) Error!*Scratch {
        if (self.scratch == null) self.scratch = createScratch(self.gpa, self.io) catch |err| return mapScratchIo(err);
        return &self.scratch.?;
    }

    /// 公開済み世代 `.nako/env/<gen>` の materialize 済み tree
    /// （`<gen>/deps/npm_<instance>`）を再利用できるなら canonical path を
    /// 返す。次の条件を全て満たす時だけ使い、満たさなければ null（cache
    /// 経路へ fallback）にする:
    /// - 世代 dir → `deps` → instance dir を各成分 no-follow で開ける
    ///   （lexical path の一括 open は中間 symlink を追従し、検証後に世代外
    ///   へ差し替えられ得るため）
    /// - provenance marker が lock の `sha256` と一致する
    /// - `package.json` の name/version が lock instance と一致する
    /// - realpath が世代 root の実体配下に留まる
    ///
    /// marker は「sync が lock の sha256 で検証した archive から materialize
    /// した tree である」ことの識別子で、内容の暗号的な完全性証明ではない。
    /// 世代の内容は environment.json の lockSha256 と、package source と
    /// 同じ project_trust の ACL 検査（import_resolver）で信頼する。
    fn reusedGenerationTree(self: *Prepared, instance: lock_model.NpmInstance) Error!?[]u8 {
        const deps = self.generation_deps orelse return null;
        const dir_name = npm_env.instanceDirName(self.gpa, instance) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer self.gpa.free(dir_name);
        // 固定済み `deps` ハンドル相対で instance dir を no-follow で開く。
        var tree = (try self.openRealDir(deps, dir_name)) orelse return null;
        defer tree.close(self.io);

        const marker = tree.readFileAlloc(self.io, npm_env.provenance_file, self.gpa, .limited(npm_env.max_provenance_bytes)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Canceled) return error.Canceled;
            return null;
        };
        defer self.gpa.free(marker);
        if (!npm_env.provenanceMatches(instance, marker)) return null;
        if (!try self.treeMatchesInstance(tree, instance)) return null;

        // package 境界検査は canonical path 同士の比較なので realpath を返す。
        // deps の実体配下に留まることも再確認する（reparse point 対策）。
        var deps_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const deps_length = deps.realPath(self.io, &deps_buffer) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Canceled) return error.Canceled;
            return null;
        };
        var tree_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const tree_length = tree.realPath(self.io, &tree_buffer) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Canceled) return error.Canceled;
            return null;
        };
        if (!npm_env.isStrictlyWithin(deps_buffer[0..deps_length], tree_buffer[0..tree_length])) return null;
        return try self.gpa.dupe(u8, tree_buffer[0..tree_length]);
    }

    /// `parent` 相対で 1 成分を no-follow で開き、実 directory
    /// の時だけ返す。symlink/reparse point・不在・通常 file は null。
    /// OOM/Canceled は fallback せず呼出し側へ伝播する。
    fn openRealDir(self: *Prepared, parent: std.Io.Dir, name: []const u8) Error!?std.Io.Dir {
        var dir = parent.openDir(self.io, name, .{ .follow_symlinks = false }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Canceled) return error.Canceled;
            return null;
        };
        const stat = dir.stat(self.io) catch |err| {
            dir.close(self.io);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Canceled) return error.Canceled;
            return null;
        };
        if (stat.kind != .directory) {
            dir.close(self.io);
            return null;
        }
        return dir;
    }

    /// 世代 tree の `package.json` が lock instance の name/version と一致する
    /// か。世代 tree が別 instance の残骸でないことを確認する（内容そのものの
    /// 完全性は marker と ACL 検査の信頼境界に委ねる）。
    fn treeMatchesInstance(self: *Prepared, tree: std.Io.Dir, instance: lock_model.NpmInstance) Error!bool {
        const bytes = tree.readFileAlloc(self.io, "package.json", self.gpa, .limited(max_package_json_bytes)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Canceled) return error.Canceled;
            return false;
        };
        defer self.gpa.free(bytes);
        // package.json の読み取り規則は `package_json.zig` に集約する
        // （BOM 受理・重複キー後勝ち・name/type の型検査）。identity は
        // name/version の組だけを照合する。name/type が非文字列の package.json
        // は Node 準拠で不正扱いになるため identity 不一致（= cache へ
        // fallback）になる。
        var manifest = package_json_mod.parse(self.gpa, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PackageJsonInvalid => return false,
        };
        defer manifest.deinit();
        const name = manifest.name orelse return false;
        const version = manifest.version orelse return false;
        return std.mem.eql(u8, name, instance.name) and std.mem.eql(u8, version, instance.version);
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
    /// 公開済み環境の `<gen>/deps` dir ハンドル。State が所有し deinit で閉じる。
    /// null なら世代 tree を使わず cache 経路のみ。
    generation_deps: ?std.Io.Dir = null,
    prepared: ?Prepared = null,
    /// prepare（registry 構築・lock 名の曖昧さ等）の失敗を記憶し、以後の
    /// import で再試行しない。cache/scratch の不備を含む instance 単位の
    /// 失敗は `Prepared.failed` が失敗した name に限定して保持する
    /// （無関係な name が有効な generation tree を失わない）。
    failure: ?anyerror = null,

    /// lock の選択 profile から `npmInstances` を取り込む。`lock_root` は
    /// Resolver の arena に載っている parsed lock。`storage` は Resolver の
    /// arena（instance 文字列の寿命）、`backing_allocator` は registry/scratch
    /// 用の実 allocator（archive bytes を都度 free できる）を渡す。
    /// `generation_deps` は公開済み環境の `<gen>/deps` dir ハンドル。成功時は
    /// State が所有し deinit で閉じる。失敗時は所有権が移らないため呼出し側が
    /// 閉じる。null は世代非依存の環境。
    pub fn load(
        storage: Allocator,
        backing_allocator: Allocator,
        io: std.Io,
        lock_root: std.json.ObjectMap,
        profile: []const u8,
        cache_root: ?[]const u8,
        generation_deps: ?std.Io.Dir,
    ) !State {
        return .{
            .io = io,
            .backing_allocator = backing_allocator,
            .instances = try collectInstances(storage, lock_root, profile),
            .cache_root = if (cache_root) |explicit| try storage.dupe(u8, explicit) else null,
            .generation_deps = generation_deps,
        };
    }

    pub fn deinit(self: *State) void {
        if (self.prepared) |*prepared| prepared.deinit();
        if (self.generation_deps) |dir| dir.close(self.io);
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
            self.prepared = prepare(self.backing_allocator, self.io, self.instances, self.cache_root, self.generation_deps) catch |err| {
                // 失敗した compile 中で scratch/cache の再構築を繰り返さない。
                self.failure = err;
                return err;
            };
        }
        // 解決不能のうち name 単位の展開失敗（CacheMiss/InvalidArchive/
        // CacheUnavailable/ScratchUnavailable）は、要求された name に閉じた
        // 失敗として `Prepared.failed` が保持する（BareNotFound は決定的で
        // 安価なため保持しない）。State 全体へ集約すると、別 name が有効な
        // generation tree を持っていても解決できなくなるため、ここでは伝播
        // だけ行う。
        const entry = try self.prepared.?.resolveBare(specifier);
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

/// 選択 profile の lock package が非空の `npmInstances` を持つか。
pub fn hasNpmInstances(lock_root: std.json.ObjectMap, profile: []const u8) bool {
    const selected = selectLockedPackages(lock_root, profile) catch return false;
    const packages = asObject(selected) orelse return false;
    var iterator = packages.iterator();
    while (iterator.next()) |entry| {
        const package = asObject(entry.value_ptr.*) orelse continue;
        const instances_value = get(package, "npmInstances") orelse continue;
        const instances = asObject(instances_value) orelse continue;
        if (instances.count() > 0) return true;
    }
    return false;
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

/// `instances` の name 索引を用意する。instance の展開は最初にその name が
/// 要求されたときに行い、世代 tree で解決できなければ cache store と scratch
/// をその時点で遅延生成する（世代 tree だけで完結する compile は cache dir・
/// TMPDIR に依存しない）。`cache_root == null` は OS 標準 cache dir。
/// `generation_deps` は公開済み環境の `<gen>/deps` dir ハンドル（呼出し側
/// 所有。State 経由では State.deinit、直接 prepare するテストでは呼出し側が
/// close する）。与えられた場合、その配下の materialize 済み tree を優先する。
/// `cache_root` は本 Prepared の寿命中有効であること（borrow）。
pub fn prepare(
    gpa: Allocator,
    io: std.Io,
    instances: []const lock_model.NpmInstance,
    cache_root: ?[]const u8,
    generation_deps: ?std.Io.Dir,
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
    var registry = npm_esm.BareRegistry{ .gpa = gpa, .io = io };
    errdefer registry.deinit();
    return .{
        .gpa = gpa,
        .io = io,
        .instances = instances,
        .generation_deps = generation_deps,
        .cache_root = cache_root,
        .by_name = by_name,
        .registry = registry,
    };
}

fn classifyExtraction(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.InvalidArchive => error.InvalidArchive,
        // 環境レベル（cache dir/scratch を作れない）失敗も name 単位で保持し、
        // 別 name の解決（世代 tree 等）を妨げない。
        error.CacheUnavailable => error.CacheUnavailable,
        error.ScratchUnavailable => error.ScratchUnavailable,
        else => error.CacheMiss,
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
        var random: [scratch_random_bytes]u8 = undefined;
        std.Io.random(io, &random);
        const hex = std.fmt.bytesToHex(random, .lower);
        var buf: [32]u8 = undefined;
        const candidate = try std.fmt.bufPrint(&buf, "{s}{s}", .{ scratch_dir_prefix, hex });
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

/// scratch の基点（TMPDIR→TEMP→TMP、Windows は USERPROFILE 配下）の
/// canonical 絶対 path を返す。scratch dir 自体は常に
/// `<base>/lnako-npm-<hex>` なので、呼出し側はこの path 境界で module が
/// scratch 由来かを判定できる（基点名の部分文字列に依存しない）。基点を
/// canonical path として開けない環境では null を返す。
pub fn scratchBaseReal(allocator: Allocator, io: std.Io) !?[]u8 {
    const base = (try tempBase(allocator)) orelse return null;
    defer allocator.free(base);
    var dir = std.Io.Dir.openDirAbsolute(io, base, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        return null;
    };
    defer dir.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = dir.realPath(io, &buffer) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        return null;
    };
    return try allocator.dupe(u8, buffer[0..length]);
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

    var prepared = try prepare(gpa, io, &.{instance}, cache_root, null);
    var alive = true;
    defer if (alive) prepared.deinit();
    const root = try prepared.resolveBare("left-pad");
    defer root.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, root.path, "index.js"));
    const sub = try prepared.resolveBare("left-pad/sub");
    defer sub.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, sub.path, "sub.js"));
    // cache 展開時だけ scratch が作られる。
    const scratch_path = try gpa.dupe(u8, prepared.scratch.?.path);
    defer gpa.free(scratch_path);
    // deinit は scratch tree を残さない（TMPDIR の蓄積防止）。
    prepared.deinit();
    alive = false;
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, scratch_path, .{}));
}

test "classifyExtraction は環境レベル失敗を CacheMiss に潰さない" {
    try testing.expectEqual(@as(Error, error.CacheUnavailable), classifyExtraction(error.CacheUnavailable));
    try testing.expectEqual(@as(Error, error.ScratchUnavailable), classifyExtraction(error.ScratchUnavailable));
    try testing.expectEqual(@as(Error, error.InvalidArchive), classifyExtraction(error.InvalidArchive));
    try testing.expectEqual(@as(Error, error.CacheMiss), classifyExtraction(error.FileNotFound));
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
    var prepared = try prepare(gpa, io, &.{instance}, cache_root, null);
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

    var prepared = try prepare(gpa, io, &.{instance}, cache_root, null);
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
    try testing.expectError(error.AmbiguousInstances, prepare(testing.allocator, testing.io, &.{ a, b }, "/nonexistent", null));
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

    var prepared = try prepare(gpa, io, &.{ cached, missing }, cache_root, null);
    defer prepared.deinit();
    // cache 済みの left-pad は、無関係な missing の欠落に影響されない。
    const entry = try prepared.resolveBare("left-pad");
    defer entry.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, entry.path, "index.js"));
    try testing.expectError(error.CacheMiss, prepared.resolveBare("missing"));
}

test "State は name 単位の失敗を Prepared.failed で保持し、再試行しない" {
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

test "State は cache 不備を name 単位に留め、後続 name の世代 tree を解決する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    // cache root は通常 file。Store を開けないため cache 経路は
    // CacheUnavailable になる。
    try temporary.dir.writeFile(io, .{ .sub_path = "not-a-dir", .data = "not a cache dir" });
    const cache_root = try temporary.dir.realPathFileAlloc(io, "not-a-dir", gpa);
    defer gpa.free(cache_root);
    try temporary.dir.createDirPath(io, "env/gen-test");
    const generation_root = try temporary.dir.realPathFileAlloc(io, "env/gen-test", gpa);
    defer gpa.free(generation_root);

    // cache が必要な name（世代 tree なし）と、有効な世代 tree を持つ name。
    const needs_cache = lock_model.NpmInstance{
        .key = "aaa-needs-cache@1.0.0",
        .name = "aaa-needs-cache",
        .version = "1.0.0",
        .sha256 = "sha256:4444444444444444444444444444444444444444444444444444444444444444",
        .url = "fixture://aaa-needs-cache-1.0.0.tgz",
    };
    const from_generation = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .url = "fixture://left-pad-1.0.0.tgz",
    };
    const marker = try npm_env.provenanceText(gpa, from_generation);
    defer gpa.free(marker);
    const tree = try writeGenerationTree(gpa, io, generation_root, from_generation, marker);
    defer gpa.free(tree);

    // generation_deps の所有権は State へ移す（State.deinit が閉じる）。
    var state = State{
        .io = io,
        .backing_allocator = gpa,
        .instances = &.{ needs_cache, from_generation },
        .cache_root = cache_root,
        .generation_deps = try openDepsDir(io, generation_root),
    };
    defer state.deinit();
    // 先行 name の cache 不備を State 全体の失敗に集約しない。
    try testing.expectError(error.CacheUnavailable, state.resolveBare(gpa, "aaa-needs-cache"));
    // 後続 name は cache を触らず、有効な世代 tree から解決できる。
    const entry = try state.resolveBare(gpa, "left-pad");
    defer entry.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, entry.path, "index.js"));
    try testing.expect(npm_env.isStrictlyWithin(generation_root, entry.path));
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

/// 世代 tree（`<generation_root>/deps/<dir>`）と package 一式・provenance
/// marker を作る。tree の絶対 path を返す（呼出し側が free する）。
fn writeGenerationTree(
    gpa: Allocator,
    io: std.Io,
    generation_root: []const u8,
    instance: lock_model.NpmInstance,
    marker: []const u8,
) ![]u8 {
    const tree = try npm_env.instanceTreePath(gpa, generation_root, instance);
    errdefer gpa.free(tree);
    try std.Io.Dir.cwd().createDirPath(io, tree);
    var dir = try std.Io.Dir.cwd().openDir(io, tree, .{ .iterate = true });
    defer dir.close(io);
    // lock instance の identity 検査（name/version）を通すため package.json に
    // 同じ name/version を書く。
    const package_json = try std.fmt.allocPrint(
        gpa,
        "{{\"name\":\"{s}\",\"version\":\"{s}\",\"exports\":{{\".\":\"./index.js\",\"./sub\":\"./sub.js\"}}}}",
        .{ instance.name, instance.version },
    );
    defer gpa.free(package_json);
    try dir.writeFile(io, .{ .sub_path = "package.json", .data = package_json });
    try dir.writeFile(io, .{ .sub_path = "index.js", .data = "export default 1;\n" });
    try dir.writeFile(io, .{ .sub_path = "sub.js", .data = "export default 2;\n" });
    // marker が空の場合は marker なし tree（旧世代相当）を再現する。
    if (marker.len != 0) try dir.writeFile(io, .{ .sub_path = npm_env.provenance_file, .data = marker });
    return tree;
}

/// 世代 dir の `deps` ハンドルを開く（prepare へ渡す固定ハンドル）。
fn openDepsDir(io: std.Io, generation_root: []const u8) !std.Io.Dir {
    var generation = try std.Io.Dir.cwd().openDir(io, generation_root, .{});
    defer generation.close(io);
    return try generation.openDir(io, "deps", .{ .iterate = true });
}

test "Prepared は世代 materialize 済み tree を cache/scratch の再展開なしで再利用する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    // cache は空。世代 tree だけが lock の sha256 を満たす。
    try temporary.dir.createDirPath(io, "empty-cache");
    try temporary.dir.createDirPath(io, "env/gen-test");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "empty-cache", gpa);
    defer gpa.free(cache_root);
    const generation_root = try temporary.dir.realPathFileAlloc(io, "env/gen-test", gpa);
    defer gpa.free(generation_root);

    const instance = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .url = "fixture://left-pad-1.0.0.tgz",
    };
    const marker = try npm_env.provenanceText(gpa, instance);
    defer gpa.free(marker);
    const tree = try writeGenerationTree(gpa, io, generation_root, instance, marker);
    defer gpa.free(tree);

    var deps_dir = try openDepsDir(io, generation_root);
    defer deps_dir.close(io);
    var prepared = try prepare(gpa, io, &.{instance}, cache_root, deps_dir);
    defer prepared.deinit();
    const root = try prepared.resolveBare("left-pad");
    defer root.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, root.path, "index.js"));
    // cache から scratch へ展開していれば path は scratch 配下になる。
    try testing.expect(std.mem.startsWith(u8, root.path, generation_root));
    try testing.expect(std.mem.startsWith(u8, root.package_root, generation_root));
    const sub = try prepared.resolveBare("left-pad/sub");
    defer sub.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, sub.path, "sub.js"));
    // 世代 tree だけで解決したため cache store/scratch は作られない。
    try testing.expect(prepared.scratch == null);
    try testing.expect(prepared.store == null);
}

test "Prepared は世代 tree の provenance が lock と食い違えば cache 経路へ fallback する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "empty-cache");
    try temporary.dir.createDirPath(io, "env/gen-test");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "empty-cache", gpa);
    defer gpa.free(cache_root);
    const generation_root = try temporary.dir.realPathFileAlloc(io, "env/gen-test", gpa);
    defer gpa.free(generation_root);

    const instance = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .url = "fixture://left-pad-1.0.0.tgz",
    };
    // 別世代の instance（sha256 が違う）の marker を置く（古い tree 相当）。
    const stale = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        .url = "fixture://left-pad-1.0.0.tgz",
    };
    const marker = try npm_env.provenanceText(gpa, stale);
    defer gpa.free(marker);
    const tree = try writeGenerationTree(gpa, io, generation_root, instance, marker);
    defer gpa.free(tree);

    var deps_dir = try openDepsDir(io, generation_root);
    defer deps_dir.close(io);
    var prepared = try prepare(gpa, io, &.{instance}, cache_root, deps_dir);
    defer prepared.deinit();
    // 世代 tree は使わず、空 cache からの構築に失敗する（fail-closed）。
    try testing.expectError(error.CacheMiss, prepared.resolveBare("left-pad"));
}

test "Prepared は marker 欠落・壊れた marker の世代 tree を古いものとして扱う" {
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
    // marker 無し（旧 lnako が materialize した世代）と、空/解析不能 marker。
    const cases = [_][]const u8{ "", "garbage\n" };
    for (cases, 0..) |marker_text, index| {
        const generation_rel = try std.fmt.allocPrint(gpa, "env/gen-{d}", .{index});
        defer gpa.free(generation_rel);
        try temporary.dir.createDirPath(io, generation_rel);
        const generation_root = try temporary.dir.realPathFileAlloc(io, generation_rel, gpa);
        defer gpa.free(generation_root);
        const tree = try writeGenerationTree(gpa, io, generation_root, instance, marker_text);
        defer gpa.free(tree);
        var deps_dir = try openDepsDir(io, generation_root);
        defer deps_dir.close(io);
        var prepared = try prepare(gpa, io, &.{instance}, cache_root, deps_dir);
        defer prepared.deinit();
        try testing.expectError(error.CacheMiss, prepared.resolveBare("left-pad"));
    }
}

test "Prepared は package.json identity が lock と違う世代 tree を再利用しない" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "empty-cache");
    try temporary.dir.createDirPath(io, "env/gen-test");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "empty-cache", gpa);
    defer gpa.free(cache_root);
    const generation_root = try temporary.dir.realPathFileAlloc(io, "env/gen-test", gpa);
    defer gpa.free(generation_root);
    const instance = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .url = "fixture://left-pad-1.0.0.tgz",
    };
    const marker = try npm_env.provenanceText(gpa, instance);
    defer gpa.free(marker);
    const tree = try writeGenerationTree(gpa, io, generation_root, instance, marker);
    defer gpa.free(tree);
    // marker は lock と一致するが、root package は別名の残骸。
    var dir = try std.Io.Dir.cwd().openDir(io, tree, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "package.json", .data = "{\"name\":\"other-pkg\",\"version\":\"1.0.0\",\"main\":\"index.js\"}" });

    var deps_dir = try openDepsDir(io, generation_root);
    defer deps_dir.close(io);
    var prepared = try prepare(gpa, io, &.{instance}, cache_root, deps_dir);
    defer prepared.deinit();
    try testing.expectError(error.CacheMiss, prepared.resolveBare("left-pad"));
}

test "Prepared は世代 tree が symlink なら cache 経路へ fallback する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "empty-cache");
    try temporary.dir.createDirPath(io, "env/gen-test/deps");
    try temporary.dir.createDirPath(io, "external/gen/deps");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "empty-cache", gpa);
    defer gpa.free(cache_root);
    const generation_root = try temporary.dir.realPathFileAlloc(io, "env/gen-test", gpa);
    defer gpa.free(generation_root);
    const external_root = try temporary.dir.realPathFileAlloc(io, "external/gen", gpa);
    defer gpa.free(external_root);

    const instance = lock_model.NpmInstance{
        .key = "left-pad@1.0.0",
        .name = "left-pad",
        .version = "1.0.0",
        .sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .url = "fixture://left-pad-1.0.0.tgz",
    };
    const marker = try npm_env.provenanceText(gpa, instance);
    defer gpa.free(marker);
    const external_tree = try writeGenerationTree(gpa, io, external_root, instance, marker);
    defer gpa.free(external_tree);
    const dir_name = try npm_env.instanceDirName(gpa, instance);
    defer gpa.free(dir_name);
    const link_path = try std.fmt.allocPrint(gpa, "{s}/deps/{s}", .{ generation_root, dir_name });
    defer gpa.free(link_path);
    // symlink を作れない環境（権限不足等）は skip する。
    std.Io.Dir.cwd().symLink(io, external_tree, link_path, .{ .is_directory = true }) catch return error.SkipZigTest;

    var deps_dir = try openDepsDir(io, generation_root);
    defer deps_dir.close(io);
    var prepared = try prepare(gpa, io, &.{instance}, cache_root, deps_dir);
    defer prepared.deinit();
    // symlink を tree root として追従せず、空 cache からの構築失敗へ倒す。
    try testing.expectError(error.CacheMiss, prepared.resolveBare("left-pad"));
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
