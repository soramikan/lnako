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
//! ただし Node の「`exports` 無し package の `name/sub` 従来解決」は実装して
//! おらず、`BareNotFound` として拒否する（安全側。docs/TODO.md に記録）。
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
pub fn resolveEntryInRoot(gpa: Allocator, io: std.Io, package_root_abs: []const u8) Error!ResolvedEntry {
    const root = try gpa.dupe(u8, package_root_abs);
    errdefer gpa.free(root);

    const pj_bytes = try readPackageJson(gpa, io, root);
    defer gpa.free(pj_bytes);

    var manifest = try package_json_mod.parse(gpa, pj_bytes);
    defer manifest.deinit();

    if (manifest.exports) |exports_v| {
        const picked = switch (try resolveExportsRoot(gpa, exports_v)) {
            .target => |target| target,
            .excluded, .unresolved => return error.EntryNotFound,
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
        // exports の target は拡張子補完しない（Node の exports と同じく厳密 path）。
        if (!fileExists(io, abs)) {
            gpa.free(abs);
            return error.EntryNotFound;
        }
        return .{ .path = abs, .package_root = root };
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
    if (!fileExists(io, index_path)) {
        gpa.free(index_path);
        return error.EntryNotFound;
    }
    return .{ .path = index_path, .package_root = root };
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
/// （exports の不正 target と同じ分類・fail-closed）。
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
        const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, candidate });
        if (fileExists(io, joined)) return .{ .path = joined, .package_root = root };
        gpa.free(joined);

        for ([_][]const u8{ ".js", ".mjs" }) |ext| {
            const with_ext = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ root, candidate, ext });
            if (fileExists(io, with_ext)) return .{ .path = with_ext, .package_root = root };
            gpa.free(with_ext);
        }
    }
    for ([_][]const u8{ "index.js", "index.mjs" }) |index_name| {
        const index_path = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ root, candidate, index_name });
        if (fileExists(io, index_path)) return .{ .path = index_path, .package_root = root };
        gpa.free(index_path);
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
///   `name`/`type` 非文字列・exports キー混在・target が root 外/不正形式）
/// - `InvalidSpecifier`: wildcard の一致部分が不正（配列 fallback でも継続しない）
/// - `EntryNotFound`: target は妥当だがファイルが無い
/// - `PackageJsonMissing`: registry 構築後に `package.json` が消えた場合
/// `exports` を持たない package の `name/sub` は Node の従来解決に対応せず
/// `BareNotFound` にする（安全側。docs/TODO.md に未対応境界として記録）。
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
    var manifest = try package_json_mod.parse(gpa, pj_bytes);
    defer manifest.deinit();

    // `exports` が string/array/object 以外（`null`・数値・真偽値）なら
    // Node と同じく exports 無し扱いで、サブパスは公開されない。
    const exports_v = manifest.exports orelse return error.BareNotFound;
    // サブパス専用 package でも、キーの混在は Node と同じく package.json 不正。
    if (exports_v == .object and !exportsKeysAreConsistent(exports_v.object)) return error.PackageJsonInvalid;
    switch (try pickExportsSubpath(gpa, exports_v, subpath)) {
        .target => |target| {
            defer gpa.free(target);
            const abs = try std.fs.path.join(gpa, &.{ root, target[2..] });
            errdefer gpa.free(abs);
            // exports の target は拡張子補完しない（Node の exports と同じく厳密 path）。
            if (!fileExists(io, abs)) return error.EntryNotFound;
            return .{ .path = abs, .package_root = root };
        },
        .invalid => return error.PackageJsonInvalid,
        .excluded, .unresolved => return error.BareNotFound,
    }
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

/// registry に登録した 1 package。root 入口は必須ではない。exports が
/// サブパスのみを公開し、`module` / `main` / `index.js` も無い package は
/// `root_path = null` として登録し、サブパスだけを解決可能にする。
pub const BarePackage = struct {
    /// package root 絶対 path（`package.json` がある dir）。
    package_root: []u8,
    /// root 入口の絶対 path。root を公開しない package は null。
    root_path: ?[]u8,

    pub fn deinit(self: BarePackage, gpa: Allocator) void {
        gpa.free(self.package_root);
        if (self.root_path) |path| gpa.free(path);
    }
};

