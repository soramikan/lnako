const std = @import("std");
const pubgrub = @import("pubgrub");
const semver = @import("semver.zig");
const features_mod = @import("features.zig");
const manifest = @import("manifest.zig");

const Allocator = std.mem.Allocator;

/// 解決対象の package 識別子。
///
/// - `pkg`: Public ID (`pkg:<32hex>`) または人間向け package 名。同じ Public ID
///   に対する複数の version 制約はソルバ内で 1 つの package として統合される。
/// - `npm`: npm 補助依存の文脈別 ID。npm resolver 本体は後続 Issue (#53) だが、
///   文脈 (`context`) ごとに別 ID として解決対象に表現できるようにしておく。
pub const PackageId = union(enum) {
    pkg: []const u8,
    npm: NpmId,

    pub const NpmId = struct {
        name: []const u8,
        /// npm instance を特定する version 文字列（未確定なら空）。
        version: []const u8 = "",
        /// 文脈 ID。空の場合は package 名を文脈とみなす。
        context: []const u8 = "",

        /// 同値判定・hash で使う正規化済みの文脈。空なら package 名。
        pub fn effectiveContext(self: NpmId) []const u8 {
            return if (self.context.len == 0) self.name else self.context;
        }
    };

    pub fn eql(a: PackageId, b: PackageId) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .pkg => |name| std.mem.eql(u8, name, b.pkg),
            .npm => |npm| npmEql(npm, b.npm),
        };
    }

    pub fn hash(p: PackageId) u64 {
        var h = std.hash.Wyhash.init(0);
        switch (p) {
            .pkg => |name| {
                h.update("pkg\x00");
                h.update(name);
            },
            .npm => |npm| {
                h.update("npm\x00");
                h.update(npm.name);
                h.update("\x00");
                h.update(npm.version);
                h.update("\x00");
                h.update(npm.effectiveContext());
            },
        }
        return h.final();
    }

    /// 決定的な候補順を作るための全順序。
    pub fn lessThan(a: PackageId, b: PackageId) bool {
        return order(a, b) == .lt;
    }

    pub fn order(a: PackageId, b: PackageId) std.math.Order {
        const ta = std.meta.activeTag(a);
        const tb = std.meta.activeTag(b);
        if (ta != tb) return if (ta == .pkg) .lt else .gt;
        return switch (a) {
            .pkg => |name| std.mem.order(u8, name, b.pkg),
            .npm => |npm| blk: {
                const c1 = std.mem.order(u8, npm.name, b.npm.name);
                if (c1 != .eq) break :blk c1;
                const c2 = std.mem.order(u8, npm.version, b.npm.version);
                if (c2 != .eq) break :blk c2;
                break :blk std.mem.order(u8, npm.effectiveContext(), b.npm.effectiveContext());
            },
        };
    }

    pub fn format(p: PackageId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (p) {
            .pkg => |name| try w.writeAll(name),
            .npm => |npm| try w.print("npm:{s}@{s}#{s}", .{ npm.name, npm.version, npm.effectiveContext() }),
        }
    }

    fn npmEql(a: NpmId, b: NpmId) bool {
        return std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.version, b.version) and
            std.mem.eql(u8, a.effectiveContext(), b.effectiveContext());
    }
};

/// ソルバが扱う version。`semver.Version` を優先順位比較 (`order`) で包む。
/// build メタデータは semver §10 に従い優先順位に影響しない。
pub const Version = struct {
    inner: semver.Version,

    pub fn parse(text: []const u8) error{InvalidSemver}!Version {
        return .{ .inner = try semver.Version.parse(text) };
    }

    pub fn cmp(a: Version, b: Version) std.math.Order {
        return a.inner.order(b.inner);
    }

    pub fn isPrerelease(v: Version) bool {
        return v.inner.hasPrerelease();
    }

    pub fn toSemver(v: Version) semver.Version {
        return v.inner;
    }

    pub fn format(v: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try v.inner.format(w);
    }
};

/// `pubgrub.Solver` の lnako 向け特殊化。
pub const Solver = pubgrub.Solver(PackageId, Version);
pub const Range = Solver.R;
pub const Selection = Solver.Selection;

/// root を表す予約 ID。TOML 文字列に NUL を含められないため衝突しない。
pub const root_id: PackageId = .{ .pkg = "\x00root" };
pub const root_version = Version{ .inner = .{ .major = 0, .minor = 0, .patch = 0 } };

/// 依存辺。`pubgrub` の `Dependency` に feature・alias・source 選択の情報を足したもの。
pub const Dependency = struct {
    id: PackageId,
    constraint: Range,
    /// manifest 上の依存エントリ名。feature 定義が alias を参照する際の照合に使う。
    name: []const u8 = "",
    /// 明示 alias（`dependencies.pkg.<name>.alias`）。
    alias: ?[]const u8 = null,
    /// この依存で有効化する feature 名。
    features: []const []const u8 = &.{},
    /// false の場合、依存先の `default` feature を無効化する。
    default_features: bool = true,
    /// true の場合、lnako 実行時に native 実装を優先選択する。
    prefer_native: bool = false,
    /// この依存の元になった npm 互換 range。prerelease ゲートを含む
    /// node-semver 判定を解決後の検証で行うために保持する。null の場合は
    /// `constraint` の区間判定にフォールバックする。
    semver_range: ?semver.Range = null,
};

