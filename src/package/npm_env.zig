//! lock `npmInstances` の環境 materialize（#53）。
//!
//! - lock の `sha256`（tarball の SHA-256）と `url` から cache key を導出し、
//!   cache の raw archive を **lock の sha256 と照合してから** 展開する。
//!   cache の派生 tree は自己認証に過ぎないため信頼しない（artifact/http
//!   経路と同じ方針で、検証済み raw bytes から毎回 tree を作り直す）。
//! - 出力は `<gen>/deps/npm_<instance>`。dir 名は instance key から決定的に
//!   導出するので、cache が揃っていれば lock と cache だけで offline 再構築
//!   できる。
//! - cache に tarball が無い場合、`--offline` なら取得せず `not_found` 診断で
//!   fail-closed する。online なら lock の `url` から tarball を取得し、lock
//!   の `sha256` で検証してから cache へ格納して materialize する（#53）。
//!   取得は `fetch` の既存 HTTP 層を再利用するため、再取得できるのは
//!   http/https の url だけ（平文 http は loopback のみ）。`file:` やローカル
//!   path を記録した lock は cache が揃っている場合だけ materialize できる。
//!   lock は変更しない。
//! - Node・npm CLI・lifecycle script は一切使わない。

const std = @import("std");
const cache = @import("cache.zig");
const environment = @import("environment.zig");
const fetch = @import("fetch.zig");
const lock_model = @import("lock_model.zig");
const project_trust = @import("project_trust.zig");
const materialize = @import("materialize.zig");
const npm_esm = @import("npm_esm.zig");
const unpack = @import("unpack.zig");

const Allocator = std.mem.Allocator;

/// instance dir 名の前置。`npm_` を含む名前は manifest 由来の package dir
/// （`allocateDepsName`）と衝突し得るため、sync 側は package 採番より前に
/// この dir 名を予約する（`instanceDirName` を参照）。
pub const dir_prefix = "npm_";
/// dir 名に残す instance key の可読部分の上限（byte）。
const max_readable_bytes: usize = 64;

/// instance tree 直下に残す provenance marker。lock の正規化 sha256 を
/// 1 行で記録し、compile 側が世代 tree を lock 束縛付きで再利用する根拠に
/// する（無い・食い違う tree は使わず cache から作り直す）。package が
/// 同名 file を同梱する場合は黙って上書きせず materialize を失敗させる。
pub const provenance_file = ".lnako-npm-instance";
/// marker として読む最大 byte 数（`sha256:<64hex>\n` に十分な余裕）。
/// compile 側の読み込み上限もこの値に揃える。
pub const max_provenance_bytes: usize = 128;

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

/// 世代 dir 絶対 path から instance tree（`<generation_dir>/deps/<dir>`）の
/// 絶対 path を作る。dir 名の導出は `instanceDirName` を再利用する。
pub fn instanceTreePath(allocator: Allocator, generation_dir: []const u8, instance: lock_model.NpmInstance) Allocator.Error![]u8 {
    const name = try instanceDirName(allocator, instance);
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ generation_dir, "deps", name });
}

/// instance tree の provenance marker 本文（`sha256:<hex>\n`）を作る。
/// sha256 を持たない・正規化できない instance は `InvalidSource`。
pub fn provenanceText(allocator: Allocator, instance: lock_model.NpmInstance) Error![]u8 {
    var digest: [32]u8 = undefined;
    const sha256 = instance.sha256 orelse return error.InvalidSource;
    if (!lock_model.normalizeSha256(sha256, &digest)) return error.InvalidSource;
    return std.fmt.allocPrint(allocator, "sha256:{s}\n", .{std.fmt.bytesToHex(digest, .lower)});
}

/// marker 本文が lock instance の sha256 と一致するか。前後の空白だけを
/// 許容し、digest は正規化して比較する（無い・壊れた marker は不一致）。
pub fn provenanceMatches(instance: lock_model.NpmInstance, text: []const u8) bool {
    if (text.len > max_provenance_bytes) return false;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var expected: [32]u8 = undefined;
    const sha256 = instance.sha256 orelse return false;
    if (!lock_model.normalizeSha256(sha256, &expected)) return false;
    var actual: [32]u8 = undefined;
    if (!lock_model.normalizeSha256(trimmed, &actual)) return false;
    return std.mem.eql(u8, &expected, &actual);
}

