//! npm package の ESM 入口解決（#54）。
//!
//! - `package.json` のパースは `package_json.zig` に集約する（#53）。
//!   `name` / `version` / `type` / `main` / `module` / `exports` の型検査と
//!   BOM・重複キー・不正 JSON の扱いを Node 24/26 の実測に合わせる。
//! - `exports` / `module` / `main` から入口 path を選ぶ
//! - `exports` のサブパスキー（`"./sub"`）と 1 個の `*` wildcard を解決する
//! - `node` / `browser` / `require` 条件は暗黙選択しない（明示要求が無い限り無視）
//! - bare specifier → lock `npmInstances` + cache tree への写像
//!
//! 入口選択は Node の ESM 解決に合わせる。`exports` がある package では
//! root 入口を `exports` からのみ選び、`module` / `main` / `index.js` へは
//! フォールバックしない（作者が root を隠せる）。`exports` が無い package は
//! `module` → `main` → `index.js` の順に候補を選び、候補のファイルが無ければ
//! Node の legacy main 解決と同じく次の候補（最終的に `index.js`）へ進む。
//! `exports` が無い（または string / array / object 以外の）package の
//! `name/sub` は、Node の ESM と同じく `<package_root>/<sub>` の厳密 path
//! として解決する（拡張子補完・`<sub>/index.js` フォールバックはしない）。
//!
//! `package_root` は解決の先頭で realpath へ canonicalize し、入口ファイルも
//! `realPathFileAlloc` 後に canonical root の直系の子孫であることを確認する。
//! symlink で root 外へ脱出する入口は fail-closed で拒否する。
//!
//! registry（`BareRegistry` / `npm_resolver.Prepared`）は入口を構築時に
//! 確定せず、bare name の要求時に遅延解決する。これにより root target の
//! `EntryNotFound` / `PackageJsonInvalid` / `BareNotFound`（非公開）を Node の
//! import 解決と同じ分類で返せる。
//!
//! module_graph は層境界のためここを直接 import せず、`NpmModuleResolver`
//! コールバック経由で利用する。

const std = @import("std");
const cache_key = @import("cache_key.zig");
const package_json_mod = @import("package_json.zig");
const cache_mod = @import("cache.zig");
const lock_model = @import("lock_model.zig");
const unpack = @import("unpack.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Error = error{
    Canceled,
    PackageJsonMissing,
    PackageJsonInvalid,
    EntryNotFound,
    BareNotFound,
    /// wildcard の一致部分が specifier として不正。`..` / `.` / `node_modules`
    /// は Node の ERR_INVALID_MODULE_SPECIFIER と同じ判定。空セグメントは Node
    /// が DEP0166 警告付きで、`:`・制御文字・`\` は警告なしで解決するが、
    /// この実装は fail-closed で拒否する（安全側の意図的差異）。
    /// 配列 fallback でも飛ばさない。
    InvalidSpecifier,
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

/// `exports` target の 1 段解決結果。`unresolved` と `excluded` を区別する
/// ことで、条件オブジェクトの「一致なし」と「`null` による非公開」を
/// Node と同じ規則で扱う。
const TargetResolution = union(enum) {
    /// 条件不一致などで未解決。呼び出し側は次の候補へ進む。
    unresolved,
    /// `null` target による明示的な非公開。探索をここで打ち切る。
    excluded,
    /// root 外・絶対 path・`:`・制御文字などを含む不正 target。
    invalid,
    /// 検証済みの相対 target（`./` 前置、gpa 所有）。
    target: []u8,
};

/// 配列 fallback で最後に観測した例外種別（Node の lastException 相当）。
const TargetException = enum { invalid, excluded };

/// `exports` の再帰評価に許す最大深度。悪意ある深い配列/条件オブジェクトで
/// スタックを使い切らないための上限（JSON 1 MiB の範囲でも十分）。
const max_exports_depth: usize = 64;
/// wildcard 置換後の target 長の上限。`*` を多数含む target と長い一致部分で
/// ファイル存在確認前に巨大なメモリを確保しないための上限。
const max_export_target_bytes: usize = 1024 * 1024;

/// wildcard 置換の文脈。`matched` は `*` に置換する文字列で、パターン
/// キーでない場合は null（target 内の `*` を置換しない）。`depth` は
/// `exports` の再帰深度。
const TargetContext = struct {
    matched: ?[]const u8 = null,
    depth: usize = 0,

    fn next(self: TargetContext) TargetContext {
        return .{ .matched = self.matched, .depth = self.depth + 1 };
    }
};

/// `package.json` から選んだ root 入口。
pub const RootEntry = struct {
    /// package root からの相対 target（`./` 前置を含み得る）。
    target: []u8,
    /// `exports` 由来なら拡張子補完をしない（Node の exports は厳密 path）。
    from_exports: bool,

    pub fn deinit(self: RootEntry, gpa: Allocator) void {
        gpa.free(self.target);
    }
};

/// `package.json` の root 入口候補を選ぶ。`exports` があれば root 入口は
/// `exports` からのみ選び、`module` / `main` / `index.js` へは
/// フォールバックしない（Node と同じく、作者が root を隠せる）。
/// `exports` が無ければ `module` → `main` → `index.js` の順に選ぶ。
/// root を公開しない package は null。`exports` が string / array / object
/// 以外（`null`・数値・真偽値）なら Node と同じく exports 無しとして扱う
/// （Node 24.21.0 / 26.13.0 で `module` へのフォールバックを実測）。
/// `name` / `type` が非文字列ならパース段階で `PackageJsonInvalid` にする
/// （同じく Node 24.21.0 / 26.13.0 実測）。
///
/// 返す `target` は「候補」であり、ファイルの存在は `resolveEntryInRoot` が
/// legacy main 解決の順で確認する。この関数はテストと将来の遅延解決用で、
/// 実運用の root 入口解決は `resolveEntryInRoot` が行う。
pub fn pickEntryFromPackageJson(gpa: Allocator, package_json: []const u8) Error!?RootEntry {
    var manifest = try package_json_mod.parse(gpa, package_json);
    defer manifest.deinit();
    return pickRootEntry(gpa, &manifest);
}

fn pickRootEntry(gpa: Allocator, manifest: *const package_json_mod.Manifest) Error!?RootEntry {
    if (manifest.exports) |exports_v| {
        return switch (try resolveExportsRoot(gpa, exports_v)) {
            .target => |target| .{ .target = target, .from_exports = true },
            .excluded, .unresolved => null,
            .invalid => error.PackageJsonInvalid,
        };
    }
    if (manifest.module) |module| {
        if (module.len > 0) return .{ .target = try gpa.dupe(u8, module), .from_exports = false };
    }
    if (manifest.main) |main| {
        if (main.len > 0) return .{ .target = try gpa.dupe(u8, main), .from_exports = false };
    }
    return .{ .target = try gpa.dupe(u8, "index.js"), .from_exports = false };
}

/// `exports` オブジェクトのキーが「`.` 前置のサブパス」と「条件キー」で
/// 混在していないか検証する。Node は混在を ERR_INVALID_PACKAGE_CONFIG に
/// する（空文字キーは条件キー扱い）。
fn exportsKeysAreConsistent(exports_obj: std.json.ObjectMap) bool {
    var has_subpath = false;
    var has_condition = false;
    var it = exports_obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len > 0 and key[0] == '.') {
            has_subpath = true;
        } else {
            has_condition = true;
        }
        if (has_subpath and has_condition) return false;
    }
    return true;
}