/// feature 定義。
pub const FeatureDefinition = struct {
    name: []const u8,
    items: []const []const u8,
};

/// export 実装種別。
pub const Impl = enum { none, source, native, esm };

/// 1 つの package version について provider が返す metadata。
pub const VersionMeta = struct {
    dependencies: []const Dependency = &.{},
    features: []const FeatureDefinition = &.{},
    /// feature 展開で alias として解決できる依存エントリ名（pkg 以外の
    /// npm/path/git/http や dev-dependencies を含む）。version 解決の辺には
    /// ならないが、feature 定義からの参照で未知 feature にしないために渡す。
    feature_aliases: []const []const u8 = &.{},
    /// null なら選択可能。値がある場合は選択不能な理由（runtime/engines/OS/
    /// artifact 欠落など）。理由は競合説明の hint として表示される。
    unavailable_reason: ?[]const u8 = null,
    /// 要求 target へ適合する export 実装の有無。provider は条件付き
    /// artifact 宣言（`when`/`min-os`/`libc`/`features`）を target で照合し、
    /// 適合する宣言が一つも無い種別は false にする（`metaFromManifest`
    /// が manifest 由来の照合を行う）。
    has_source: bool = false,
    has_native: bool = false,
    has_esm: bool = false,
};

/// 解決対象の環境条件。
pub const Target = struct {
    runtime: []const u8 = "lnako",
    os: []const u8 = "macos",
    cpu: []const u8 = "aarch64",
    abi: []const u8 = "gnu",
    /// OS バージョン（`min-os` 付き artifact 宣言の照合用）。null は不明で、
    /// `min-os` を要求する宣言は適合を証明できないため不適合となる。
    os_version: ?[]const u8 = null,
    /// libc 種別（`libc` 付き artifact 宣言の照合用）。null は `abi` から推定。
    libc: ?[]const u8 = null,
    compat_js: bool = false,
    optimize: []const u8 = "O0",
    nako_version: ?semver.Version = null,
    cnako_version: ?semver.Version = null,
    lnako_version: ?semver.Version = null,
};

/// 取得処理を解決 core から分離するための metadata provider 契約。
/// 実装は version 一覧、version ごとの metadata、既存 lock の選択候補を返す。
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 選択可能な全 version。package が存在しない場合は
        /// `error.PackageNotFound` を返す（解決失敗として扱われる）。
        listVersions: *const fn (ptr: *anyopaque, gpa: Allocator, id: PackageId) anyerror![]const Version,
        /// version の metadata。解決不能な version は `unavailable_reason` を設定する。
        versionMeta: *const fn (ptr: *anyopaque, gpa: Allocator, id: PackageId, version: Version) anyerror!VersionMeta,
        /// 既存 lock の選択候補。候補が無い場合は null。
        lockedVersion: *const fn (ptr: *anyopaque, id: PackageId) ?Version,
    };

    pub fn listVersions(self: Provider, gpa: Allocator, id: PackageId) anyerror![]const Version {
        return self.vtable.listVersions(self.ptr, gpa, id);
    }

    pub fn versionMeta(self: Provider, gpa: Allocator, id: PackageId, version: Version) anyerror!VersionMeta {
        return self.vtable.versionMeta(self.ptr, gpa, id, version);
    }

    pub fn lockedVersion(self: Provider, id: PackageId) ?Version {
        return self.vtable.lockedVersion(self.ptr, id);
    }
};

pub const ResolveOptions = struct {
    target: Target = .{},
    prefer_oldest: bool = false,
    /// feature 要求の不動点を求める反復上限。要求は選択 version の変化で
    /// 減ることもあり収束は単調ではないため、収束しない場合はこの上限で
    /// `error.FeatureIterationExceeded` とする。
    max_feature_iterations: u32 = 64,
};

/// 解決済み package node。
///
/// `dependencies` は `dependencies.pkg` から解決した辺のみ。npm/path/git/http
/// 依存は version 解決の対象外で、lock 生成・取得・import 層が manifest を
/// 再評価して扱う（この node には含まれない）。
pub const PackageNode = struct {
    id: PackageId,
    version: Version,
    /// 有効化された feature（展開済み・昇順）。
    features: []const []const u8,
    /// 選択された実装種別（共通 source 既定・native 明示）。
    implementation: Impl,
    /// いずれかの依存辺で prefer-native が指定されたか。
    prefer_native: bool,
    /// 直接依存の解決済み ID（昇順）。
    dependencies: []const PackageId,
};

pub const Failure = struct {
    /// 直接要求から競合箇所まで辿れる説明。
    message: []const u8,
    /// ソルバが試行した候補解の数。
    attempted_solutions: u32,
};

pub const Resolution = struct {
    arena: std.heap.ArenaAllocator,
    result: union(enum) {
        resolved: []const PackageNode,
        failed: Failure,
        /// package 依存の循環。診断層は `E004_DEPENDENCY_CYCLE` へ変換する。
        /// 先頭と末尾は同じ package（経路を閉じる）。
        cycle: []const PackageId,
    },

    pub fn deinit(self: *Resolution) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidFeatureGraph,
    FeatureIterationExceeded,
};