/// `instances` を世代 `deps/` へ materialize する。空なら何もしない。
/// 途中で失敗した場合、生成済みの tree は世代ごと破棄される（公開しない）。
///
/// 返り値は今回読み出し・格納した cache object key（`params.arena` 所有）。
/// 呼出し側はこれを sync の used-keys へ記録し、`sync --clean` が直後に
/// 参照 entry を消さないようにする。
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

    // marker は package tree 直下の予約名。package が同名 entry を同梱して
    // いる場合に黙って上書き（archive と異なる tree を公開）しない。
    if (reservedMarkerNameInTree(scratch, params.io) catch |err| return mapFs(err)) {
        return params.session.fail(.invalid_source, .artifact, instance.key, "npm package \"{s}\" contains the reserved lnako provenance file \"{s}\"", .{ instance.key, provenance_file });
    }

    // 同一世代内の再実行でも同じ結果になるようにする。
    environment.deleteTreeChecked(params.deps_dir, params.io, dir_name) catch {};
    params.deps_dir.createDirPath(params.io, dir_name) catch |err| return mapFs(err);
    var dest = params.deps_dir.openDir(params.io, dir_name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapFs(err);
    defer dest.close(params.io);
    _ = materialize.copyTreeFromDirs(params.gpa, params.io, &scratch, &dest, .{}) catch |err| return mapTreeError(params, err, instance.key);
    // 検証済み archive から作った tree であることを lock の sha256 で記録する。
    // compile 側は marker が lock と一致する場合だけ世代 tree を再利用する。
    // 世代は commit まで非公開なので、部分的な marker が公開世代に残らない。
    const provenance = try provenanceText(params.gpa, instance);
    defer params.gpa.free(provenance);
    dest.writeFile(params.io, .{ .sub_path = provenance_file, .data = provenance }) catch |err| return mapFs(err);
}

/// lock の `sha256` と cache の raw archive を照合して bytes を返す。
/// 検証できない cache bytes は返さない（欠落・改竄はどちらも cache miss と
/// みなす）。cache 欠落時は `--offline` なら `not_found` で fail-closed し、
/// online なら lock の `url` から取得・検証・cache 格納してから bytes を返す。
/// 返り値は `params.gpa` 所有（呼出し側が free）。
fn readVerifiedArchive(
    params: Params,
    instance: lock_model.NpmInstance,
    used_keys: *std.ArrayListUnmanaged([]const u8),
) Error![]u8 {
    const sha256 = instance.sha256 orelse return params.session.fail(
        .invalid_source,
        .artifact,
        instance.key,
        "npm instance \"{s}\" has no sha256 in nako.lock",
        .{instance.key},
    );
    // 解釈できない hash 表記は取得前に落とす（cache も fetch も不要と分かる
    // 入力で無駄な GET をしない。`verifyHash` と同じ表記を受理する）。
    if (!fetch.isSupportedHash(sha256)) return params.session.fail(
        .invalid_source,
        .artifact,
        instance.key,
        "npm instance \"{s}\" has an unsupported sha256 notation in nako.lock",
        .{instance.key},
    );
    const url = instance.url orelse return params.session.fail(
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
    const cached = params.cache_store.readVerifiedSourceArchive(params.gpa, key, sha256) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidKey => return params.session.fail(
            .invalid_source,
            .artifact,
            instance.key,
            "npm instance \"{s}\" has an invalid cache key",
            .{instance.key},
        ),
    };
    const bytes = cached orelse blk: {
        // cache 欠落。`--offline` は従来どおり取得せず fail-closed する
        // （診断は既存のまま）。online は lock の url から取得する。
        if (params.session.policy.offline) {
            return params.session.fail(
                .not_found,
                .artifact,
                instance.key,
                "npm tarball for \"{s}\" is not in the cache and sync is running with --offline; rerun without --offline to fetch it from the lock url",
                .{instance.key},
            );
        }
        break :blk try fetchIntoCache(params, instance, url, key, sha256);
    };
    // `sync --clean` の keep list に載せる（直後に参照 entry を消さない）。
    // append が OOM しても、呼出し側の `defer free` が張られる前に
    // bytes を落とさないようここで解放する。
    errdefer params.gpa.free(bytes);
    try used_keys.append(params.arena, key);
    return bytes;
}