/// `exports` 全体から root 入口 target を解決する。object は `"."` キーが
/// あればその値、無ければ条件オブジェクトとして扱う（Node と同じ）。
fn resolveExportsRoot(gpa: Allocator, exports_v: std.json.Value) Error!TargetResolution {
    if (exports_v == .object) {
        if (!exportsKeysAreConsistent(exports_v.object)) return error.PackageJsonInvalid;
        if (exports_v.object.get(".")) |dot| return resolveTarget(gpa, dot, .{});
    }
    return resolveTarget(gpa, exports_v, .{});
}

fn resolveTarget(gpa: Allocator, value: std.json.Value, ctx: TargetContext) Error!TargetResolution {
    if (ctx.depth > max_exports_depth) return error.PackageJsonInvalid;
    return switch (value) {
        .null => .excluded,
        .string => |target| resolveTargetString(gpa, target, ctx),
        .array => |arr| resolveTargetArray(gpa, arr.items, ctx.next()),
        .object => |obj| resolveTargetObject(gpa, obj, ctx.next()),
        // Node は string / array / null / object 以外の target を
        // ERR_INVALID_PACKAGE_TARGET にする（真偽値・数値）。
        else => .invalid,
    };
}

/// Node の `isArrayIndex` 相当。条件オブジェクトに 10 進の非負整数キーが
/// 現れたら package.json 不正（配列 fallback でも飛ばさない）。
fn isArrayIndexKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 10) return false;
    if (key.len > 1 and key[0] == '0') return false;
    var value: u64 = 0;
    for (key) |byte| {
        if (byte < '0' or byte > '9') return false;
        value = value * 10 + (byte - '0');
    }
    return value < 4294967295; // 2^32 - 1 は array index ではない
}

/// 条件オブジェクトを挿入順に走査し、`import` / `default` の最初の一致で
/// 確定する（`import` 固定優先ではない）。値が未解決なら次のキーへ進み、
/// `null` ならそこで非公開にする。`node` / `browser` / `require` は
/// 暗黙有効にしない。
fn resolveTargetObject(gpa: Allocator, obj: std.json.ObjectMap, ctx: TargetContext) Error!TargetResolution {
    // Node と同じく、条件マッチングの前に全キーの配列 index 検査を行う
    // （一致した条件が先にあっても package.json 不正として拒否する）。
    var keys = obj.iterator();
    while (keys.next()) |entry| {
        if (isArrayIndexKey(entry.key_ptr.*)) return error.PackageJsonInvalid;
    }
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "import") and !std.mem.eql(u8, key, "default")) continue;
        const resolution = try resolveTarget(gpa, entry.value_ptr.*, ctx);
        switch (resolution) {
            .unresolved => continue,
            else => return resolution,
        }
    }
    return .unresolved;
}

/// 配列 fallback。Node と同じく不正な target は飛ばして次の候補へ進む。
/// 全候補が失敗した場合は最後に観測した例外種別で結果を決める
/// （`null` が最後なら非公開、不正 target が最後なら package.json 不正）。
fn resolveTargetArray(gpa: Allocator, items: []const std.json.Value, ctx: TargetContext) Error!TargetResolution {
    // Node は空配列 target を `null`（非公開）として即座に確定する。
    if (items.len == 0) return .excluded;
    var last_exception: ?TargetException = null;
    for (items) |item| {
        const resolution = try resolveTarget(gpa, item, ctx);
        switch (resolution) {
            .target => return resolution,
            .invalid => last_exception = .invalid,
            .excluded => last_exception = .excluded,
            .unresolved => {},
        }
    }
    const exception = last_exception orelse return .unresolved;
    return switch (exception) {
        .invalid => .invalid,
        .excluded => .excluded,
    };
}

fn resolveTargetString(gpa: Allocator, target: []const u8, ctx: TargetContext) Error!TargetResolution {
    if (ctx.matched) |matched| {
        // target の template 自体が不正なら target エラーを確定する
        // （Node の PACKAGE_TARGET_RESOLVE と同じ順序）。置換で新たに入る
        // 文字列は matched 側の責任なので、ここでは template だけを見て、
        // 置換後の包含検証は呼出し側の matchedSubpathIsSafe に委ねる。
        if (!exportTargetIsContained(target)) return .invalid;
        // 置換後の長さを確保前に計算し、上限を超える入力を拒否する
        // （メモリ枯渇対策）。target 内の複数 `*` はすべて置換する。
        const stars = std.mem.count(u8, target, "*");
        if (stars > 0) {
            const base = target.len - stars;
            const expansion = std.math.mul(usize, stars, matched.len) catch return error.InvalidSpecifier;
            const total = std.math.add(usize, base, expansion) catch return error.InvalidSpecifier;
            if (total > max_export_target_bytes) return error.InvalidSpecifier;
        }
        return .{ .target = std.mem.replaceOwned(u8, gpa, target, "*", matched) catch return error.OutOfMemory };
    }
    const substituted = gpa.dupe(u8, target) catch return error.OutOfMemory;
    if (!exportTargetIsContained(substituted)) {
        gpa.free(substituted);
        return .invalid;
    }
    return .{ .target = substituted };
}