/// bare name → 解決済み入口。同一 context の instance 集合を保持する。
pub const BareRegistry = struct {
    gpa: Allocator,
    io: std.Io,
    /// bare name → BarePackage（arena ではなく gpa 所有）。
    by_name: std.StringHashMapUnmanaged(BarePackage) = .empty,
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
    /// root 入口を解決できないサブパス専用 package も、そのサブパスを解決
    /// できるよう registry へ登録する（root 解決の失敗で registry 全体を
    /// 落とさない）。
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
    /// `package.json` の `exports` サブパス入口から解決する。root 入口を
    /// 持たない package（exports がサブパスのみ）の `name` は `BareNotFound`。
    pub fn resolveBare(self: *const BareRegistry, specifier: []const u8) Error!ResolvedEntry {
        const parsed = parseBareSpecifier(specifier) orelse return error.BareNotFound;
        const package = self.by_name.get(parsed.name) orelse return error.BareNotFound;
        if (parsed.subpath.len == 0) {
            const root_path = package.root_path orelse return error.BareNotFound;
            const path = try self.gpa.dupe(u8, root_path);
            errdefer self.gpa.free(path);
            return .{
                .path = path,
                .package_root = try self.gpa.dupe(u8, package.package_root),
            };
        }
        return resolveSubpathInRoot(self.gpa, self.io, package.package_root, parsed.subpath);
    }
};

/// instance の tree root から registry 登録用の package を作る。root 入口を
/// 解決できない package（サブパス専用・root target 欠落・package.json 破損）は
/// `root_path = null` として登録し、registry 全体を落とさない。root の
/// エラー分類（`EntryNotFound` / `PackageJsonInvalid` の保持）は
/// docs/TODO.md の follow-up（遅延解決）で扱う。`npm_resolver` が instance
/// 単位の entry 構築（#54 の context 別解決）で再利用するため公開する。
pub fn resolvePackageForRegistry(gpa: Allocator, io: std.Io, tree: []const u8) Error!BarePackage {
    const resolved = resolveEntryInRoot(gpa, io, tree) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EntryNotFound, error.PackageJsonMissing, error.PackageJsonInvalid => return .{
            .package_root = try gpa.dupe(u8, tree),
            .root_path = null,
        },
        else => return err,
    };
    return .{ .package_root = resolved.package_root, .root_path = resolved.path };
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

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "pickEntryFromPackageJson exports string" {
    const gpa = testing.allocator;
    const entry = (try pickEntryFromPackageJson(gpa, "{\"exports\":\"./dist/index.mjs\"}")).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("./dist/index.mjs", entry.target);
    try testing.expect(entry.from_exports);
}

test "pickEntryFromPackageJson rejects exports target without ./" {
    const gpa = testing.allocator;
    // Node の exports target は `./` 前置の相対 path でなければならない。
    try testing.expectError(error.PackageJsonInvalid, pickEntryFromPackageJson(gpa, "{\"exports\":\"dist/index.mjs\"}"));
}

test "pickEntryFromPackageJson exports import condition ignores node" {
    const gpa = testing.allocator;
    const json =
        \\{"exports":{".":{"node":"./node.js","import":"./esm.mjs","default":"./default.js"}}}
    ;
    const entry = (try pickEntryFromPackageJson(gpa, json)).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("./esm.mjs", entry.target);
}

test "pickEntryFromPackageJson exports conditions follow insertion order" {
    const gpa = testing.allocator;
    // `import` 固定優先にせず、object の挿入順で最初の一致を使う。
    const json =
        \\{"exports":{"default":"./a.js","import":"./b.mjs"}}
    ;
    const entry = (try pickEntryFromPackageJson(gpa, json)).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("./a.js", entry.target);
}

test "pickEntryFromPackageJson exports null condition stops lookup" {
    const gpa = testing.allocator;
    const json =
        \\{"exports":{".":{"import":null,"default":"./x.js"}}}
    ;
    // 一致した条件の値が null なら、そこで非公開（default へ進まない）。
    const picked = try pickEntryFromPackageJson(gpa, json);
    if (picked) |entry| entry.deinit(gpa);
    try testing.expect(picked == null);
}

test "pickEntryFromPackageJson does not pick browser alone" {
    const gpa = testing.allocator;
    const json =
        \\{"exports":{".":{"browser":"./browser.js","require":"./cjs.js"}},"main":"lib/main.js"}
    ;
    // import/default が一致しない exports は root を公開しない
    // （`module` / `main` / `index.js` へはフォールバックしない）。
    const picked = try pickEntryFromPackageJson(gpa, json);
    if (picked) |entry| entry.deinit(gpa);
    try testing.expect(picked == null);
}

test "pickEntryFromPackageJson treats scalar exports as absent" {
    const gpa = testing.allocator;
    // Node は exports が string / array / object 以外なら exports 無しとして
    // module/main/index.js の従来解決へ落とす。
    for ([_][]const u8{
        "{\"exports\":5,\"main\":\"lib/main.js\"}",
        "{\"exports\":false,\"main\":\"lib/main.js\"}",
        "{\"exports\":null,\"main\":\"lib/main.js\"}",
    }) |json| {
        const entry = (try pickEntryFromPackageJson(gpa, json)).?;
        defer entry.deinit(gpa);
        try testing.expectEqualStrings("lib/main.js", entry.target);
        try testing.expect(!entry.from_exports);
    }
}