// ---------------------------------------------------------------------------
// semver.Range → pubgrub.Range 変換
// ---------------------------------------------------------------------------

/// lnako の npm 互換 range を pubgrub の区間集合へ変換する。
///
/// この変換は区間のみを表し、node-semver の prerelease ゲート（候補が同一
/// tuple の prerelease 比較子を要求する規則）は表現しない。ゲートは辺ごとに
/// `applyPrereleaseGate` で、その辺の元 range が許可しない prerelease を区間
/// から除外して表現する。prerelease の候補順は pubgrub に従い release が優先
/// される。
pub fn rangeFromSemver(gpa: Allocator, range: semver.Range) error{OutOfMemory}!Range {
    // `sets.len == 0` は「全 version 一致」を表すセンチネル（`semver.Range`
    // の契約）。空の AND 集合は区間 `any` に対応する。
    if (range.sets.len == 0) return .any;
    var result: Range = .empty;
    for (range.sets) |set| {
        var low_v: ?Version = null;
        var low_inclusive = true;
        var high_v: ?Version = null;
        var high_inclusive = true;
        for (set) |comparator| {
            const v = Version{ .inner = comparator.version };
            switch (comparator.op) {
                .gte => updateLower(&low_v, &low_inclusive, v, true),
                .gt => updateLower(&low_v, &low_inclusive, v, false),
                .lte => updateUpper(&high_v, &high_inclusive, v, true),
                .lt => updateUpper(&high_v, &high_inclusive, v, false),
                .eq => {
                    updateLower(&low_v, &low_inclusive, v, true);
                    updateUpper(&high_v, &high_inclusive, v, true);
                },
            }
        }
        const interval = try Range.between(gpa, low_v, low_inclusive, high_v, high_inclusive);
        result = try result.unionWith(interval, gpa);
    }
    return result;
}

fn updateLower(low_v: *?Version, low_inclusive: *bool, v: Version, inclusive: bool) void {
    const replace = if (low_v.*) |current| switch (Version.cmp(v, current)) {
        .gt => true,
        .lt => false,
        // 同一 version では `>` (exclusive) が `>=` より強い。
        .eq => !inclusive and low_inclusive.*,
    } else true;
    if (replace) {
        low_v.* = v;
        low_inclusive.* = inclusive;
    }
}

fn updateUpper(high_v: *?Version, high_inclusive: *bool, v: Version, inclusive: bool) void {
    const replace = if (high_v.*) |current| switch (Version.cmp(v, current)) {
        .lt => true,
        .gt => false,
        // 同一 version では `<` (exclusive) が `<=` より強い。
        .eq => !inclusive and high_inclusive.*,
    } else true;
    if (replace) {
        high_v.* = v;
        high_inclusive.* = inclusive;
    }
}

// ---------------------------------------------------------------------------
// feature 統合
// ---------------------------------------------------------------------------

const PkgRequest = struct {
    features: std.StringHashMap(void),
    default_enabled: bool = false,
    prefer_native: bool = false,
};

fn IdMap(comptime Val: type) type {
    return std.HashMap(PackageId, Val, struct {
        pub fn hash(_: @This(), k: PackageId) u64 {
            return k.hash();
        }
        pub fn eql(_: @This(), a: PackageId, b: PackageId) bool {
            return a.eql(b);
        }
    }, std.hash_map.default_max_load_percentage);
}

const RequestMap = IdMap(PkgRequest);

const Expansion = struct {
    features: std.StringHashMap(void),
    aliases: std.StringHashMap(void),
};

const Interner = struct {
    strings: std.StringHashMap([]const u8),

    fn init(gpa: Allocator) Interner {
        return .{ .strings = std.StringHashMap([]const u8).init(gpa) };
    }

    fn intern(self: *Interner, gpa: Allocator, text: []const u8) ![]const u8 {
        if (self.strings.get(text)) |owned| return owned;
        const copy = try gpa.dupe(u8, text);
        try self.strings.put(copy, copy);
        return copy;
    }

    fn id(self: *Interner, gpa: Allocator, value: PackageId) !PackageId {
        return switch (value) {
            .pkg => |name| .{ .pkg = try self.intern(gpa, name) },
            .npm => |npm| .{ .npm = .{
                .name = try self.intern(gpa, npm.name),
                .version = try self.intern(gpa, npm.version),
                .context = try self.intern(gpa, npm.context),
            } },
        };
    }

    fn version(self: *Interner, gpa: Allocator, value: Version) !Version {
        return .{ .inner = .{
            .major = value.inner.major,
            .minor = value.inner.minor,
            .patch = value.inner.patch,
            .prerelease = if (value.inner.prerelease.len > 0)
                try self.intern(gpa, value.inner.prerelease)
            else
                "",
            .build = if (value.inner.build.len > 0)
                try self.intern(gpa, value.inner.build)
            else
                "",
        } };
    }
};