/// `exports` のサブパスキーから target を解決する。exact 一致を優先し、
/// 無ければ 1 個の `*` を持つ wildcard を prefix 最長 → key 最長の順で
/// 使う（Node の `patternKeyCompare` と同じ）。`*` は 1 文字以上にマッチする。
fn pickExportsSubpath(gpa: Allocator, exports_v: std.json.Value, subpath: []const u8) Error!TargetResolution {
    const obj = switch (exports_v) {
        .object => |o| o,
        else => return .unresolved,
    };
    const want = try std.fmt.allocPrint(gpa, "./{s}", .{subpath});
    defer gpa.free(want);
    // Node の packageExportsResolve は exact 判定に
    // `!packageSubpath.includes('*')` を要求する。specifier に `*` を含む
    // 場合は exact 一致をスキップし、パターン解決へ回す（`*` を含むキーは
    // パターンとしてのみ評価される）。
    if (std.mem.indexOfScalar(u8, want, '*') == null) {
        if (obj.get(want)) |target| return resolveTarget(gpa, target, .{});
    }

    var best_key: ?[]const u8 = null;
    var best_prefix_len: usize = 0;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, "./")) continue;
        const star = std.mem.indexOfScalar(u8, key, '*') orelse continue;
        // 置換対象の "*" は 1 個だけに制限する（Node と同じ）。
        if (std.mem.indexOfScalar(u8, key[star + 1 ..], '*') != null) continue;
        const prefix = key[0..star];
        const suffix = key[star + 1 ..];
        // `*` は空文字にマッチしない（Node: packageSubpath.length >= key.length）。
        if (want.len <= prefix.len + suffix.len) continue;
        if (!std.mem.startsWith(u8, want, prefix)) continue;
        if (!std.mem.endsWith(u8, want, suffix)) continue;
        if (best_key) |current| {
            // prefix が長いパターンを優先し、同長なら key が長い方を使う。
            if (prefix.len < best_prefix_len) continue;
            if (prefix.len == best_prefix_len and key.len <= current.len) continue;
        }
        best_key = key;
        best_prefix_len = prefix.len;
    }

    const key = best_key orelse return .unresolved;
    const target = obj.get(key) orelse return .unresolved;
    // Node は `null` target を一致部分の検証より先に確定する（非公開）。
    // `pkg/node_modules/x` と `"./*": null` / `{"import": null}` の組合せは
    // NOT_EXPORTED（InvalidSpecifier ではない）。
    const suffix_len = key.len - best_prefix_len - 1;
    const matched = want[best_prefix_len .. want.len - suffix_len];
    const resolution = try resolveTarget(gpa, target, .{ .matched = matched });
    switch (resolution) {
        .excluded => return .excluded,
        .invalid => {
            // target 自体が不正なら、一致部分の検証より先に target エラーを
            // 確定する（Node の PACKAGE_TARGET_RESOLVE と同じ順序）。
            return .invalid;
        },
        .unresolved => {
            // target は未解決でも、一致部分が specifier として不正なら
            // Node は ERR_INVALID_MODULE_SPECIFIER を返す。
            if (!matchedSubpathIsSafe(matched)) return error.InvalidSpecifier;
            return .unresolved;
        },
        .target => |substituted| {
            // 一致部分は specifier 側の入力。target とは別に検査し、不正なら
            // 配列 fallback でも後続候補へ進まない（Node はエラー確定）。
            if (!matchedSubpathIsSafe(matched)) {
                gpa.free(substituted);
                return error.InvalidSpecifier;
            }
            return resolution;
        },
    }
}

/// wildcard の一致部分（specifier 由来）が安全か検証する。`..` / `.` /
/// `node_modules` は Node も `ERR_INVALID_MODULE_SPECIFIER` にする。
/// 空セグメントは Node が DEP0166 警告付き、`:`・制御文字・`\` は警告なしで
/// 解決するが、この実装では fail-closed として拒否する
/// （安全側の意図的差異。docs/TODO.md 参照）。
fn matchedSubpathIsSafe(matched: []const u8) bool {
    for (matched) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == ':' or byte == '\\') return false;
    }
    var segments = std.mem.splitScalar(u8, matched, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".")) return false;
        if (std.mem.eql(u8, segment, "..")) return false;
        if (std.ascii.eqlIgnoreCase(segment, "node_modules")) return false;
    }
    return true;
}

/// `exports` の target が package root 内の相対 path であることを検証する。
/// 絶対 path・親セグメント・`.` セグメント・`node_modules` を拒否し、
/// `unpack` と同じく制御文字・`\`・`:` をどこでも拒否する（Windows の
/// drive 前置と代替データストリームへの参照対策）。
fn exportTargetIsContained(target: []const u8) bool {
    if (!std.mem.startsWith(u8, target, "./")) return false;
    const rel = target[2..];
    if (rel.len == 0) return false;
    for (rel) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '\\' or byte == ':') return false;
    }
    var segments = std.mem.splitScalar(u8, rel, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".")) return false;
        if (std.mem.eql(u8, segment, "..")) return false;
        if (std.ascii.eqlIgnoreCase(segment, "node_modules")) return false;
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
///
/// `exports` がある package は exports target だけを厳密 path として確認し、
/// `module` / `main` / `index.js` へはフォールバックしない。`exports` が無い
/// package は `module` → `main` → `index.js` の候補を Node の legacy main
/// 解決と同じ順でファイル確認し、見つからない候補は次へ進む
/// （Node 24.21.0 / 26.13.0 実測: `main` 欠落・ディレクトリ・`.`・空文字の
/// いずれも最終的に `index.js` へ到達する）。`.mjs` 補完だけは Node に無い
/// lnako の意図的拡張（docs/TODO.md）。
///
/// `package_root_abs` は realpath へ canonicalize してから使う（symlink を
/// 含む root でも `module_graph` の realpath 比較と同じ座標系になる）。
/// 入口ファイルが symlink で canonical root の外を指す場合は
/// `PackageJsonInvalid` で fail-closed にする。
pub fn resolveEntryInRoot(gpa: Allocator, io: std.Io, package_root_abs: []const u8) Error!ResolvedEntry {
    return resolveEntryInRootWith(gpa, io, package_root_abs, .direct);
}