test "pickEntryFromPackageJson module field" {
    const gpa = testing.allocator;
    const entry = (try pickEntryFromPackageJson(gpa, "{\"module\":\"lib/mod.mjs\",\"main\":\"lib/mod.js\"}")).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("lib/mod.mjs", entry.target);
    try testing.expect(!entry.from_exports);
}

test "pickEntryFromPackageJson exports array" {
    const gpa = testing.allocator;
    // root exports の配列 fallback（不正 target は飛ばす）。
    const entry = (try pickEntryFromPackageJson(gpa, "{\"exports\":[\"../evil.js\",\"./a.js\"]}")).?;
    defer entry.deinit(gpa);
    try testing.expectEqualStrings("./a.js", entry.target);
    try testing.expect(entry.from_exports);
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
    errdefer gpa.free(name);
    const entry = try resolveEntryInRoot(gpa, io, pkg_root);
    try reg.by_name.put(gpa, name, .{ .package_root = entry.package_root, .root_path = entry.path });

    const got = try reg.resolveBare("left-pad");
    defer got.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, got.path, "index.js"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("missing"));
}

/// テスト用 fixture の追加ファイル。
const TestFile = struct { path: []const u8, data: []const u8 };

/// テスト用: `dir/package.json` と追加ファイルを作り registry へ登録する。
/// `create_root_index` が false の fixture は root 入口を持たない package に
/// なる（exports がサブパスのみを公開する package など）。
fn makeTestRegistryWithRoot(
    gpa: Allocator,
    io: std.Io,
    tmp: *testing.TmpDir,
    dir: []const u8,
    name: []const u8,
    package_json: []const u8,
    files: []const TestFile,
    create_root_index: bool,
) !BareRegistry {
    try tmp.dir.createDirPath(io, dir);
    const pj = try std.fs.path.join(gpa, &.{ dir, "package.json" });
    defer gpa.free(pj);
    try tmp.dir.writeFile(io, .{ .sub_path = pj, .data = package_json });
    if (create_root_index) {
        const root_index = try std.fs.path.join(gpa, &.{ dir, "index.js" });
        defer gpa.free(root_index);
        try tmp.dir.writeFile(io, .{ .sub_path = root_index, .data = "export default 1;\n" });
    }
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
    // root 入口を解決できない fixture もサブパス専用 package として登録する。
    const package = try resolvePackageForRegistry(gpa, io, root);
    errdefer package.deinit(gpa);
    const key = try gpa.dupe(u8, name);
    errdefer gpa.free(key);
    try reg.by_name.put(gpa, key, package);
    return reg;
}

fn makeTestRegistry(
    gpa: Allocator,
    io: std.Io,
    tmp: *testing.TmpDir,
    dir: []const u8,
    name: []const u8,
    package_json: []const u8,
    files: []const TestFile,
) !BareRegistry {
    return makeTestRegistryWithRoot(gpa, io, tmp, dir, name, package_json, files, true);
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
    // 公開キーに一致しない深いサブパスは非公開。
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

test "BareRegistry resolveBare rejects invalid export targets as PackageJsonInvalid" {
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

    // 「未公開（BareNotFound）」と「壊れた/悪意ある package.json」を区別する。
    for ([_][]const u8{
        "left-pad/up",
        "left-pad/nested-up",
        "left-pad/abs",
        "left-pad/node-modules",
        "left-pad/bare-target",
        "left-pad/dot",
    }) |spec| {
        try testing.expectError(error.PackageJsonInvalid, reg.resolveBare(spec));
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

    // wildcard は複数セグメントにも一致し、target の `*` を置換する。
    const deep = try reg.resolveBare("left-pad/features/a/b");
    defer deep.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, deep.path, "feat/a/b.mjs"));

    // trailing slash target（空セグメント）は不正な target。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/slash"));
    // Windows ドライブレター target は不正な target。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/drive"));
    // `*` は 1 文字以上: 空マッチは非公開。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/ab"));
}

// --- PR #225 レビュー指摘の回帰テスト（M1/M2 + correctness minor） ---

test "BareRegistry resolveBare wildcard requires one character (M1 example 1)" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./foo*":"./foo*.js"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "foo.js", .data = "export default 1;\n" },
        .{ .path = "foobar.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // `*` は 1 文字以上: `pkg/foo` は非公開（Node: ERR_PACKAGE_PATH_NOT_EXPORTED）。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/foo"));
    const bar = try reg.resolveBare("left-pad/foobar");
    defer bar.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, bar.path, "foobar.js"));
}