fn isDefinedFeature(meta: VersionMeta, name: []const u8) bool {
    for (meta.features) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return true;
    }
    return false;
}

fn dependencyAliasMatches(dep: Dependency, name: []const u8) bool {
    if (std.mem.eql(u8, dep.name, name)) return true;
    if (dep.alias) |alias| return std.mem.eql(u8, alias, name);
    return false;
}

/// 依存 alias が feature 定義から参照されている場合、その依存は
/// 「feature 有効時のみ含める」対象 (gated) とみなす。schema v1 には
/// optional フラグが無いため、この規則で feature の有効/無効を依存の
/// 有無へ反映する。
fn isGated(meta: VersionMeta, dep: Dependency) bool {
    for (meta.features) |definition| {
        for (definition.items) |item| {
            if (isDefinedFeature(meta, item)) continue;
            if (dependencyAliasMatches(dep, item)) return true;
        }
    }
    return false;
}

/// `expansionFor` の結果。`orphans` は選択版が提供しない要求 feature 名
/// （`default` を除く）。呼出し側は該当版を選択不能として扱う。
const ExpansionResult = struct {
    expansion: Expansion,
    orphans: []const []const u8,
};

fn expansionFor(gpa: Allocator, meta: VersionMeta, request: ?PkgRequest) !ExpansionResult {
    var definitions: features_mod.Definitions = .empty;
    for (meta.features) |definition| {
        try definitions.put(gpa, definition.name, .{
            .name = definition.name,
            .items = definition.items,
            .position = .{},
        });
    }

    var input_aliases = std.StringHashMap(void).init(gpa);
    for (meta.dependencies) |dep| {
        try input_aliases.put(dep.name, {});
        if (dep.alias) |alias| try input_aliases.put(alias, {});
    }
    // version 解決対象外の依存（npm/path/git/http・dev）も feature の
    // alias として解決できるようにする。
    for (meta.feature_aliases) |alias| try input_aliases.put(alias, {});

    // 選択版が提供しない要求 feature は「この version では満たせない」ため
    // 呼出し側で unavailable として扱い、PubGrub に別 version へ backtrack
    // させる。`default` は未定義なら無効化される仕様のため対象外。
    var requested: std.ArrayList([]const u8) = .empty;
    var orphans: std.ArrayList([]const u8) = .empty;
    if (request) |req| {
        var iterator = req.features.keyIterator();
        while (iterator.next()) |name| {
            if (definitions.contains(name.*) or input_aliases.contains(name.*)) {
                try requested.append(gpa, name.*);
            } else if (!std.mem.eql(u8, name.*, "default")) {
                try orphans.append(gpa, name.*);
            }
        }
    }

    const use_default = if (request) |req| req.default_enabled else false;
    var offender: ?[]const u8 = null;
    const expanded = features_mod.expand(
        gpa,
        &definitions,
        requested.items,
        use_default,
        &input_aliases,
        &offender,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FeatureCycle, error.UnknownFeature => return error.InvalidFeatureGraph,
    };
    return .{
        .expansion = .{
            .features = expanded.features,
            .aliases = expanded.dependency_aliases,
        },
        .orphans = orphans.items,
    };
}

/// 有効 feature 集合を考慮した依存辺。gated 依存は有効化された alias のみ含む。
fn activeDependencies(gpa: Allocator, meta: VersionMeta, request: ?PkgRequest) !struct { expansion: Expansion, deps: []const Dependency, orphans: []const []const u8 } {
    const result = try expansionFor(gpa, meta, request);
    var deps: std.ArrayList(Dependency) = .empty;
    for (meta.dependencies) |dep| {
        if (isGated(meta, dep)) {
            const activated = result.expansion.aliases.contains(dep.name) or
                (if (dep.alias) |alias| result.expansion.aliases.contains(alias) else false);
            if (!activated) continue;
        }
        try deps.append(gpa, dep);
    }
    return .{ .expansion = result.expansion, .deps = deps.items, .orphans = result.orphans };
}

// ---------------------------------------------------------------------------
// 解決本体
// ---------------------------------------------------------------------------

const Adapter = struct {
    provider: Provider,
    requests: *const RequestMap,

    pub fn listVersions(self: *const Adapter, gpa: Allocator, id: PackageId) anyerror![]const Version {
        return self.provider.listVersions(gpa, id);
    }

    pub fn dependencies(self: *const Adapter, gpa: Allocator, id: PackageId, version: Version) anyerror!Solver.DepResult {
        const meta = try self.provider.versionMeta(gpa, id, version);
        if (meta.unavailable_reason) |reason| return .{ .unavailable = reason };
        const request = if (self.requests.get(id)) |req| req else null;
        const active = try activeDependencies(gpa, meta, request);
        // この version が提供しない要求 feature がある場合、その version は
        // 選択不能として PubGrub に別 version を探索させる。
        if (active.orphans.len > 0) {
            return .{ .unavailable = "requested feature is not provided by this version" };
        }
        var result: std.ArrayList(Solver.Dependency) = .empty;
        for (active.deps) |dep| {
            try result.append(gpa, .{
                .package = dep.id,
                .constraint = try applyPrereleaseGate(gpa, self.provider, dep),
            });
        }
        return .{ .known = result.items };
    }

    pub fn lockedVersion(self: *const Adapter, id: PackageId) ?Version {
        return self.provider.lockedVersion(id);
    }
};