/// root 入口解決の文脈。`exports` が `"."` を公開しない場合の分類だけが
/// 異なる（Node の import 解決では `ERR_PACKAGE_PATH_NOT_EXPORTED` に相当する
/// `BareNotFound`、入口検査 API の直接利用では入口不在の `EntryNotFound`）。
const RootResolutionContext = enum {
    /// `resolveEntryInRoot` の直接利用。既存の呼出し契約を保つ。
    direct,
    /// registry に登録済みの package root からの遅延解決
    /// （`resolveEntryForBare`）。
    registry,
};

fn resolveEntryInRootWith(
    gpa: Allocator,
    io: std.Io,
    package_root_abs: []const u8,
    context: RootResolutionContext,
) Error!ResolvedEntry {
    // registry 経由（bare name の import 解決）では、package root や
    // `package.json` が消えた場合も Node の ERR_MODULE_NOT_FOUND に合わせて
    // `BareNotFound` にする。直接利用 API は診断用の分類をそのまま返す。
    const root = canonicalizePackageRoot(gpa, io, package_root_abs) catch |err| switch (err) {
        error.PackageJsonMissing => switch (context) {
            .direct => return error.PackageJsonMissing,
            .registry => return error.BareNotFound,
        },
        else => return err,
    };
    errdefer gpa.free(root);

    const pj_bytes = readPackageJson(gpa, io, root) catch |err| switch (err) {
        error.PackageJsonMissing => switch (context) {
            .direct => return error.PackageJsonMissing,
            .registry => return error.BareNotFound,
        },
        else => return err,
    };
    defer gpa.free(pj_bytes);

    var manifest = try package_json_mod.parse(gpa, pj_bytes);
    defer manifest.deinit();

    if (manifest.exports) |exports_v| {
        const picked = switch (try resolveExportsRoot(gpa, exports_v)) {
            .target => |target| target,
            .excluded, .unresolved => return switch (context) {
                .direct => error.EntryNotFound,
                .registry => error.BareNotFound,
            },
            .invalid => return error.PackageJsonInvalid,
        };
        defer gpa.free(picked);
        const cleaned = stripLeadingDotSlash(picked);
        // package root 外への escapes を拒否する。exports 由来の target は
        // `exportTargetIsContained` で検証済みだが、念のため `/` と `\` の
        // 両区切りで親セグメントを検査する（Windows の `..\` 対策）。
        // legacy main の同じ検査（PackageJsonInvalid）と分類を揃える。
        if (!entryPathIsContained(cleaned)) return error.PackageJsonInvalid;
        const abs = try std.fs.path.join(gpa, &.{ root, cleaned });
        defer gpa.free(abs);
        // exports の target は拡張子補完しない（Node の exports と同じく厳密 path）。
        if (!fileExists(io, abs)) return error.EntryNotFound;
        // symlink が canonical root の外を指すなら fail-closed。
        const canonical = (try canonicalEntryPath(gpa, io, root, abs)) orelse return error.PackageJsonInvalid;
        return .{ .path = canonical, .package_root = root };
    }

    // exports が無い package。`module` は Node が読まない lnako の ESM 入口
    // 候補で、`main` より優先する（docs/TODO.md の意図的拡張）。候補の
    // ファイルが無ければ Node の legacy main 解決と同じく次の候補へ進む。
    const candidates = [_]?[]const u8{ manifest.module, manifest.main };
    for (candidates) |candidate_opt| {
        const candidate = candidate_opt orelse continue;
        if (try resolveLegacyEntry(gpa, io, root, candidate)) |entry| return entry;
    }
    // 最後の index フォールバックは Node と同じく厳密 path だけを見る
    // （`index.js.js` や `index.js/index.js` のような拡張子・ディレクトリ
    // 補完はしない）。
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.js", .{root});
    defer gpa.free(index_path);
    if (!fileExists(io, index_path)) return error.EntryNotFound;
    const canonical = (try canonicalEntryPath(gpa, io, root, index_path)) orelse return error.PackageJsonInvalid;
    return .{ .path = canonical, .package_root = root };
}