/// cache 欠落時の online 取得経路。lock の `url` から tarball を取得し、
/// lock の `sha256` と照合してから content-addressed key へ cache 格納する。
/// 検証に失敗した bytes は cache へ公開しない（objects/ に部分 entry を
/// 残さない）。既存 entry が lock の sha256 を満たさない場合は、検証済み
/// bytes で置き換える（壊れた cache を自己修復する）。
/// `url` は呼出し側（`readVerifiedArchive`）が非 null を保証する。
/// 返り値は `params.gpa` 所有（呼出し側が free）。
fn fetchIntoCache(
    params: Params,
    instance: lock_model.NpmInstance,
    url: []const u8,
    key: []const u8,
    sha256: []const u8,
) Error![]u8 {
    // 404・redirect 上限・timeout・HTTP status は fetch 層が分類付きで
    // session へ記録する。取得 bytes は session arena 所有なので、cache 格納
    // と返却に使う gpa 所有の複製を作る。
    const fetched = try fetch.fetchBytes(params.session, url, .artifact);
    try fetch.verifyHash(params.session, fetched, sha256, url, .artifact);
    const owned = try params.gpa.dupe(u8, fetched);
    errdefer params.gpa.free(owned);
    // `Store.removeEntry` の error set は I/O のみ（OOM/Canceled は含まない）。
    // 検証できない既存 entry（改竄・不完全）が残っていると、`publishStaging` は
    // tree digest と marker の一致だけで既存 entry を保持し、壊れた
    // `source.archive` を残してしまう。取得した検証済み bytes で作り直すため
    // 先に消す。ここへ来る時点で cache は lock の sha256 を満たしておらず、
    // 保持する価値は無い。欠落 key では no-op（`deleteTreeChecked` が
    // FileNotFound を成功扱いする）なので、通常の cache miss もこの経路で安全。
    // 削除から publish までの窓は `sync` が cache の排他 lock を保持している
    // 前提で、他プロセスが観測しても entry 欠落は cache miss として自己修復
    // される（publish は staging からの rename で原子置換）。
    params.cache_store.removeEntry(key) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.InvalidKey => return params.session.fail(
            .invalid_source,
            .artifact,
            instance.key,
            "npm instance \"{s}\" has an invalid cache key",
            .{instance.key},
        ),
        else => return error.FileSystem,
    };
    // cache 格納は lock の sha256 と url から導出した key へ行う。これにより
    // 次回以降の sync は同じ key で cache hit する。
    npm_esm.publishNpmTree(params.gpa, params.io, params.cache_store, key, owned) catch |err|
        return mapUnpackError(params, err, instance.key);
    return owned;
}

/// `dir` 直下に予約 marker 名（ASCII 大小文字を畳んで比較）の entry が
/// あるか。case-insensitive FS では別表記の entry を marker 書込みが黙って
/// 上書きしてしまうため、case を無視して検出する。
fn reservedMarkerNameInTree(dir: std.Io.Dir, io: std.Io) !bool {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, provenance_file)) return true;
    }
    return false;
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

/// `child` が `parent` の直系の子孫（separator 境界）か。Windows の
/// realpath は `/`・`\\` のどちらも返し得るため `std.fs.path.isSep` で判定する。
pub fn isStrictlyWithin(parent: []const u8, child: []const u8) bool {
    if (child.len <= parent.len) return false;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return std.fs.path.isSep(child[parent.len]);
}