/// 対象処理系として公開されている値か。`lnako`/`cnako` 以外は
/// `Export.resolve` と同じく対象外として扱う。
pub fn isSupportedRuntime(runtime: []const u8) bool {
    return std.mem.eql(u8, runtime, "lnako") or std.mem.eql(u8, runtime, "cnako");
}

/// package 全体としての代表実装を選ぶ。export が複数ある場合の最終的な
/// export 単位の選択は import 時の `Export.resolve` が再検証する
/// （ここでは source があれば既定で source、`prefer_native` が lnako で
/// 明示された場合のみ native）。
pub fn chooseImplementation(meta: VersionMeta, target: Target, prefer_native: bool) Impl {
    // 未知の処理系は実装選択の対象外。`Export.resolve` の契約に合わせる。
    if (!isSupportedRuntime(target.runtime)) return .none;
    if (meta.has_source) {
        if (prefer_native and std.mem.eql(u8, target.runtime, "lnako") and meta.has_native) {
            return .native;
        }
        return .source;
    }
    if (std.mem.eql(u8, target.runtime, "lnako")) {
        if (meta.has_native) return .native;
        if (meta.has_esm and target.compat_js) return .esm;
        return .none;
    }
    // cnako は ESM を直接扱える。native 単独は非対応。
    if (meta.has_esm) return .esm;
    return .none;
}

fn mergeDependency(gpa: Allocator, interner: *Interner, requests: *RequestMap, dep: Dependency) !void {
    const id = try interner.id(gpa, dep.id);
    const gop = try requests.getOrPut(id);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .features = std.StringHashMap(void).init(gpa) };
    }
    for (dep.features) |feature| {
        try gop.value_ptr.features.put(try interner.intern(gpa, feature), {});
    }
    gop.value_ptr.default_enabled = gop.value_ptr.default_enabled or dep.default_features;
    gop.value_ptr.prefer_native = gop.value_ptr.prefer_native or dep.prefer_native;
}

/// `a` と `b` の要求内容（feature 集合・default/native フラグ）が一致するか。
fn requestsEqual(a: *const RequestMap, b: *const RequestMap) bool {
    if (a.count() != b.count()) return false;
    var iterator = a.iterator();
    while (iterator.next()) |entry| {
        const other = b.get(entry.key_ptr.*) orelse return false;
        if (entry.value_ptr.features.count() != other.features.count()) return false;
        var features = entry.value_ptr.features.keyIterator();
        while (features.next()) |name| {
            if (!other.features.contains(name.*)) return false;
        }
        if (entry.value_ptr.default_enabled != other.default_enabled) return false;
        if (entry.value_ptr.prefer_native != other.prefer_native) return false;
    }
    return true;
}

/// 解決結果の選択から、各 package の feature 要求を再計算する。
fn collectRequests(
    gpa: Allocator,
    interner: *Interner,
    provider: Provider,
    current: *const RequestMap,
    root_deps: []const Dependency,
    selections: []const Selection,
) !RequestMap {
    var requests = RequestMap.init(gpa);
    for (root_deps) |dep| try mergeDependency(gpa, interner, &requests, dep);
    for (selections) |selection| {
        if (selection.package.eql(root_id)) continue;
        const meta = try provider.versionMeta(gpa, selection.package, selection.version);
        const request = if (current.get(selection.package)) |req| req else null;
        const active = try activeDependencies(gpa, meta, request);
        for (active.deps) |dep| try mergeDependency(gpa, interner, &requests, dep);
    }
    return requests;
}