/// `module` / `main` 候補を legacy main 解決の順で探す:
/// 候補そのもの → `<候補>.js` → `<候補>/index.js`。Node 24.21.0 / 26.13.0 の
/// 実測では legacy main の拡張補完は `.js` / `.json` / `.node` と
/// `<候補>/index.js` のみ（`.mjs` は補完しない）。この実装は ESM 専用の
/// lnako 拡張として `<候補>.mjs` と `<候補>/index.mjs` も補完する
/// （docs/TODO.md の意図的差異）。`.json` / `.node` は ESM から import 属性
/// なしで直接 import できないため対象外。
///
/// 候補が無ければ null を返し、呼び出し側は次の優先候補へ進む。候補 path が
/// package root 外・絶対 path・`:` 等を含む場合は、Node の legacy 解決
/// （package root を出られる）より厳しく `PackageJsonInvalid` にする
/// （exports の不正 target と同じ分類・fail-closed）。候補が symlink で
/// canonical root の外を指す場合も、次候補へフォールバックせず
/// `PackageJsonInvalid` にする。
///
/// 末尾 separator 付きの候補（`"lib/"`）はディレクトリ指定として扱い、
/// `<候補>/index.js` / `<候補>/index.mjs` だけを試す（Node 実測:
/// `main:"lib/"` は `lib/index.js` を解決し、`lib.js` は試さない）。
/// strip 後に空になる `"./"` / `"././"` / `"/"` は候補なしとして次の候補へ
/// 進む（Node 実測（v24/v26）: `main:"/"` も package root の `index.js` へ
/// 到達する）。`<候補>/package.json` の `main` は Node の ESM legacy main も
/// 参照しないため解決しない（Node 実測: `lib/package.json` の main より
/// `lib/index.js` が優先）。
fn resolveLegacyEntry(gpa: Allocator, io: std.Io, root: []u8, raw_candidate: []const u8) Error!?ResolvedEntry {
    const cleaned = stripLeadingDotSlash(raw_candidate);
    // 末尾 separator を剥がす前に `\` を拒否する。`lib\` を `lib` として
    // `<候補>/index.js` に解決してしまうのを防ぐ（POSIX の Node は `\` を
    // 通常文字として扱うが、lnako は安全側で不正とする）。
    if (std.mem.indexOfScalar(u8, cleaned, '\\') != null) return error.PackageJsonInvalid;
    const trimmed = stripTrailingSeparators(cleaned);
    const directory_only = trimmed.len != cleaned.len;
    const candidate = trimmed;
    if (candidate.len == 0) return null;
    // `module` / `main` が root 外・絶対 path・`:` 等を含む場合は、Node の
    // legacy 解決（package root を出られる）より厳しく fail-closed にする。
    if (!entryPathIsContained(candidate)) return error.PackageJsonInvalid;

    if (!directory_only) {
        {
            const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, candidate });
            defer gpa.free(joined);
            if (fileExists(io, joined)) {
                const canonical = (try canonicalEntryPath(gpa, io, root, joined)) orelse return error.PackageJsonInvalid;
                return .{ .path = canonical, .package_root = root };
            }
        }

        for ([_][]const u8{ ".js", ".mjs" }) |ext| {
            const with_ext = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ root, candidate, ext });
            defer gpa.free(with_ext);
            if (fileExists(io, with_ext)) {
                const canonical = (try canonicalEntryPath(gpa, io, root, with_ext)) orelse return error.PackageJsonInvalid;
                return .{ .path = canonical, .package_root = root };
            }
        }
    }
    for ([_][]const u8{ "index.js", "index.mjs" }) |index_name| {
        const index_path = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ root, candidate, index_name });
        defer gpa.free(index_path);
        if (fileExists(io, index_path)) {
            const canonical = (try canonicalEntryPath(gpa, io, root, index_path)) orelse return error.PackageJsonInvalid;
            return .{ .path = canonical, .package_root = root };
        }
    }
    return null;
}

fn stripLeadingDotSlash(path: []const u8) []const u8 {
    var p = path;
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    return p;
}

/// `main` / `module` の末尾 separator を除く（`"lib/"` を `"lib"` にして
/// `<候補>/index.js` の結合を素直にする。Node 実測: `main:"lib/"` は
/// `lib/index.js` を解決する）。
fn stripTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    return path[0..end];
}

/// package root から `exports` のサブパス入口を解決する。`subpath` は
/// `name/sub` の `sub`（先頭 `./` 無し）。戻り値の分類は次の通り。
/// - `BareNotFound`: そのサブパスを公開していない（`null` target を含む）
/// - `PackageJsonInvalid`: package.json が不正（不正 JSON・root 非 object・
///   `name`/`type` 非文字列・exports キー混在・target が root 外/不正形式・
///   入口 symlink の root 外脱出）
/// - `InvalidSpecifier`: wildcard の一致部分が不正（配列 fallback でも継続
///   しない）、または `exports` 無しの `name/sub` の字句が不正
/// - `EntryNotFound`: target は妥当だがファイルが無い（`exports` 無しの
///   `name/sub` で拡張子補完・directory index 補完をしない結果も含む）
/// - `PackageJsonMissing`: registry 構築後に `package.json` が消えた場合
///
/// `exports` を持たない（または `exports` が string / array / object 以外の）
/// package の `name/sub` は、Node の ESM と同じく `<package_root>/<sub>` の
/// 厳密 path として解決する。`package_root_abs` は realpath へ canonicalize
/// し、解決した入口が canonical root の外（symlink 脱出）を指す場合は
/// `InvalidSpecifier` で fail-closed にする。
pub fn resolveSubpathInRoot(
    gpa: Allocator,
    io: std.Io,
    package_root_abs: []const u8,
    subpath: []const u8,
) Error!ResolvedEntry {
    if (!subpathIsSafe(subpath)) return error.BareNotFound;
    const root = try canonicalizePackageRoot(gpa, io, package_root_abs);
    errdefer gpa.free(root);

    const pj_bytes = try readPackageJson(gpa, io, root);
    defer gpa.free(pj_bytes);
    var manifest = try package_json_mod.parse(gpa, pj_bytes);
    defer manifest.deinit();

    // `exports` が string/array/object 以外（`null`・数値・真偽値）なら
    // Node と同じく exports 無し扱いになる。その場合のサブパスは
    // `<package_root>/<sub>` の従来解決（Node の ESM と同じ厳密 path）。
    const exports_v = manifest.exports orelse return resolveLegacySubpath(gpa, io, root, subpath);
    // サブパス専用 package でも、キーの混在は Node と同じく package.json 不正。
    if (exports_v == .object and !exportsKeysAreConsistent(exports_v.object)) return error.PackageJsonInvalid;
    switch (try pickExportsSubpath(gpa, exports_v, subpath)) {
        .target => |target| {
            defer gpa.free(target);
            const abs = try std.fs.path.join(gpa, &.{ root, target[2..] });
            defer gpa.free(abs);
            // exports の target は拡張子補完しない（Node の exports と同じく厳密 path）。
            if (!fileExists(io, abs)) return error.EntryNotFound;
            // symlink が canonical root の外を指すなら fail-closed。
            const canonical = (try canonicalEntryPath(gpa, io, root, abs)) orelse return error.PackageJsonInvalid;
            return .{ .path = canonical, .package_root = root };
        },
        .invalid => return error.PackageJsonInvalid,
        .excluded, .unresolved => return error.BareNotFound,
    }
}