test "BareRegistry resolveBare wildcard does not hide on empty match (M1 example 2)" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./features/*":"./src/*.js","./features/private*":null}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "src/private.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // 空マッチした `private*` が prefix 最長として選ばれてはならない。
    const priv = try reg.resolveBare("left-pad/features/private");
    defer priv.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, priv.path, "src/private.js"));
    // 1 文字以上マッチするなら null target が勝って非公開になる。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/features/privatex"));
}

test "BareRegistry resolveBare wildcard prefix tie prefers longer key" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./feat*":"./generic/*.mjs","./feat*x":"./specific/*.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "generic/abx.mjs", .data = "export default 1;\n" },
        .{ .path = "specific/ab.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // prefix 長が同じなら key が長い `./feat*x` が勝つ（Node の patternKeyCompare）。
    const got = try reg.resolveBare("left-pad/featabx");
    defer got.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, got.path, "specific/ab.mjs"));
}

test "BareRegistry resolveBare substitutes every star in target" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./f/*":"./x/*/*.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "x/a/a.mjs", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    const got = try reg.resolveBare("left-pad/f/a");
    defer got.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, got.path, "x/a/a.mjs"));
}

test "BareRegistry resolveBare conditions follow insertion order" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./cond":{"default":"./a.js","import":"./b.mjs"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "a.js", .data = "export default 1;\n" },
        .{ .path = "b.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // `import` を固定優先せず、object の挿入順で最初の一致を使う。
    const got = try reg.resolveBare("left-pad/cond");
    defer got.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, got.path, "a.js"));
}

test "BareRegistry resolveBare null condition stops lookup" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./hidden":{"import":null,"default":"./fallback.js"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "fallback.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // 一致した条件の値が null なら、そこで非公開（default へ進まない）。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/hidden"));
}

test "BareRegistry resolveBare array fallback skips invalid targets" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./sub":["../evil.js","./ok.mjs"],"./bad":["../evil.js"]}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "ok.mjs", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // 不正な候補は飛ばして次の候補を使う（Node の配列 fallback）。
    const ok = try reg.resolveBare("left-pad/sub");
    defer ok.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, ok.path, "ok.mjs"));
    // 全候補が不正なら「未公開」ではなく package.json 不正として分類する。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/bad"));
}

test "BareRegistry resolveBare classifies invalid export targets" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        "{\"exports\":{\".\":\"./index.js\",\"./up\":\"../evil.js\"," ++
        "\"./abs\":\"/tmp/evil.js\",\"./node-modules\":\"./node_modules/evil.js\"," ++
        "\"./upper-node-modules\":\"./NODE_MODULES/evil.js\",\"./bare\":\"dist/sub.mjs\"," ++
        "\"./ads\":\"./index.js:s\",\"./control\":\"./dist/a\\u0001.mjs\"," ++
        "\"./nul\":\"./dist/a\\u0000.mjs\",\"./backslash\":\"./dist/a\\\\b.mjs\"}}";
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{});
    defer reg.deinit();

    for ([_][]const u8{
        "left-pad/up",
        "left-pad/abs",
        "left-pad/node-modules",
        "left-pad/upper-node-modules",
        "left-pad/bare",
        "left-pad/ads",
        "left-pad/control",
        "left-pad/nul",
        "left-pad/backslash",
    }) |spec| {
        try testing.expectError(error.PackageJsonInvalid, reg.resolveBare(spec));
    }
}

test "BareRegistry resolveBare classifies scalar targets as PackageJsonInvalid" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./scalar":{"import":true,"default":"./x.js"},"./num":5}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "x.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // Node は string / array / null / object 以外の target を
    // ERR_INVALID_PACKAGE_TARGET にする（default へ進まない）。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/scalar"));
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/num"));
}

test "BareRegistry resolveBare rejects array index condition keys" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./idx":{"0":"./a.js","default":"./x.js"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "x.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // Node は条件オブジェクトの配列 index キーを ERR_INVALID_PACKAGE_CONFIG に
    // する（配列 fallback でも飛ばさない）。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/idx"));
}

test "BareRegistry resolveBare array index boundary keys" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./max":{"4294967294":"./a.js","default":"./x.js"},"./over":{"4294967295":"./a.js","default":"./x.js"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "x.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // Node の isArrayIndex は 2^32-2 までを index とする（`4294967295` は違う）。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/max"));
    const over = try reg.resolveBare("left-pad/over");
    defer over.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, over.path, "x.js"));
}