/// package の依存制約を解決する。
///
/// 現在の feature 要求で version を解き、得た解の依存辺から feature 要求を
/// 再計算する。要求が一致して不動点に達するまで反復し、収束した要求で解いた
/// 選択をそのまま報告する。version 選択・競合学習・backjump・競合理由の生成は
/// すべて `zig-pubgrub` のソルバが行う。
///
/// 反復は単調増加ではない。選択 version の変化で feature 要求が減ることも
/// あり、収束せず振動する場合がある。その場合は `max_feature_iterations` で
/// 打ち切る（`error.FeatureIterationExceeded`）。
///
/// 既知の限界: feature の有無で依存先の version 選択が変わる場合、feature
/// 要求はソルバの制約項ではないため、ある version を選んだ後に別 version の
/// feature 依存が競合しても backjump できず、有効な別 version を選べない。
/// これは安全側の失敗であり、誤った解は返さない。
///
/// node-semver の prerelease ゲートは `applyPrereleaseGate` で辺ごとに除外し、
/// 親 version に条件付けて PubGrub の制約として表現する。
pub fn resolve(gpa: Allocator, provider: Provider, root_deps: []const Dependency, opts: ResolveOptions) !Resolution {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var interner = Interner.init(a);
    var requests = RequestMap.init(a);
    for (root_deps) |dep| try mergeDependency(a, &interner, &requests, dep);

    // root 依存は決定的順序でソルバへ渡す。
    const sorted_root = try a.dupe(Dependency, root_deps);
    std.mem.sort(Dependency, sorted_root, {}, struct {
        fn lt(_: void, x: Dependency, y: Dependency) bool {
            return PackageId.lessThan(x.id, y.id);
        }
    }.lt);
    var solver_root_deps: std.ArrayList(Solver.Dependency) = .empty;
    for (sorted_root) |dep| {
        try solver_root_deps.append(a, .{
            .package = dep.id,
            .constraint = try applyPrereleaseGate(a, provider, dep),
        });
    }

    var iteration: u32 = 0;
    while (iteration < opts.max_feature_iterations) : (iteration += 1) {
        const adapter = Adapter{ .provider = provider, .requests = &requests };
        // ソルバ自身のアリーナは実 allocator 上に作らせ、各反復の終了時に
        // 解放する。provider が返す version 文字列は解決結果へ持ち出す前に
        // interner で複製するため、ここで solve のメモリを破棄してよい。
        var outcome = try Solver.solve(
            gpa,
            &adapter,
            root_id,
            root_version,
            solver_root_deps.items,
            .{ .prefer_oldest = opts.prefer_oldest },
        );
        defer outcome.deinit();
        switch (outcome.result) {
            .failed => |failed| {
                const message = try a.dupe(u8, failed.message);
                const attempted = outcome.attempted_solutions;
                return .{
                    .arena = arena,
                    .result = .{ .failed = .{
                        .message = message,
                        .attempted_solutions = attempted,
                    } },
                };
            },
            .resolved => |resolved| {
                // 選択を先に resolver アリーナへ複製しておく（outcome
                // の解放後も参照できるようにする）。
                var selections: std.ArrayList(Selection) = .empty;
                for (resolved.selections) |selection| {
                    try selections.append(a, .{
                        .package = try interner.id(a, selection.package),
                        .version = try interner.version(a, selection.version),
                    });
                }
                const gathered = try collectRequests(a, &interner, provider, &requests, root_deps, selections.items);
                if (requestsEqual(&requests, &gathered)) {
                    const nodes = try buildGraph(a, &interner, provider, &gathered, selections.items, sorted_root, opts.target);
                    if (try findCycle(a, nodes)) |cycle| {
                        return .{
                            .arena = arena,
                            .result = .{ .cycle = cycle },
                        };
                    }
                    return .{
                        .arena = arena,
                        .result = .{ .resolved = nodes },
                    };
                }
                requests = gathered;
            },
        }
    }
    return error.FeatureIterationExceeded;
}

/// node-semver の prerelease ゲートは区間で表現できないため、辺ごとに
/// 対象 package の prerelease 候補のうち元 range が許可しないものを区間から
/// 除外して PubGrub へ渡す。親 version が変わればその辺の除外も変わるため、
/// 別の親版が許可する有効解を消さない。
///
/// このため辺の制約生成時に対象 package の `listVersions` を呼ぶ。
/// `error.PackageNotFound` は除外なしとして扱い、それ以外の provider エラーは
/// そのまま伝搬する（取得失敗が解決失敗として表面化する）。
fn applyPrereleaseGate(gpa: Allocator, provider: Provider, dep: Dependency) !Range {
    const range = dep.semver_range orelse return dep.constraint;
    const versions = provider.listVersions(gpa, dep.id) catch |err| switch (err) {
        error.PackageNotFound => return dep.constraint,
        else => return err,
    };
    var excluded: Range = .empty;
    for (versions) |version| {
        if (!Version.isPrerelease(version)) continue;
        if (range.satisfies(version.toSemver())) continue;
        excluded = try excluded.unionWith(try Range.singleton(gpa, version), gpa);
    }
    return dep.constraint.difference(excluded, gpa);
}

fn buildGraph(
    gpa: Allocator,
    interner: *Interner,
    provider: Provider,
    requests: *const RequestMap,
    selections: []const Selection,
    root_deps: []const Dependency,
    target: Target,
) ![]const PackageNode {
    var nodes: std.ArrayList(PackageNode) = .empty;
    for (selections) |selection| {
        if (selection.package.eql(root_id)) continue;
        const meta = try provider.versionMeta(gpa, selection.package, selection.version);
        const request = if (requests.get(selection.package)) |req| req else null;
        const active = try activeDependencies(gpa, meta, request);

        var feature_names: std.ArrayList([]const u8) = .empty;
        var feature_iterator = active.expansion.features.keyIterator();
        while (feature_iterator.next()) |name| {
            try feature_names.append(gpa, try interner.intern(gpa, name.*));
        }
        std.mem.sort([]const u8, feature_names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);

        var dep_ids: std.ArrayList(PackageId) = .empty;
        var seen = IdMap(void).init(gpa);
        for (active.deps) |dep| {
            const owned = try interner.id(gpa, dep.id);
            const gop = try seen.getOrPut(owned);
            if (gop.found_existing) continue;
            try dep_ids.append(gpa, owned);
        }
        std.mem.sort(PackageId, dep_ids.items, {}, struct {
            fn lt(_: void, x: PackageId, y: PackageId) bool {
                return PackageId.lessThan(x, y);
            }
        }.lt);

        const prefer_native = if (request) |req| req.prefer_native else false;
        try nodes.append(gpa, .{
            .id = try interner.id(gpa, selection.package),
            .version = try interner.version(gpa, selection.version),
            .features = feature_names.items,
            .implementation = chooseImplementation(meta, target, prefer_native),
            .prefer_native = prefer_native,
            .dependencies = dep_ids.items,
        });
    }
    const reachable = try filterReachable(gpa, nodes.items, root_deps);
    std.mem.sort(PackageNode, reachable, {}, struct {
        fn lt(_: void, x: PackageNode, y: PackageNode) bool {
            return PackageId.lessThan(x.id, y.id);
        }
    }.lt);
    return reachable;
}