/// `exports` を持たない package の `name/sub` を Node の ESM と同じく
/// `<package_root>/<sub>` の厳密 path として解決する。Node 準拠で拡張子
/// 補完（`.js` / `.mjs`）も `<sub>/index.js` フォールバックもしないため、
/// 該当ファイルが無い（またはディレクトリである）場合は `EntryNotFound`。
/// `sub` の字句が不正（制御文字・`:`・Windows drive letter 等）なら
/// `InvalidSpecifier`、symlink で canonical root の外へ脱出するなら同じく
/// `InvalidSpecifier` で fail-closed にする。
fn resolveLegacySubpath(gpa: Allocator, io: std.Io, root: []u8, subpath: []const u8) Error!ResolvedEntry {
    if (!entryPathIsContained(subpath)) return error.InvalidSpecifier;
    const abs = try std.fs.path.join(gpa, &.{ root, subpath });
    defer gpa.free(abs);
    if (!fileExists(io, abs)) return error.EntryNotFound;
    const canonical = (try canonicalEntryPath(gpa, io, root, abs)) orelse return error.InvalidSpecifier;
    return .{ .path = canonical, .package_root = root };
}

/// `module` / `main` / `index.js` の入口 path が package root 内の相対 path で
/// あることを検証する。絶対 path・NUL・制御文字・`/` と `\` のどちらで
/// 区切っても親セグメントになる path を拒否する（Windows の `..\` 対策）。
/// `foo..bar.js` のようなファイル名は許可する。
fn entryPathIsContained(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |byte| {
        // `unpack` と同じ規則: 制御文字と `:`（Windows の ADS 区切り）を拒否。
        if (byte < 0x20 or byte == 0x7f or byte == ':') return false;
    }
    if (path[0] == '/' or path[0] == '\\') return false;
    // Windows ドライブレター（`C:` / `C:\` / `C:/`）。
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return false;
    var segments = std.mem.tokenizeAny(u8, path, "/\\");
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

/// path が通常ファイルとして存在するか。ディレクトリは入口にしない
/// （`access` だけだと directory も存在扱いになる）。
fn fileExists(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

/// `realPathFileAlloc` の sentinel 付き slice を通常の gpa 所有 slice へ写す
/// （`ResolvedEntry` / `BarePackage` の field 型を `[]u8` に揃える）。
fn realPathOwned(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
    defer gpa.free(canonical);
    return try gpa.dupe(u8, canonical);
}

/// package root を realpath へ canonicalize する（symlink・`..` を実体 path に
/// 寄せる）。入口ファイルの包含検査と `module_graph` の realpath 比較を同じ
/// 座標系に揃えるため、`resolveEntryInRoot` / `resolveSubpathInRoot` の先頭で
/// 行う。不在・非 directory は `PackageJsonMissing`、その他の I/O 失敗は
/// `PackageJsonInvalid`（`readPackageJson` と同じ分類）。
fn canonicalizePackageRoot(gpa: Allocator, io: std.Io, package_root_abs: []const u8) Error![]u8 {
    return realPathOwned(gpa, io, package_root_abs) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.FileNotFound, error.NotDir => error.PackageJsonMissing,
        else => error.PackageJsonInvalid,
    };
}

/// 入口ファイルの実体 path を返し、canonical な package root の直系の子孫で
/// あることを検証する。symlink で root 外へ脱出する入口は null（呼び出し側が
/// 文脈に応じた分類を選ぶ: exports / legacy は `PackageJsonInvalid`、
/// `exports` 無し `name/sub` は `InvalidSpecifier`）。realpath 自体の失敗は
/// 入口不在を `EntryNotFound`、その他を `PackageJsonInvalid` に写す。
fn canonicalEntryPath(
    gpa: Allocator,
    io: std.Io,
    canonical_root: []const u8,
    lexical_abs: []const u8,
) Error!?[]u8 {
    const canonical = realPathOwned(gpa, io, lexical_abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        // `fileExists` 確認後の削除・差し替えは入口不在として扱う。
        error.FileNotFound, error.NotDir => return error.EntryNotFound,
        else => return error.PackageJsonInvalid,
    };
    errdefer gpa.free(canonical);
    if (!isStrictlyWithin(canonical_root, canonical)) {
        gpa.free(canonical);
        return null;
    }
    return canonical;
}

/// `child` が `parent` の直系の子孫（separator 境界）か。
/// `npm_env.isStrictlyWithin` と同じ separator 境界の規則に加えて、`parent`
/// 自身が separator で終わる場合（filesystem root の `/`、Windows の `C:\\`）
/// も直下の子を子孫として扱う。Windows の realpath が `/`・`\` のどちらも
/// 返し得るため `std.fs.path.isSep` で判定する。
fn isStrictlyWithin(parent: []const u8, child: []const u8) bool {
    if (parent.len == 0) return false;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (std.fs.path.isSep(parent[parent.len - 1])) return child.len > parent.len;
    return child.len > parent.len and std.fs.path.isSep(child[parent.len]);
}

test "isStrictlyWithin enforces separator boundary" {
    // 同一 path は子孫ではない。
    try testing.expect(!isStrictlyWithin("/pkg", "/pkg"));
    try testing.expect(!isStrictlyWithin("/", "/"));
    // 兄弟 prefix は separator 境界を満たさない。
    try testing.expect(!isStrictlyWithin("/pkg", "/pkg2/a.js"));
    // 通常の子孫。
    try testing.expect(isStrictlyWithin("/pkg", "/pkg/a.js"));
    try testing.expect(isStrictlyWithin("/pkg", "/pkg/sub/a.js"));
    // filesystem root は末尾が separator でも直下の子を子孫として扱う。
    try testing.expect(isStrictlyWithin("/", "/index.js"));
    // 空 parent は常に false。
    try testing.expect(!isStrictlyWithin("", "/index.js"));
}

/// registry に登録した 1 package。root 入口は registry 構築時に確定せず、
/// bare name の要求時に `resolveEntryForBare` で遅延解決する。これにより
/// `EntryNotFound` / `PackageJsonInvalid` / 非公開（`BareNotFound`）を Node の
/// import 解決と同じ分類で保持したまま、サブパス専用 package や壊れた
/// package.json を持つ package が registry 全体を落とさない。
pub const BarePackage = struct {
    /// package root の canonical 絶対 path（`package.json` がある dir）。
    package_root: []u8,

    pub fn deinit(self: BarePackage, gpa: Allocator) void {
        gpa.free(self.package_root);
    }
};

/// bare name → 解決済み入口。同一 context の instance 集合を保持する。
pub const BareRegistry = struct {
    gpa: Allocator,
    io: std.Io,
    /// bare name → BarePackage（arena ではなく gpa 所有）。
    by_name: std.StringHashMapUnmanaged(BarePackage) = .empty,
    /// canonical な package_root 絶対 path → bare name（npm 内 bare の
    /// context 復元用。`module_graph` の realpath 比較と同じ座標系）。
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
    /// 入口解決は行わないため、root 入口を持たない package（サブパス専用・
    /// package.json 破損・root target 欠落）も登録でき、registry 全体を
    /// 落とさない。root 入口は bare name の要求時に遅延解決する。
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
            // InvalidArchive は fail-closed の分類を保つため素通しする
            // （現行の呼出し側は npm_resolver.prepare のみ）。
            const tree = (tree_path_for(ctx, gpa, inst) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.InvalidArchive => return error.InvalidArchive,
                else => return error.CacheMiss,
            }) orelse return error.CacheMiss;
            defer gpa.free(tree);
            try reg.registerInstance(inst, tree);
        }
        return reg;
    }

    /// 1 instance の tree を registry へ登録する（遅延構築用）。同名が既に
    /// 登録済みなら何もしない。`tree` は呼出し側が所有し、この関数は複製する。
    pub fn registerInstance(self: *BareRegistry, instance: lock_model.NpmInstance, tree: []const u8) Error!void {
        if (self.by_name.contains(instance.name)) return;
        const package = try resolvePackageForRegistry(self.gpa, self.io, tree);
        {
            // `errdefer` はブロック内の失敗だけを対象にする。put 成功後は
            // registry が所有権を持つため、二重解放を避ける。
            errdefer package.deinit(self.gpa);
            const name_key = try self.gpa.dupe(u8, instance.name);
            errdefer self.gpa.free(name_key);
            try self.by_name.put(self.gpa, name_key, package);
        }
        if (!self.root_to_name.contains(package.package_root)) {
            const root_key = try self.gpa.dupe(u8, package.package_root);
            errdefer self.gpa.free(root_key);
            const name_val = try self.gpa.dupe(u8, instance.name);
            errdefer self.gpa.free(name_val);
            try self.root_to_name.put(self.gpa, root_key, name_val);
        }
    }

    /// bare specifier を解決する。返却の path/root は caller が `deinit` する。
    /// `name` は package root 入口、`name/sub` / `@scope/name/sub` は
    /// `package.json` の `exports` サブパス入口（`exports` が無ければ
    /// `<root>/<sub>` の従来解決）から解決する。root 入口は要求時に
    /// `resolveEntryForBare` で遅延解決する。
    pub fn resolveBare(self: *const BareRegistry, specifier: []const u8) Error!ResolvedEntry {
        const parsed = parseBareSpecifier(specifier) orelse return error.BareNotFound;
        const package = self.by_name.get(parsed.name) orelse return error.BareNotFound;
        if (parsed.subpath.len == 0) return resolveEntryForBare(self.gpa, self.io, package.package_root);
        return resolveSubpathInRoot(self.gpa, self.io, package.package_root, parsed.subpath);
    }
};