/// 公開済み世代の `deps` dir を project root から各段 no-follow で開いて
/// 固定する。compile はこのハンドル相対で npm tree を特定・検証する（load 後の
/// 中間 path 差し替えに左右されない）。返却後の module 読みは package source と
/// 同じ path 解決で、load 時の ACL 検査と project 所有権を信頼する。
/// 途中が symlink・不在なら null（世代 tree を使わず cache 経路へ fallback）。
/// OOM/Canceled は fallback せず呼出し側へ伝播する。
pub fn openGenerationDeps(io: std.Io, project_root: []const u8, generation: []const u8) !?std.Io.Dir {
    // 単一の規範 path 成分であることを先に確認する（".." や separator を
    // openDir に渡さない）。
    if (!environment.validGenerationName(generation)) return null;
    var project = std.Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        return null;
    };
    defer project.close(io);
    var nako = project.openDir(io, environment.dir_name, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        return null;
    };
    defer nako.close(io);
    var env = nako.openDir(io, environment.env_dir, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        return null;
    };
    defer env.close(io);
    var generation_dir = env.openDir(io, generation, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        return null;
    };
    defer generation_dir.close(io);
    // 呼出し側（ACL 検査）が iterate するため list 権限も付けて開く。
    const deps = generation_dir.openDir(io, "deps", .{ .follow_symlinks = false, .iterate = true }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        return null;
    };
    return deps;
}