/// root から到達できない node を除く（単調併合で残った古い feature 要求の
/// 影響で選択に残った package を graph から落とす）。
fn filterReachable(gpa: Allocator, nodes: []const PackageNode, root_deps: []const Dependency) ![]PackageNode {
    var by_id = IdMap(usize).init(gpa);
    for (nodes, 0..) |node, index| try by_id.put(node.id, index);

    var keep = std.AutoHashMap(usize, void).init(gpa);
    var stack: std.ArrayList(PackageId) = .empty;
    for (root_deps) |dep| {
        if (by_id.get(dep.id)) |index| {
            if (!keep.contains(index)) {
                try keep.put(index, {});
                try stack.append(gpa, dep.id);
            }
        }
    }
    while (stack.pop()) |id| {
        const index = by_id.get(id) orelse continue;
        for (nodes[index].dependencies) |next| {
            const next_index = by_id.get(next) orelse continue;
            if (keep.contains(next_index)) continue;
            try keep.put(next_index, {});
            try stack.append(gpa, next);
        }
    }

    var out: std.ArrayList(PackageNode) = .empty;
    for (nodes, 0..) |node, index| {
        if (keep.contains(index)) try out.append(gpa, node);
    }
    return out.items;
}

const VisitState = enum { white, gray, black };