/// registry に登録済みの package root から bare name の入口を遅延解決する。
/// Node の import 解決に合わせた分類を返す:
/// - `package.json` が無い・`exports` が `"."` を公開しない: `BareNotFound`
/// - 入口ファイル（`exports` target / `main` / `module` / `index.js`）が無い:
///   `EntryNotFound`
/// - `package.json` 不正・root 外を指す target / symlink: `PackageJsonInvalid`
pub fn resolveEntryForBare(gpa: Allocator, io: std.Io, package_root: []const u8) Error!ResolvedEntry {
    return resolveEntryInRootWith(gpa, io, package_root, .registry);
}

/// instance の tree root から registry 登録用の package を作る。入口解決は
/// 行わず、`package_root` だけを canonical path で保持する（壊れた
/// package.json・root target 欠落の package も登録し、registry 全体を
/// 落とさない）。`npm_resolver` が instance 単位の entry 構築（#54 の
/// context 別解決）で再利用するため公開する。
/// `tree` が存在して realpath を取得できる場合は canonical path を、
/// できない場合だけ渡された path を複製して保持する（分類は遅延解決時の
/// `resolveEntryForBare` が行う）。
pub fn resolvePackageForRegistry(gpa: Allocator, io: std.Io, tree: []const u8) Error!BarePackage {
    const root = realPathOwned(gpa, io, tree) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return .{ .package_root = try gpa.dupe(u8, tree) },
    };
    return .{ .package_root = root };
}

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
        // `@/x` のような空 scope は package 名として扱わない。
        if (scope_slash == 0) return null;
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

/// instance を 1 行の診断にしたもの。cache miss 等の fail-closed 診断で
/// 「どの instance が欠けたか」を一意に示す（#54 の instance 単位診断）。
/// `key`（`name@version[#context]`）が主表記で、cache key は content key。
pub fn formatInstanceDiagnostic(
    gpa: Allocator,
    instance: lock_model.NpmInstance,
) Allocator.Error![]u8 {
    const key = try cacheKeyForInstance(gpa, instance);
    defer if (key) |owned| gpa.free(owned);
    return std.fmt.allocPrint(
        gpa,
        "npm instance {s}（cache key: {s}）",
        .{ instance.key, key orelse "unavailable" },
    );
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
        // 展開エラーは潰さずに透過する。呼出し側が構造不正（InvalidArchive 等）・
        // 上限超過（TooManyEntries 等）・OOM・Canceled・I/O をそれぞれの分類へ
        // 写像できるようにする（`npm_env` の materialize 経路と同じ taxonomy）。
        try unpack.extractTarGzInto(gpa, io, bytes, tree, .{ .strip_components = 1 });
    } else {
        try tree.writeFile(io, .{ .sub_path = "blob", .data = bytes });
    }
    tree.close(io);
    tree_open = false;
    staging.close(io);
    staging_open = false;
    try store.publishStaging(key);
}