/// 固定した世代 `deps` ハンドルに対する writable 検査。compile は npm tree を
/// nako package source と同じ信頼境界で読むため、package root に適用して
/// いるのと同じ ACL 検査を、世代 `deps` 自身・その祖先（gen/env/.nako）・
/// 配下の npm tree へ適用する。検査対象は実際に読み出す deps ハンドルの
/// 実体 path から導出する（ACL 判定自体は path を再解決するため、判定と
/// 読み出しの間に差し替えが起きる可能性は project 所有権の信頼に含める）。
/// 戻り値 true=再利用可、false=検査不能のため cache 経路へ fallback。
/// 実際に書込み可能と確認された unsafe は enforce で拒否し、warn では警告して
/// 再利用する（`shouldRejectWritable`）。「検査不能」は書込み可能状態とは
/// 区別し、warn でも reuse せず cache 経路へ fallback する。この検査不能
/// fallback は enforce でも停止せず fallback する点が旧挙動からの変化で、
/// 書込み可能の警告（`writable_warning`）とは別事象のため現状は追加の診断を
/// 出さない。fallback 先の cache も unavailable の場合は name 単位の cache 系
/// エラー（`CacheUnavailable`/`CacheMiss` 等）で停止する。祖先検査や個々の
/// entry の owner/ACL 取得失敗（`low_level_fs.stat` 等）は `project_trust` の
/// 既定どおり unsafe(true)（warn で警告して再利用・enforce で拒否）に
/// 丸められる。entry の mode/kind を確定する POSIX `statFile` 失敗は検査不能
/// として fallback する。なお d_type を返さない FS（entry.kind == .unknown）では
/// walker が子dirへ降りないため、深部の検査不能を検出できない既存制約がある
/// （`project_trust` 側と同じ制約・follow-up）。
pub fn validateGenerationDepsWritable(
    allocator: Allocator,
    io: std.Io,
    project_root: []const u8,
    deps: std.Io.Dir,
    mode: project_trust.WritableMode,
    writable_warning: *bool,
) !bool {
    // project_root は呼出し側で realPath 済みの canonical path だが、Windows の
    // junction/reparse point を no-follow open が追従し得るため、canonical な
    // project root と deps 実体 path を突き合わせる。
    var project_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var project_dir = std.Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        return false;
    };
    defer project_dir.close(io);
    const project_length = project_dir.realPath(io, &project_buffer) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        return false;
    };
    const project_real = project_buffer[0..project_length];

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deps_length = deps.realPath(io, &buffer) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        return false;
    };
    const deps_real = buffer[0..deps_length];
    // 世代外 tree を「検査済み」と誤認しない。検査不能として cache 経路へ
    // fallback する（enforce/warn いずれも未検査 tree は使わない）。
    if (!isStrictlyWithin(project_real, deps_real)) return false;
    if (mode == .ignore) return true;

    // deps 自身と祖先を検査する。実在する子を仮定して親方向を走査することで
    // deps 自身の mode/owner も対象に含める（祖先だけでは deps が漏れる）。
    const probe = try std.fs.path.join(allocator, &.{ deps_real, ".lnako-acl-probe" });
    defer allocator.free(probe);
    const unsafe_ancestors = project_trust.hasUnsafeWritableAncestors(allocator, io, probe, project_real) catch |err| {
        // エラー集合は platform で異なる（Windows は InvalidUtf8 を含む）。
        // 特定 error 名を switch の case にすると非対応 platform で
        // コンパイルできないため、名前で判定する。
        if (std.mem.eql(u8, @errorName(err), "OutOfMemory")) return error.OutOfMemory;
        if (std.mem.eql(u8, @errorName(err), "Canceled")) return error.Canceled;
        // 検査不能な世代 tree は使わず cache 経路へ fallback する。
        return false;
    };
    if (project_trust.shouldRejectWritable(mode, unsafe_ancestors, writable_warning)) return error.InvalidEnvironment;

    // 配下の npm tree 本体を検査する。entry.kind が unknown の FS では stat で
    // 種別を確定し、確定できない場合は検査不能として cache 経路へ fallback する。
    var iterator = deps.iterate();
    while (true) {
        const next = iterator.next(io) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Canceled) return error.Canceled;
            // 走査できない deps を「検査済み」にしない。世代 tree を使わず
            // cache 経路へ fallback する（呼出し側が false でハンドルを捨てる）。
            return false;
        };
        const entry = next orelse break;
        // deps は大文字小文字を畳む FS があり得る。reuse 側の openRealDir は
        // その FS で `NPM_*` も開けるため、検査対象も同じ規則で拾う。
        if (!std.ascii.startsWithIgnoreCase(entry.name, dir_prefix)) continue;
        var is_directory = entry.kind == .directory;
        if (entry.kind == .unknown) {
            const stat = deps.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (err == error.Canceled) return error.Canceled;
                // 種別を確定できない tree は検査不能。「実際に書込み可能」と
                // 確認できたわけではないため warn でも再利用せず fallback する。
                return false;
            };
            is_directory = stat.kind == .directory;
        }
        // 非 directory は reuse 側（openRealDir）が tree root として拒否する。
        if (!is_directory) continue;
        const tree_path = try std.fs.path.join(allocator, &.{ deps_real, entry.name });
        defer allocator.free(tree_path);
        // 走査不能な子dir等は「検査不能」であり、書き込み可能と確認された
        // unsafe とは異なる。warn でも未検査 tree を再利用せず、正常な cache
        // archive から作り直す（enforce の拒否と warn の確認済み unsafe の
        // 扱いは `shouldRejectWritable` のまま）。
        const unsafe = project_trust.inspectUnsafeWritableDirectory(allocator, io, tree_path) catch |err| {
            // エラー集合は platform で異なるため、case ではなく名前で判定する。
            if (std.mem.eql(u8, @errorName(err), "OutOfMemory")) return error.OutOfMemory;
            if (std.mem.eql(u8, @errorName(err), "Canceled")) return error.Canceled;
            return false;
        };
        if (project_trust.shouldRejectWritable(mode, unsafe, writable_warning)) return error.InvalidEnvironment;
    }
    return true;
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

/// 予約 marker 名を同梱する npm tarball（materialize 拒否の再現用）。
fn buildNpmTarballWithMarkerCollision(gpa: Allocator) ![]u8 {
    var tar_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer tar_buffer.deinit();
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &tar_buffer.writer };
    try tar_writer.setRoot("package");
    try tar_writer.writeFileBytes("package.json", "{\"name\":\"escape\",\"version\":\"1.2.3\",\"main\":\"index.js\"}", .{});
    try tar_writer.writeFileBytes("index.js", "export default 1;\n", .{});
    try tar_writer.writeFileBytes(provenance_file, "attacker", .{});
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