/// 依存 graph の循環を検出する。循環があれば閉じた経路
/// (`a -> b -> ... -> a`) を返す。反復 DFS でネイティブスタックを消費しない。
fn findCycle(gpa: Allocator, nodes: []const PackageNode) !?[]const PackageId {
    var by_id = IdMap(usize).init(gpa);
    for (nodes, 0..) |node, index| try by_id.put(node.id, index);

    const color = try gpa.alloc(VisitState, nodes.len);
    @memset(color, .white);
    const parent = try gpa.alloc(?usize, nodes.len);
    @memset(parent, null);

    const Frame = struct { node: usize, next: usize };
    var stack: std.ArrayList(Frame) = .empty;
    for (0..nodes.len) |start| {
        if (color[start] != .white) continue;
        color[start] = .gray;
        try stack.append(gpa, .{ .node = start, .next = 0 });
        while (stack.items.len > 0) {
            const frame = &stack.items[stack.items.len - 1];
            if (frame.next < nodes[frame.node].dependencies.len) {
                const dep = nodes[frame.node].dependencies[frame.next];
                frame.next += 1;
                const target = by_id.get(dep) orelse continue;
                switch (color[target]) {
                    .gray => {
                        // 循環を parent ポインタで再構成する。
                        var path: std.ArrayList(PackageId) = .empty;
                        var cursor: usize = frame.node;
                        while (true) {
                            try path.append(gpa, nodes[cursor].id);
                            if (cursor == target) break;
                            cursor = parent[cursor] orelse break;
                        }
                        std.mem.reverse(PackageId, path.items);
                        try path.append(gpa, nodes[target].id);
                        return path.items;
                    },
                    .white => {
                        color[target] = .gray;
                        parent[target] = frame.node;
                        try stack.append(gpa, .{ .node = target, .next = 0 });
                    },
                    .black => {},
                }
            } else {
                color[frame.node] = .black;
                _ = stack.pop();
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// manifest からの provider 補助
// ---------------------------------------------------------------------------

/// `Manifest` から `VersionMeta` を組み立てる補助。
///
/// runtime (`package.runtimes`)・engines (`package.engines`)・export 実装の
/// 有無・共通ソース/native 選択を反映し、選択不能な version には理由を付ける。
/// OS/artifact の可用性は registry 側の責務であり、provider 実装が
/// `unavailable_reason` を上書きして表現する。
///
/// version 解決へ渡すのは `dependencies.pkg` のみ。`dependencies.npm`・
/// `path`・`git`・`http` と dev-dependencies は取得/lock/npm resolver の別層が
/// 担い、この関数では解決対象にしない。`dependencies.pkg.<name>.profile` も
/// profile 選択・OS 条件の再評価を別層（lock/import）に委ね、ここでは辺の
/// 制約として扱わない。
pub fn metaFromManifest(gpa: Allocator, source: *const manifest.Manifest, target: Target) !VersionMeta {
    var deps: std.ArrayList(Dependency) = .empty;
    var pkg_iterator = source.dependencies.pkg.iterator();
    while (pkg_iterator.next()) |entry| {
        const dep = entry.value_ptr.*;
        const id: PackageId = if (dep.public_id) |public_id|
            .{ .pkg = public_id }
        else
            .{ .pkg = dep.name };
        try deps.append(gpa, .{
            .id = id,
            .constraint = try rangeFromSemver(gpa, dep.version),
            .name = dep.name,
            .alias = dep.alias,
            .features = dep.features,
            .default_features = dep.default_features,
            .prefer_native = dep.prefer_native,
            .semver_range = dep.version,
        });
    }

    var definitions: std.ArrayList(FeatureDefinition) = .empty;
    var feature_iterator = source.features.iterator();
    while (feature_iterator.next()) |entry| {
        try definitions.append(gpa, .{
            .name = entry.value_ptr.name,
            .items = entry.value_ptr.items,
        });
    }

    // feature 定義は pkg 以外（npm/path/git/http・dev）の alias も参照できる。
    // これらは version 解決の辺にはしないが、未知 feature にしないため
    // 展開用の alias 集合として渡す。
    var feature_aliases: std.ArrayList([]const u8) = .empty;
    {
        var aliases = try source.dependencyAliases(gpa);
        defer aliases.deinit();
        var alias_iterator = aliases.keyIterator();
        while (alias_iterator.next()) |name| try feature_aliases.append(gpa, name.*);
        std.mem.sort([]const u8, feature_aliases.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
    }

    var meta = VersionMeta{
        .dependencies = deps.items,
        .features = definitions.items,
        .feature_aliases = feature_aliases.items,
    };
    // native/esm は宣言の存在ではなく「対象環境へ適合する宣言の有無」で
    // 実装可否を決める。条件付き宣言（when/min-os/libc）が一つも対象へ
    // 適合しない種別は実装候補にしない。`os_version`/`libc` が Target で
    // 未指定の場合、それを要求する宣言は適合を証明できず不適合となる
    // （保守方向）。`features` 要件は feature unification 後にしか確定
    // しないためこの段階では未評価とし、feature 条件だけで version 候補を
    // 落とさない（最終的な実装選択は import 時の `Export.resolve` が
    // 再有効化 feature で検証する）。
    const artifact_target = manifest.ArtifactTarget{
        .runtime = target.runtime,
        .os = target.os,
        .cpu = target.cpu,
        .abi = target.abi,
        .os_version = target.os_version,
        .libc = target.libc,
        .compat_js = target.compat_js,
        // marker の `version` はなでしこ言語版を指す。処理系版への
        // フォールバックは verify 側（nako_version のみ）と契約がずれる
        // ため行わず、不明な場合は `version` を使う式を証明不能とする。
        .version = target.nako_version,
    };
    for (source.exports) |item| {
        if (item.path != null) meta.has_source = true;
        for (item.native) |*decl| {
            if (try decl.matchesTarget(gpa, artifact_target, false)) {
                meta.has_native = true;
                break;
            }
        }
        for (item.esm) |*decl| {
            if (try decl.matchesTarget(gpa, artifact_target, false)) {
                meta.has_esm = true;
                break;
            }
        }
    }
    meta.unavailable_reason = unavailableReason(source, meta, target);
    return meta;
}

fn unavailableReason(source: *const manifest.Manifest, meta: VersionMeta, target: Target) ?[]const u8 {
    if (!isSupportedRuntime(target.runtime)) return "unsupported runtime";
    if (source.package.runtimes.len > 0) {
        var supported = false;
        for (source.package.runtimes) |runtime| {
            if (std.mem.eql(u8, runtime, target.runtime)) supported = true;
        }
        if (!supported) return "package does not support the requested runtime";
    }
    if (!enginesSatisfied(source, target)) {
        return "package engines requirement is not satisfied";
    }
    if (chooseImplementation(meta, target, false) == .none) {
        if (std.mem.eql(u8, target.runtime, "lnako")) {
            return "package has no implementation for lnako without --compat-js";
        }
        return "package has no implementation for the requested runtime";
    }
    return null;
}

/// engines 要件を判定する。判定対象 version が未指定のキーは
/// `SPECIFICATION.md` §3.2 の契約どおり「未検査」として扱う
/// （呼出し側が厳格にしたい場合は `Target` のバージョンを埋める）。
/// `nako` は言語版として常に判定し、`cnako`/`lnako` は対象 runtime の
/// ものだけを判定する（無関係な処理系の制約で package を拒否しない）。
fn enginesSatisfied(source: *const manifest.Manifest, target: Target) bool {
    const engines = source.package.engines;
    if (engines.nako) |range| {
        if (target.nako_version) |version| {
            if (!range.satisfies(version)) return false;
        }
    }
    if (std.mem.eql(u8, target.runtime, "cnako")) {
        if (engines.cnako) |range| {
            if (target.cnako_version) |version| {
                if (!range.satisfies(version)) return false;
            }
        }
    } else if (std.mem.eql(u8, target.runtime, "lnako")) {
        if (engines.lnako) |range| {
            if (target.lnako_version) |version| {
                if (!range.satisfies(version)) return false;
            }
        }
    }
    return true;
}

test {
    _ = @import("resolver_test.zig");
}