pub fn looksLikeGzip(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b;
}

// 非公開 helper（`entryPathIsContained` / `pickExportsSubpath` /
// `max_exports_depth`）に依存する回帰テストは、定義と同じファイルに置く。

test "pickExportsSubpath resolves star in specifier via pattern" {
    const gpa = testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        \\{"exports":{"./a*":"./x/*.js"}}
    ,
        .{},
    );
    defer parsed.deinit();
    const exports_v = parsed.value.object.get("exports").?;

    // exact キーが無いためパターンに落ちる。matched は literal な `*` を
    // 含み得る（ファイルシステム上で `*` を含む名は Windows で作れないため、
    // 解決結果の文字列で検証する）。
    switch (try pickExportsSubpath(gpa, exports_v, "a*b")) {
        .target => |target| {
            defer gpa.free(target);
            try testing.expectEqualStrings("./x/*b.js", target);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "pickExportsSubpath は specifier の * をパターンとして解決する" {
    const gpa = testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        \\{"exports":{"./a*b":"./literal.js","./a*":"./wild/*.js"}}
    ,
        .{},
    );
    defer parsed.deinit();
    const exports_v = parsed.value.object.get("exports").?;
    switch (try pickExportsSubpath(gpa, exports_v, "a*b")) {
        .target => |target| {
            defer gpa.free(target);
            try testing.expectEqualStrings("./literal.js", target);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "pickExportsSubpath は target 不正を一致部分の不正より先に返す" {
    const gpa = testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        \\{"exports":{"./*":"../evil.js"}}
    ,
        .{},
    );
    defer parsed.deinit();
    const exports_v = parsed.value.object.get("exports").?;
    // Node 実測: ERR_INVALID_PACKAGE_TARGET（一致部分の node_modules より先）。
    switch (try pickExportsSubpath(gpa, exports_v, "node_modules/x")) {
        .invalid => {},
        else => return error.TestUnexpectedResult,
    }
}

test "pickExportsSubpath は未解決 target でも不正な一致部分を拒否する" {
    const gpa = testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        \\{"exports":{"./*":{"node":"./x.js"}}}
    ,
        .{},
    );
    defer parsed.deinit();
    const exports_v = parsed.value.object.get("exports").?;
    // node 条件は暗黙有効にしないため unresolved。ただし一致部分が
    // node_modules なので Node は ERR_INVALID_MODULE_SPECIFIER。
    try testing.expectError(error.InvalidSpecifier, pickExportsSubpath(gpa, exports_v, "node_modules/x"));
}

test "entryPathIsContained rejects parent segments in both separators" {
    try testing.expect(entryPathIsContained("index.js"));
    try testing.expect(entryPathIsContained("dist/foo..bar.js"));
    try testing.expect(entryPathIsContained("lib/mod.js"));
    try testing.expect(entryPathIsContained("lib\\mod.js"));
    try testing.expect(!entryPathIsContained("../x.js"));
    try testing.expect(!entryPathIsContained("a/../b.js"));
    try testing.expect(!entryPathIsContained(".."));
    try testing.expect(!entryPathIsContained("..\\x.js"));
    try testing.expect(!entryPathIsContained("a\\..\\x.js"));
    try testing.expect(!entryPathIsContained("/x.js"));
    try testing.expect(!entryPathIsContained("\\x.js"));
    try testing.expect(!entryPathIsContained("C:\\x.js"));
    try testing.expect(!entryPathIsContained("C:/x.js"));
    try testing.expect(!entryPathIsContained("index.js:s"));
    try testing.expect(!entryPathIsContained("a\x00b.js"));
    try testing.expect(!entryPathIsContained(""));
}

test "package.json の深い exports ネストは PackageJsonInvalid" {
    const gpa = testing.allocator;
    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"exports\":");
    var i: usize = 0;
    while (i < max_exports_depth + 4) : (i += 1) try json.append(gpa, '[');
    try json.appendSlice(gpa, "\"./index.js\"");
    i = 0;
    while (i < max_exports_depth + 4) : (i += 1) try json.append(gpa, ']');
    try json.append(gpa, '}');
    try testing.expectError(error.PackageJsonInvalid, pickEntryFromPackageJson(gpa, json.items));
}

test "package.json の exports 深度は境界ちょうどまで受理する" {
    const gpa = testing.allocator;
    // 64 段の配列ネスト（最深の文字列は depth 64）は受理する。
    var ok: std.ArrayListUnmanaged(u8) = .empty;
    defer ok.deinit(gpa);
    try ok.appendSlice(gpa, "{\"exports\":");
    var i: usize = 0;
    while (i < max_exports_depth) : (i += 1) try ok.append(gpa, '[');
    try ok.appendSlice(gpa, "\"./index.js\"");
    i = 0;
    while (i < max_exports_depth) : (i += 1) try ok.append(gpa, ']');
    try ok.append(gpa, '}');
    var entry = (try pickEntryFromPackageJson(gpa, ok.items)) orelse return error.TestUnexpectedResult;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("./index.js", entry.target);

    // 65 段は PackageJsonInvalid。
    var too_deep: std.ArrayListUnmanaged(u8) = .empty;
    defer too_deep.deinit(gpa);
    try too_deep.appendSlice(gpa, "{\"exports\":");
    i = 0;
    while (i < max_exports_depth + 1) : (i += 1) try too_deep.append(gpa, '[');
    try too_deep.appendSlice(gpa, "\"./index.js\"");
    i = 0;
    while (i < max_exports_depth + 1) : (i += 1) try too_deep.append(gpa, ']');
    try too_deep.append(gpa, '}');
    try testing.expectError(error.PackageJsonInvalid, pickEntryFromPackageJson(gpa, too_deep.items));
}

test {
    // #53: package.json 本格パースの回帰テスト
    _ = @import("npm_esm_test.zig");
    // #54: #53 以前に npm_esm.zig 内へあった回帰テストの分離先
    _ = @import("npm_esm_registry_test.zig");
    _ = @import("npm_esm_entry_test.zig");
}