test "npm_env は provenance marker 名を同梱する tarball を拒否する" {
    var h = try Harness.init();
    defer h.deinit();
    const gpa = testing.allocator;
    const arena = h.arena_impl.allocator();

    const tarball = try buildNpmTarballWithMarkerCollision(gpa);
    defer gpa.free(tarball);
    const instance = try testInstance(arena, gpa, tarball);
    try h.publish(instance, tarball);

    const params = h.params();
    try testing.expectError(error.InvalidSource, materializeInstances(params, &.{instance}));
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

test "validateGenerationDepsWritable は検査不能な世代 tree を warn でも cache fallback にする" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    // root 実行では mode 000 でも走査できるため前提が成立しない。
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    // 子dirを走査できない世代 tree（検査不能）を再現する。d_type を返す FS
    // で walker が `locked` へ降り、open 失敗が伝播することを前提にする。
    try temporary.dir.createDirPath(io, "project/.nako/env/gen-test/deps/npm_x/locked");
    // d_type を返さない FS では walker が `locked` へ降りず前提が崩れるため skip。
    var npm_x = try temporary.dir.openDir(io, "project/.nako/env/gen-test/deps/npm_x", .{ .iterate = true });
    defer npm_x.close(io);
    var probe = npm_x.iterate();
    while (try probe.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "locked") and entry.kind == .unknown) return error.SkipZigTest;
    }
    var locked = try temporary.dir.openDir(io, "project/.nako/env/gen-test/deps/npm_x/locked", .{ .iterate = true });
    defer locked.close(io);
    try locked.setPermissions(io, .fromMode(0o000));
    // cleanup が走査できるよう、close 前に権限を戻す。
    defer locked.setPermissions(io, .fromMode(0o755)) catch {};
    const project_root = try temporary.dir.realPathFileAlloc(io, "project", gpa);
    defer gpa.free(project_root);
    var deps = (try openGenerationDeps(io, project_root, "gen-test")) orelse return error.TestUnexpectedResult;
    defer deps.close(io);

    var warning = false;
    const keep = try validateGenerationDepsWritable(gpa, io, project_root, deps, .warn, &warning);
    // 検査不能は「実際に書込み可能と確認された状態」ではない。warn でも
    // 未検査 tree を再利用せず、正常な cache archive へ fallback する。
    try testing.expect(!keep);
    try testing.expect(!warning);
    // enforce でも検査不能は拒否ではなく fallback（fallback 先の cache archive は
    // lock の sha256 で検証される）。
    var enforce_warning = false;
    try testing.expect(!try validateGenerationDepsWritable(gpa, io, project_root, deps, .enforce, &enforce_warning));
    try testing.expect(!enforce_warning);
}

test "validateGenerationDepsWritable は確認済み unsafe の warn/enforce の扱いを変えない" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    // 共有writableな子dir（実際に書込み可能＝unsafe と確認できる状態）。
    try temporary.dir.createDirPath(io, "project/.nako/env/gen-test/deps/npm_x/shared");
    var shared = try temporary.dir.openDir(io, "project/.nako/env/gen-test/deps/npm_x/shared", .{ .iterate = true });
    defer shared.close(io);
    try shared.setPermissions(io, .fromMode(0o777));
    const project_root = try temporary.dir.realPathFileAlloc(io, "project", gpa);
    defer gpa.free(project_root);
    var deps = (try openGenerationDeps(io, project_root, "gen-test")) orelse return error.TestUnexpectedResult;
    defer deps.close(io);

    // warn は警告して再利用（既存の扱いを維持）。
    var warn_warning = false;
    try testing.expect(try validateGenerationDepsWritable(gpa, io, project_root, deps, .warn, &warn_warning));
    try testing.expect(warn_warning);
    // enforce は拒否（既存の扱いを維持）。
    var enforce_warning = false;
    try testing.expectError(error.InvalidEnvironment, validateGenerationDepsWritable(gpa, io, project_root, deps, .enforce, &enforce_warning));
}