test "BareRegistry resolveBare duplicate keys use last value" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./sub":"./a.js","./sub":"./b.js"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "a.js", .data = "export default 1;\n" },
        .{ .path = "b.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // JS の JSON.parse と同じく後勝ち（Node 実測: b.js）。
    const got = try reg.resolveBare("left-pad/sub");
    defer got.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, got.path, "b.js"));
}

test "BareRegistry resolveBare array last exception decides" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./last-null":["../evil.js",null],"./last-invalid":[null,"../evil.js"]}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{});
    defer reg.deinit();

    // Node: 最後の例外が null なら非公開、不正 target なら package.json 不正。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/last-null"));
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/last-invalid"));
}

test "BareRegistry resolveBare rejects numeric key after matching condition" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./sub":{"import":"./a.js","0":"./b.js"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "a.js", .data = "export default 1;\n" },
        .{ .path = "b.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // Node は条件マッチング前に全キーを検査する（import が先でも拒否）。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/sub"));
}

test "BareRegistry resolveBare array skips scalar but not numeric key error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./scalar":[true,"./x.js"],"./numeric":[{"0":"./a.js"},"./x.js"]}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "x.js", .data = "export default 1;\n" },
        .{ .path = "a.js", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // スカラー target は配列で飛ばす（Node: ERR_INVALID_PACKAGE_TARGET → continue）。
    const scalar = try reg.resolveBare("left-pad/scalar");
    defer scalar.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, scalar.path, "x.js"));
    // 数値キーは package.json 不正で、配列でも飛ばさない。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/numeric"));
}

test "BareRegistry resolveBare rejects node_modules in wildcard match" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./*":["./a/*.js","./fallback.js"]}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "fallback.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // Node: ERR_INVALID_MODULE_SPECIFIER。配列 fallback で後続候補へ進まない。
    try testing.expectError(error.InvalidSpecifier, reg.resolveBare("left-pad/node_modules/x"));
}

test "BareRegistry resolveBare keeps longer prefix key seen first" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./feat*x":"./specific/*.mjs","./feat*":"./generic/*.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "specific/ab.mjs", .data = "export default 1;\n" },
        .{ .path = "generic/abx.mjs", .data = "export default 2;\n" },
    });
    defer reg.deinit();

    // 長いキーが先に出てきても、後の短いキーで上書きしない。
    const got = try reg.resolveBare("left-pad/featabx");
    defer got.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, got.path, "specific/ab.mjs"));
}

test "BareRegistry resolveBare root-less fixture without index.js" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./app":"./app.mjs"}}
    ;
    // `index.js` を書かない fixture。root 入口は存在しない。
    var reg = try makeTestRegistryWithRoot(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "app.mjs", .data = "export default 1;\n" },
    }, false);
    defer reg.deinit();

    const app = try reg.resolveBare("left-pad/app");
    defer app.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, app.path, "app.mjs"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad"));
}

test "resolveEntryInRoot rejects directory as entry file" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "dist");
    // `dist.js` があっても exports は拡張子補完しない（Node は厳密 path）。
    try tmp.dir.writeFile(io, .{ .sub_path = "dist.js", .data = "export default 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{\"exports\":\"./dist\"}" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    try testing.expectError(error.EntryNotFound, resolveEntryInRoot(gpa, io, root));
}

test "resolveEntryInRoot does not probe extensions for exports targets" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":"./dist/index"}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = json });
    try tmp.dir.createDirPath(io, "dist");
    try tmp.dir.writeFile(io, .{ .sub_path = "dist/index.js", .data = "export default 1;\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    // exports target は拡張子補完しない（Node: ERR_MODULE_NOT_FOUND）。
    try testing.expectError(error.EntryNotFound, resolveEntryInRoot(gpa, io, root));
}

test "resolveEntryInRoot does not fall back to main when exports hides root" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./app":"./app.mjs"},"main":"index.js"}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = json });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.mjs", .data = "export default 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "index.js", .data = "export default 2;\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    // exports がある package は root 入口を exports からのみ選ぶ（Node と同じ）。
    try testing.expectError(error.EntryNotFound, resolveEntryInRoot(gpa, io, root));
}

test "resolveEntryInRoot rejects exports target outside root" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{\"exports\":\"./../evil.js\"}" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    try testing.expectError(error.PackageJsonInvalid, resolveEntryInRoot(gpa, io, root));
}

test "pickEntryFromPackageJson rejects mixed exports keys" {
    const gpa = testing.allocator;
    // Node は `.` 前置キーと条件キーの混在を ERR_INVALID_PACKAGE_CONFIG にする。
    try testing.expectError(error.PackageJsonInvalid, pickEntryFromPackageJson(
        gpa,
        "{\"exports\":{\".\":\"./index.js\",\"import\":\"./esm.mjs\"}}",
    ));
}

test "BareRegistry resolveBare empty array target is unpublished" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./empty":[],"./cond-empty":{"import":[],"default":"./ok.mjs"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "ok.mjs", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // Node は空配列 target を null（非公開）として即座に確定する
    // （`default` へは進まない）。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/empty"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/cond-empty"));
}

test "resolveSubpathInRoot rejects mixed exports keys" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"./sub":"./sub.mjs","import":"./esm.mjs"}}
    ;
    // package_json 自体が不正なので registry 構築を経ずに直接検査する。
    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/package.json", .data = json });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/sub.mjs", .data = "export default 1;\n" });
    const root = try tmp.dir.realPathFileAlloc(io, "pkg", gpa);
    defer gpa.free(root);

    try testing.expectError(error.PackageJsonInvalid, resolveSubpathInRoot(gpa, io, root, "sub"));
}

test "BareRegistry resolveBare top-level conditions exports" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{"import":"./esm.mjs","default":"./index.js"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "esm.mjs", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    const root = try reg.resolveBare("left-pad");
    defer root.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, root.path, "esm.mjs"));
    // 条件オブジェクトは root 専用で、サブパスは公開されない。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/sub"));
}

test "BareRegistry resolveBare without exports rejects subpath" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", "{\"main\":\"index.js\"}", &.{});
    defer reg.deinit();

    const root = try reg.resolveBare("left-pad");
    defer root.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, root.path, "index.js"));
    // Node の従来 subpath 解決は未対応（安全側で拒否）。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/sub"));
}

test "parseBareSpecifier rejects empty scope and empty name" {
    try testing.expect(parseBareSpecifier("@/x") == null);
    try testing.expect(parseBareSpecifier("@scope/") == null);
    try testing.expect(parseBareSpecifier("@scope//x") == null);
    try testing.expect(parseBareSpecifier("@scope") == null);
    try testing.expect(parseBareSpecifier("@") == null);
    try testing.expect(parseBareSpecifier("/x") == null);
    try testing.expect(parseBareSpecifier("./x") == null);
}

test "parseBareSpecifier splits scoped subpath" {
    const scoped = parseBareSpecifier("@scope/pkg/sub").?;
    try testing.expectEqualStrings("@scope/pkg", scoped.name);
    try testing.expectEqualStrings("sub", scoped.subpath);
    const scoped_root = parseBareSpecifier("@scope/pkg").?;
    try testing.expectEqualStrings("@scope/pkg", scoped_root.name);
    try testing.expectEqualStrings("", scoped_root.subpath);
    const plain = parseBareSpecifier("pkg/sub/deep").?;
    try testing.expectEqualStrings("pkg", plain.name);
    try testing.expectEqualStrings("sub/deep", plain.subpath);
}

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

test "BareRegistry resolveBare null target precedes specifier validation" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./*":null}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{});
    defer reg.deinit();

    // Node 実測（v24/v26）: `"./*": null` + `pkg/node_modules/x` は
    // ERR_PACKAGE_PATH_NOT_EXPORTED。一致部分の検証より null が先。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/node_modules/x"));
}

test "BareRegistry resolveBare rejects colon and control chars in wildcard match" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./*":"./a/*.js"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{});
    defer reg.deinit();

    // Node は警告のみで通すが、この実装は fail-closed（docs/TODO.md）。
    try testing.expectError(error.InvalidSpecifier, reg.resolveBare("left-pad/a:b"));
    try testing.expectError(error.InvalidSpecifier, reg.resolveBare("left-pad/a\x01b"));
    // 空セグメントは specifier の段階で bare として拒否する。
    try testing.expect(parseBareSpecifier("left-pad/x//y") == null);
}

test "BareRegistry resolveBare empty string exports is invalid" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", "{\"exports\":\"\"}", &.{});
    defer reg.deinit();

    // Node 実測（v24/v26）: `exports: ""` は root で ERR_INVALID_PACKAGE_TARGET、
    // サブパスは sugar 経由で ERR_PACKAGE_PATH_NOT_EXPORTED。
    try testing.expectError(error.PackageJsonInvalid, pickEntryFromPackageJson(gpa, "{\"exports\":\"\"}"));
    // registry は root 解決の失敗を root 非公開へ丸めるため BareNotFound。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/sub"));
}

test "BareRegistry resolveBare nested unresolved condition falls through" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./sub":{"import":{"node":"./x.js"},"default":"./y.js"}}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "y.js", .data = "export default 1;\n" },
    });
    defer reg.deinit();

    // 一致した `import` の値が未解決なら、挿入順で次の一致キー（default）へ進む。
    const got = try reg.resolveBare("left-pad/sub");
    defer got.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, got.path, "y.js"));
}

const TestInstanceTrees = struct {
    paths: []const struct { name: []const u8, path: []const u8 },

    fn treePath(ctx: *anyopaque, gpa: Allocator, instance: lock_model.NpmInstance) anyerror!?[]u8 {
        const self: *const TestInstanceTrees = @ptrCast(@alignCast(ctx));
        for (self.paths) |entry| {
            if (std.mem.eql(u8, entry.name, instance.name)) return try gpa.dupe(u8, entry.path);
        }
        return null;
    }
};

test "BareRegistry registerInstance は同名を no-op にする" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_]struct { dir: []const u8, version: []const u8 }{
        .{ .dir = "first", .version = "1.0.0" },
        .{ .dir = "second", .version = "2.0.0" },
    }) |entry| {
        try tmp.dir.createDirPath(io, entry.dir);
        const json = try std.fmt.allocPrint(gpa, "{{\"version\":\"{s}\",\"main\":\"index.js\"}}", .{entry.version});
        defer gpa.free(json);
        const manifest_path = try std.fmt.allocPrint(gpa, "{s}/package.json", .{entry.dir});
        defer gpa.free(manifest_path);
        const source_path = try std.fmt.allocPrint(gpa, "{s}/index.js", .{entry.dir});
        defer gpa.free(source_path);
        try tmp.dir.writeFile(io, .{ .sub_path = manifest_path, .data = json });
        try tmp.dir.writeFile(io, .{ .sub_path = source_path, .data = "export default 1;\n" });
    }
    const first_root = try tmp.dir.realPathFileAlloc(io, "first", gpa);
    defer gpa.free(first_root);
    const second_root = try tmp.dir.realPathFileAlloc(io, "second", gpa);
    defer gpa.free(second_root);

    var reg: BareRegistry = .{ .gpa = gpa, .io = io };
    defer reg.deinit();
    const first = lock_model.NpmInstance{ .key = "pkg@1.0.0", .name = "pkg", .version = "1.0.0" };
    const second = lock_model.NpmInstance{ .key = "pkg@2.0.0", .name = "pkg", .version = "2.0.0" };
    try reg.registerInstance(first, first_root);
    try reg.registerInstance(second, second_root);
    const entry = try reg.resolveBare("pkg");
    defer entry.deinit(gpa);
    const entry_dir = std.fs.path.dirname(entry.path) orelse return error.UnexpectedResult;
    try testing.expectEqualStrings("first", std.fs.path.basename(entry_dir));
}

test "BareRegistry buildFromInstances registers subpath-only package (M2)" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.createDirPath(io, "subonly");
    try tmp.dir.writeFile(io, .{ .sub_path = "subonly/package.json", .data = "{\"exports\":{\"./app\":\"./app.mjs\"}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "subonly/app.mjs", .data = "export default 1;\n" });
    try tmp.dir.createDirPath(io, "rooted");
    try tmp.dir.writeFile(io, .{ .sub_path = "rooted/package.json", .data = "{\"main\":\"index.js\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "rooted/index.js", .data = "export default 2;\n" });

    const subonly_root = try tmp.dir.realPathFileAlloc(io, "subonly", gpa);
    defer gpa.free(subonly_root);
    const rooted_root = try tmp.dir.realPathFileAlloc(io, "rooted", gpa);
    defer gpa.free(rooted_root);

    var trees = TestInstanceTrees{ .paths = &.{
        .{ .name = "subonly", .path = subonly_root },
        .{ .name = "rooted", .path = rooted_root },
    } };
    const instances = [_]lock_model.NpmInstance{
        .{ .key = "subonly@1.0.0", .name = "subonly", .version = "1.0.0" },
        .{ .key = "rooted@1.0.0", .name = "rooted", .version = "1.0.0" },
    };

    var reg = try BareRegistry.buildFromInstances(gpa, io, &instances, TestInstanceTrees.treePath, &trees);
    defer reg.deinit();

    // root 入口を持たない package でもサブパスは解決できる。
    const app = try reg.resolveBare("subonly/app");
    defer app.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, app.path, "app.mjs"));
    // root 入口だけが非公開になる。
    try testing.expectError(error.BareNotFound, reg.resolveBare("subonly"));
    // 同じ registry の他の package は影響を受けない。
    const root = try reg.resolveBare("rooted");
    defer root.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, root.path, "index.js"));
}

test "BareRegistry buildFromInstances keeps other packages when one is invalid" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.createDirPath(io, "broken");
    // JSON として壊れた package.json。
    try tmp.dir.writeFile(io, .{ .sub_path = "broken/package.json", .data = "{\"exports\":{\"./sub\":\"./s.mjs\"" });
    try tmp.dir.writeFile(io, .{ .sub_path = "broken/s.mjs", .data = "export default 1;\n" });
    try tmp.dir.createDirPath(io, "ok");
    try tmp.dir.writeFile(io, .{ .sub_path = "ok/package.json", .data = "{\"main\":\"index.js\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ok/index.js", .data = "export default 2;\n" });

    const broken_root = try tmp.dir.realPathFileAlloc(io, "broken", gpa);
    defer gpa.free(broken_root);
    const ok_root = try tmp.dir.realPathFileAlloc(io, "ok", gpa);
    defer gpa.free(ok_root);

    var trees = TestInstanceTrees{ .paths = &.{
        .{ .name = "broken", .path = broken_root },
        .{ .name = "ok", .path = ok_root },
    } };
    const instances = [_]lock_model.NpmInstance{
        .{ .key = "broken@1.0.0", .name = "broken", .version = "1.0.0" },
        .{ .key = "ok@1.0.0", .name = "ok", .version = "1.0.0" },
    };

    // 壊れた package.json があっても registry 全体は構築できる。
    var reg = try BareRegistry.buildFromInstances(gpa, io, &instances, TestInstanceTrees.treePath, &trees);
    defer reg.deinit();

    // 壊れた package のサブパスは per-import で package.json 不正になる。
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("broken/sub"));
    try testing.expectError(error.BareNotFound, reg.resolveBare("broken"));
    // 無関係な package は影響を受けない。
    const root = try reg.resolveBare("ok");
    defer root.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, root.path, "index.js"));
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

test "BareRegistry resolveBare は過大な wildcard 展開を確保前に拒否する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg");
    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"exports\":{\"./*\":\"./");
    var i: usize = 0;
    while (i < 100) : (i += 1) try json.appendSlice(gpa, "x*");
    try json.appendSlice(gpa, "\"}}");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/package.json", .data = json.items });
    const root = try tmp.dir.realPathFileAlloc(io, "pkg", gpa);
    defer gpa.free(root);
    var reg: BareRegistry = .{ .gpa = gpa, .io = io };
    defer reg.deinit();
    const name = try gpa.dupe(u8, "left-pad");
    const package_root = try gpa.dupe(u8, root);
    try reg.by_name.put(gpa, name, .{ .package_root = package_root, .root_path = null });

    const long = try gpa.alloc(u8, 20_000);
    defer gpa.free(long);
    @memset(long, 'a');
    const spec = try std.fmt.allocPrint(gpa, "left-pad/{s}", .{long});
    defer gpa.free(spec);
    try testing.expectError(error.InvalidSpecifier, reg.resolveBare(spec));
}

test "BareRegistry resolveBare は null target を一致部分検証より優先する" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg");
    const json =
        \\{"exports":{"./*":{"import":null}}}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/package.json", .data = json });
    const root = try tmp.dir.realPathFileAlloc(io, "pkg", gpa);
    defer gpa.free(root);
    var reg: BareRegistry = .{ .gpa = gpa, .io = io };
    defer reg.deinit();
    const name = try gpa.dupe(u8, "left-pad");
    const package_root = try gpa.dupe(u8, root);
    try reg.by_name.put(gpa, name, .{ .package_root = package_root, .root_path = null });

    // 一致部分は node_modules だが、target が null（非公開）なので
    // InvalidSpecifier ではなく BareNotFound。
    try testing.expectError(error.BareNotFound, reg.resolveBare("left-pad/node_modules/x"));
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

test "BareRegistry resolveBare は * 入り specifier をパターンとして解決する" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./a*b":"./literal.mjs","./*":"./wild/*.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{
        .{ .path = "literal.mjs", .data = "export default 1;\n" },
    });
    defer reg.deinit();
    const got = try reg.resolveBare("left-pad/a*b");
    defer got.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, got.path, "literal.mjs"));
}

test "BareRegistry resolveBare は選択パターンの不正 target を他パターンへ fallback しない" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const json =
        \\{"exports":{".":"./index.js","./a*b":"../evil.js","./*":"./wild/*.mjs"}}
    ;
    var reg = try makeTestRegistry(gpa, io, &tmp, "pkg", "left-pad", json, &.{});
    defer reg.deinit();
    try testing.expectError(error.PackageJsonInvalid, reg.resolveBare("left-pad/a*b"));
}

test {
    _ = @import("npm_esm_test.zig");
}
