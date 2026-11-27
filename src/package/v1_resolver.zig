//! v1 の依存解決（§6.1〜§6.3 のバージョン選択部分）。
//!
//! 入力は型付きの sparse index（`Package`/`Release`）と、ルートプロジェクトの
//! 直接依存宣言（`types.Dependency`）だけ。network・JSON・CLI は扱わない。
//!
//! 方針:
//! - 直接依存は宣言ごとに辺を作り、alias・features・`allow_global_commands`
//!   を辺に保持する。後段の命令登録はこの辺をそのまま使う（別名や許可を
//!   他の依存へ継承しない）。
//! - `exports_global_commands = false` の Package ID は、要求範囲が交わらなければ
//!   同一プロファイル内で複数版を併存させてよい（R-04・R-11）。交わる場合は
//!   共通版を優先する（R-11 の後半）。
//! - `exports_global_commands = true` の版を採用するなら、同じ Package ID は
//!   単一版に収束させる。収束できなければエラー（R-05・R-10）。
//! - 別パッケージ間の `global_commands` の同名衝突はエラー（R-06）。
//! - yank 版は新規解決では選ばない。既存 lock に記録があり、index の選択済み
//!   アーティファクトとハッシュが一致する場合だけ再利用し、警告する（R-09）。
//! - lock で固定された候補も、選択関数に現在の runtime・triple・ABI・glibc と
//!   ID＋SHA-256 の明示許可を再確認させる。不適格なら非 yank 版は同じ版の
//!   代替（universal など）へ切り替えるが、yank 版は lock のハッシュ一致以外へ
//!   切り替えない。代替がなければ失敗する。解除できない固定を黙って
//!   再利用しない。
//! - 後から見つかった要求で既存ノードが不適合になった場合、その ID の全要求を
//!   満たす共通版があれば一版へ集約する。交差しない scoped 要求だけ複数版を
//!   残し、global は常に単一版に収束させる。
//! - 候補は決定的に並べる。既存 lock と一致する版を先に試し、その中では版の
//!   降順。候補で行き詰まればバックトラックする。
//!
//! lock への変換は `Graph.toLock`。実行経路（CLI・project・plugin_registration）
//! への接続は統合作業に委ねる。

const std = @import("std");
const types = @import("v1_types.zig");
const semver = @import("semver.zig");
const lock_mod = @import("v1_lock.zig");

const Allocator = std.mem.Allocator;

pub const Feature = struct {
    name: []const u8,
    /// この feature を有効にすると追加で有効になる feature。
    enables: []const []const u8 = &.{},
};

/// sparse index の版。P10index の `Release` 契約に対応する。
pub const Release = struct {
    version: []const u8,
    yanked: bool = false,
    exports_global_commands: bool = false,
    global_commands: []const []const u8 = &.{},
    dependencies: []const types.Dependency = &.{},
    artifacts: []const types.Artifact = &.{},
    /// 仕様 §2 の feature 表。名前から追加 feature への写像。
    features: []const Feature = &.{},
};

/// sparse index のパッケージ。P10index の `Package` 契約に対応する。
pub const Package = struct {
    id: []const u8,
    versions: []const Release = &.{},
};

/// アーティファクト選択は P09 が所有する。P10 は選択関数を注入され、
/// target の詳細（triple・ABI・glibc）をここへ持ち込まない。
pub const ArtifactSelector = struct {
    ctx: ?*anyopaque = null,
    selectFn: *const fn (ctx: ?*anyopaque, id: []const u8, artifacts: []const types.Artifact) anyerror!?usize,

    pub fn select(self: ArtifactSelector, id: []const u8, artifacts: []const types.Artifact) anyerror!?usize {
        return self.selectFn(self.ctx, id, artifacts);
    }
};

/// `root` と `index`（およびその文字列）は返却された `Graph` より長生き
/// しなければならない。`Graph` は入力スライスを借用する。
pub const Options = struct {
    profile: []const u8 = "default",
    runtime: types.Runtime = .lnako,
    target_triple: ?[]const u8 = null,
    root: []const types.Dependency = &.{},
    index: []const Package = &.{},
    lock: ?*const lock_mod.Lock = null,
    /// lock 内で参照するプロファイル名。省略時は `profile`。
    lock_profile: ?[]const u8 = null,
    artifacts: ?ArtifactSelector = null,
};

pub const FailureKind = enum {
    unknown_package,
    no_solution,
    global_version_conflict,
    global_command_conflict,
    invalid_range,
    invalid_release,
    feature_cycle,
    unknown_feature,
    artifact_selection_failed,
};

pub const Failure = struct {
    kind: FailureKind,
    id: []const u8 = "",
    req: []const u8 = "",
    detail: []const u8 = "",
};

pub const WarningKind = enum {
    yanked_from_lock,
    lock_hash_mismatch,
    lock_node_missing,
};

pub const Warning = struct {
    kind: WarningKind,
    id: []const u8,
    version: []const u8,
};

pub const Node = struct {
    id: []const u8,
    version: []const u8,
    release: *const Release,
    /// 選択したアーティファクトの SHA-256。選択関数が未指定なら空。
    sha256: []const u8,
    kind: ?types.Kind,
    global: bool,
    features: []const []const u8,
};

pub const Edge = struct {
    /// `null` はルートからの直接依存。
    from: ?usize,
    to: usize,
    /// 宣言元の dependencies / root 配列内の位置。
    dep_index: usize,
    id: []const u8,
    req: []const u8,
    alias: ?[]const u8,
    features: []const []const u8,
    default_features: bool,
    optional: bool,
    allow_global_commands: bool,
    runtimes: []const types.Runtime,
};

pub const Graph = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    profile: []const u8,
    runtime: types.Runtime,
    target_triple: ?[]const u8,
    nodes: []const Node,
    edges: []const Edge,
    /// `edges` の先頭からこの件数までがルート（直接依存）の辺。
    root_count: usize,
    warnings: []const Warning,

    pub fn deinit(self: *Graph) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn rootEdges(self: *const Graph) []const Edge {
        return self.edges[0..self.root_count];
    }

    pub fn nodeEdges(self: *const Graph) []const Edge {
        return self.edges[self.root_count..];
    }

    pub fn findNode(self: *const Graph, id: []const u8, version: []const u8) ?usize {
        for (self.nodes, 0..) |node, index| {
            if (std.mem.eql(u8, node.id, id) and std.mem.eql(u8, node.version, version)) return index;
        }
        return null;
    }

    pub fn nodeKey(self: *const Graph, allocator: Allocator, index: usize) ![]const u8 {
        const node = self.nodes[index];
        return std.fmt.allocPrint(allocator, "{s}@{s}", .{ node.id, node.version });
    }

    /// 解決済みグラフを lock 構築用の入力へ変換する。`allocator` は返却する
    /// スライスを所有する。複数プロファイルを一つの lock にまとめるときは、
    /// プロファイルごとにこれを作り `v1_lock.fromGraphs` へ渡す。
    pub fn toLockInput(self: *Graph, allocator: Allocator) lock_mod.Error!lock_mod.GraphInput {
        var nodes = try allocator.alloc(lock_mod.GraphNode, self.nodes.len);
        for (self.nodes, 0..) |node, index| {
            nodes[index] = .{
                .id = node.id,
                .version = node.version,
                .sha256 = node.sha256,
                .kind = node.kind orelse return error.MissingArtifact,
                .global = node.global,
            };
        }
        var root: std.ArrayList(lock_mod.GraphEdge) = .empty;
        var edges: std.ArrayList(lock_mod.GraphEdge) = .empty;
        for (self.edges) |edge| {
            const to = self.nodes[edge.to];
            if (edge.from) |from_index| {
                const from = self.nodes[from_index];
                try edges.append(allocator, .{
                    .from = .{ .id = from.id, .version = from.version },
                    .to = .{ .id = to.id, .version = to.version },
                    .id = edge.id,
                    .req = edge.req,
                    .alias = edge.alias,
                    .features = edge.features,
                    .default_features = edge.default_features,
                    .optional = edge.optional,
                    .allow_global_commands = edge.allow_global_commands,
                    .runtimes = edge.runtimes,
                });
            } else {
                try root.append(allocator, .{
                    .to = .{ .id = to.id, .version = to.version },
                    .id = edge.id,
                    .req = edge.req,
                    .alias = edge.alias,
                    .features = edge.features,
                    .default_features = edge.default_features,
                    .optional = edge.optional,
                    .allow_global_commands = edge.allow_global_commands,
                    .runtimes = edge.runtimes,
                });
            }
        }
        return .{
            .profile = self.profile,
            .runtime = self.runtime,
            .target_triple = self.target_triple,
            .nodes = nodes,
            .root = root.items,
            .edges = edges.items,
        };
    }

    /// 解決済みグラフを新形式 lock へ変換する。アーティファクト未選択の
    /// ノードがあれば `error.MissingArtifact`。
    pub fn toLock(self: *Graph) lock_mod.Error!lock_mod.Lock {
        const input = try self.toLockInput(self.arena.allocator());
        return lock_mod.fromGraph(self.gpa, input);
    }
};

pub const Outcome = union(enum) {
    resolved: Graph,
    failed: Failure,
};

// ---------------------------------------------------------------------------
// 内部
// ---------------------------------------------------------------------------

const Declaration = struct {
    id: []const u8,
    req: []const u8,
    alias: ?[]const u8 = null,
    features: []const []const u8 = &.{},
    default_features: bool = true,
    optional: bool = false,
    allow_global_commands: bool = false,
    runtimes: []const types.Runtime = &.{},
};

const Requirement = struct {
    decl: Declaration,
    origin: ?usize,
    dep_index: usize,
    range: semver.Range,
    handled: bool = false,
};

const Candidate = struct {
    id: []const u8,
    release: *const Release,
    version: semver.Version,
    locked: bool,
    lock_kind: ?types.Kind,
    lock_sha: ?[]const u8,
    yanked_allowed: bool,
};

const PackageInfo = struct {
    id: []const u8,
    candidates: []Candidate,
};

const NodeSlot = struct {
    id: []const u8,
    release: *const Release,
    version: semver.Version,
    version_text: []const u8,
    sha256: []const u8,
    kind: ?types.Kind,
    global: bool,
    features: std.ArrayList([]const u8),
    deps_added: []bool,
};

const Undo = union(enum) {
    node,
    req,
    handled: usize,
    feature: struct { node: usize, len: usize },
    dep: struct { node: usize, dep: usize },
};

const Solver = struct {
    allocator: Allocator,
    options: *const Options,
    lock_profile: ?*const lock_mod.Profile,
    packages: []PackageInfo,
    reqs: std.ArrayList(Requirement) = .empty,
    nodes: std.ArrayList(NodeSlot) = .empty,
    undo: std.ArrayList(Undo) = .empty,
    warnings: std.ArrayList(Warning) = .empty,
    failure: ?Failure = null,
    saw_global_conflict: bool = false,
    root_count: usize = 0,
    /// 遅れて見つかった要求で既存版を共通版へ集約する試行を行うか。
    strict_common: bool,
    /// strict 試行が「共通版へ集約するためにバックトラックが必要」と判断した。
    consolidation_required: bool = false,

    fn init(allocator: Allocator, options: *const Options, strict_common: bool) !Solver {
        var solver = Solver{
            .allocator = allocator,
            .options = options,
            .lock_profile = null,
            .packages = &.{},
            .strict_common = strict_common,
        };
        if (options.lock) |lock| {
            const profile_name = options.lock_profile orelse options.profile;
            solver.lock_profile = lock.findProfile(profile_name);
        }
        solver.packages = try solver.buildPackages();
        for (options.root, 0..) |dep, index| {
            if (!try solver.pushRootRequirement(dep, index)) break;
        }
        return solver;
    }

    fn buildPackages(self: *Solver) ![]PackageInfo {
        var packages: std.ArrayList(PackageInfo) = .empty;
        for (self.options.index) |package| {
            var candidates: std.ArrayList(Candidate) = .empty;
            for (package.versions) |*release| {
                const version = semver.Version.parse(release.version) catch {
                    // 公開バージョンとしての構文が正しくても、node-semver の
                    // Number.MAX_SAFE_INTEGER 制限で表現できない版は range 適合
                    // の対象外とする。node-semver の Range.test と同じく不一致
                    // として扱い、index 全体を invalid_release で失敗させない。
                    if (types.validPublicVersion(release.version)) continue;
                    self.recordFailure(.{ .kind = .invalid_release, .id = package.id, .req = release.version });
                    continue;
                };
                var duplicate = false;
                for (candidates.items) |candidate| {
                    if (candidate.version.eql(version)) duplicate = true;
                }
                if (duplicate) {
                    self.recordFailure(.{ .kind = .invalid_release, .id = package.id, .req = release.version });
                    continue;
                }
                var locked = false;
                var lock_kind: ?types.Kind = null;
                var lock_sha: ?[]const u8 = null;
                if (self.lock_profile) |profile| {
                    if (findLockNode(profile, package.id, release.version)) |node| {
                        if (releaseHasArtifact(release, node.kind, node.sha256)) {
                            locked = true;
                            lock_kind = node.kind;
                            lock_sha = node.sha256;
                        } else {
                            try self.addWarning(.lock_hash_mismatch, package.id, release.version);
                        }
                    }
                }
                try candidates.append(self.allocator, .{
                    .id = package.id,
                    .release = release,
                    .version = version,
                    .locked = locked,
                    .lock_kind = lock_kind,
                    .lock_sha = lock_sha,
                    .yanked_allowed = locked,
                });
            }
            std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);
            try packages.append(self.allocator, .{
                .id = package.id,
                .candidates = try candidates.toOwnedSlice(self.allocator),
            });
        }
        // lock にだけ存在するノードは診断に残す（解決は続行できる）。
        if (self.lock_profile) |profile| {
            for (profile.nodes) |node| {
                var found = false;
                for (packages.items) |package| {
                    if (!std.mem.eql(u8, package.id, node.id)) continue;
                    for (package.candidates) |candidate| {
                        if (std.mem.eql(u8, candidate.release.version, node.version)) found = true;
                    }
                }
                if (!found) try self.addWarning(.lock_node_missing, node.id, node.version);
            }
        }
        return packages.toOwnedSlice(self.allocator);
    }

    fn pushRootRequirement(self: *Solver, dep: types.Dependency, index: usize) !bool {
        if (!dependencyApplies(dep, self.options.runtime)) return true;
        const range = types.parseRange(self.allocator, dep.req) catch {
            self.recordFailure(.{ .kind = .invalid_range, .id = dep.id, .req = dep.req });
            return false;
        };
        try self.reqs.append(self.allocator, .{
            .decl = declarationOf(dep),
            .origin = null,
            .dep_index = index,
            .range = range,
        });
        self.root_count += 1;
        return true;
    }

    fn recordFailure(self: *Solver, failure: Failure) void {
        if (self.failure == null or self.failure.?.kind == .no_solution) self.failure = failure;
    }

    fn addWarning(self: *Solver, kind: WarningKind, id: []const u8, version: []const u8) !void {
        for (self.warnings.items) |warning| {
            if (warning.kind == kind and std.mem.eql(u8, warning.id, id) and std.mem.eql(u8, warning.version, version)) return;
        }
        try self.warnings.append(self.allocator, .{ .kind = kind, .id = id, .version = version });
    }

    fn findPackage(self: *Solver, id: []const u8) ?*const PackageInfo {
        for (self.packages) |*package| {
            if (std.mem.eql(u8, package.id, id)) return package;
        }
        return null;
    }

    fn satisfiesAllRequirements(self: *Solver, id: []const u8, version: semver.Version) bool {
        for (self.reqs.items) |req| {
            if (!std.mem.eql(u8, req.decl.id, id)) continue;
            if (!req.range.satisfies(version)) return false;
        }
        return true;
    }

    /// 同じ ID の全要求を一版で満たす既存ノード。決定的に最高版を選ぶ。
    fn findCommonNode(self: *Solver, id: []const u8) ?usize {
        var best: ?usize = null;
        var best_version: ?semver.Version = null;
        for (self.nodes.items, 0..) |node, index| {
            if (!std.mem.eql(u8, node.id, id)) continue;
            if (!self.satisfiesAllRequirements(id, node.version)) continue;
            if (best_version) |version| {
                if (node.version.order(version) != .gt) continue;
            }
            best = index;
            best_version = node.version;
        }
        return best;
    }

    fn findSatisfying(self: *Solver, id: []const u8, range: semver.Range) ?usize {
        var best: ?usize = null;
        var best_version: ?semver.Version = null;
        for (self.nodes.items, 0..) |node, index| {
            if (!std.mem.eql(u8, node.id, id)) continue;
            if (!range.satisfies(node.version)) continue;
            if (best_version) |version| {
                if (node.version.order(version) != .gt) continue;
            }
            best = index;
            best_version = node.version;
        }
        return best;
    }

    /// 同じ ID の既存ノードのうち、現在の全要求を満たさないものがあるか。
    fn hasConflictingNode(self: *Solver, id: []const u8) bool {
        for (self.nodes.items) |node| {
            if (!std.mem.eql(u8, node.id, id)) continue;
            if (!self.satisfiesAllRequirements(id, node.version)) return true;
        }
        return false;
    }

    /// 追加しようとしている要求を含む全要求を一版で満たす候補があるか。
    /// アーティファクトの選択可否はここでは見ない。strict 試行が行き詰まった
    /// 場合は、呼出し側が複数版を受け入れる緩和試行へ戻る。
    fn hasCommonCandidate(self: *Solver, package: *const PackageInfo, req: Requirement) bool {
        for (package.candidates) |candidate| {
            if (candidate.release.yanked and !candidate.yanked_allowed) continue;
            if (!req.range.satisfies(candidate.version)) continue;
            if (!self.satisfiesAllRequirements(req.decl.id, candidate.version)) continue;
            return true;
        }
        return false;
    }

    fn canAdd(self: *Solver, id: []const u8, candidate: Candidate) bool {
        var existing_count: usize = 0;
        var existing_global = false;
        for (self.nodes.items) |node| {
            if (!std.mem.eql(u8, node.id, id)) continue;
            existing_count += 1;
            if (node.global) existing_global = true;
        }
        if (existing_global) {
            self.saw_global_conflict = true;
            return false;
        }
        if (candidate.release.exports_global_commands) {
            if (existing_count > 0) {
                self.saw_global_conflict = true;
                return false;
            }
            for (self.reqs.items) |req| {
                if (!std.mem.eql(u8, req.decl.id, id)) continue;
                if (!req.range.satisfies(candidate.version)) {
                    self.saw_global_conflict = true;
                    return false;
                }
            }
        }
        return true;
    }

    fn addNode(self: *Solver, candidate: Candidate, decl: Declaration) !?usize {
        var sha256: []const u8 = "";
        var kind: ?types.Kind = null;
        if (candidate.locked) {
            const lock_sha = candidate.lock_sha.?;
            const lock_kind = candidate.lock_kind.?;
            if (self.options.artifacts) |selector| {
                // lock のアーティファクトも現在の環境と許可で再評価する。
                // 不適格な固定をそのまま再利用すると、許可取消しや ABI 変更を
                // 迂回してビルド工程へ進んでしまう。
                if (try lockedArtifactUsable(selector, candidate, lock_kind, lock_sha)) {
                    sha256 = lock_sha;
                    kind = lock_kind;
                } else if (candidate.release.yanked) {
                    // yank 済み版は lock が固定した SHA-256 のアーティファクトだけ
                    // 再利用できる（§6.2・R-09）。同じ版に別ハッシュの universal が
                    // あっても、それを新規選択して yank を迂回してはならない。
                    self.recordFailure(.{
                        .kind = .artifact_selection_failed,
                        .id = candidate.id,
                        .req = candidate.release.version,
                        .detail = "yank 済み版は lock の SHA-256 と一致するアーティファクトだけ再利用できます",
                    });
                    return null;
                } else if (!try self.selectArtifact(selector, candidate, &sha256, &kind)) {
                    return null;
                }
            } else {
                sha256 = lock_sha;
                kind = lock_kind;
            }
        } else if (self.options.artifacts) |selector| {
            if (!try self.selectArtifact(selector, candidate, &sha256, &kind)) return null;
        }

        const node_index = self.nodes.items.len;
        const deps_added = try self.allocator.alloc(bool, candidate.release.dependencies.len);
        @memset(deps_added, false);
        try self.nodes.append(self.allocator, .{
            .id = candidate.id,
            .release = candidate.release,
            .version = candidate.version,
            .version_text = candidate.release.version,
            .sha256 = sha256,
            .kind = kind,
            .global = candidate.release.exports_global_commands,
            .features = .empty,
            .deps_added = deps_added,
        });
        try self.undo.append(self.allocator, .node);

        if (!try self.checkFeatureCycle(candidate.release)) return null;
        if (!try self.addDeclFeatures(node_index, decl)) return null;
        if (candidate.release.yanked) try self.addWarning(.yanked_from_lock, candidate.id, candidate.release.version);
        return node_index;
    }

    /// 選択関数で現在の環境・許可に適合するアーティファクトを選び直す。
    /// 適合候補がなければ診断を残して false を返す。
    fn selectArtifact(
        self: *Solver,
        selector: ArtifactSelector,
        candidate: Candidate,
        sha256: *[]const u8,
        kind: *?types.Kind,
    ) !bool {
        const selected = selector.select(candidate.id, candidate.release.artifacts) catch {
            self.recordFailure(.{ .kind = .artifact_selection_failed, .id = candidate.id, .req = candidate.release.version });
            return false;
        };
        const index = selected orelse {
            self.recordFailure(.{ .kind = .artifact_selection_failed, .id = candidate.id, .req = candidate.release.version });
            return false;
        };
        if (index >= candidate.release.artifacts.len) {
            self.recordFailure(.{ .kind = .artifact_selection_failed, .id = candidate.id, .req = candidate.release.version });
            return false;
        }
        sha256.* = candidate.release.artifacts[index].sha256;
        kind.* = candidate.release.artifacts[index].kind;
        return true;
    }

    fn mergeFeatures(self: *Solver, node_index: usize, decl: Declaration) !bool {
        return self.addDeclFeatures(node_index, decl);
    }

    fn addDeclFeatures(self: *Solver, node_index: usize, decl: Declaration) !bool {
        if (decl.default_features) {
            if (!try self.addFeature(node_index, "default")) return false;
        }
        for (decl.features) |feature| {
            if (!try self.addFeature(node_index, feature)) return false;
        }
        return self.addEnabledDependencies(node_index);
    }

    fn addFeature(self: *Solver, node_index: usize, name: []const u8) !bool {
        if (contains(self.nodes.items[node_index].features.items, name)) return true;
        const release = self.nodes.items[node_index].release;
        const feature = findFeature(release, name) orelse {
            if (std.mem.eql(u8, name, "default")) return true;
            self.recordFailure(.{ .kind = .unknown_feature, .id = self.nodes.items[node_index].id, .req = name });
            return false;
        };
        const length = self.nodes.items[node_index].features.items.len;
        try self.nodes.items[node_index].features.append(self.allocator, name);
        try self.undo.append(self.allocator, .{ .feature = .{ .node = node_index, .len = length } });
        for (feature.enables) |enabled| {
            if (!try self.addFeature(node_index, enabled)) return false;
        }
        return true;
    }

    fn addEnabledDependencies(self: *Solver, node_index: usize) !bool {
        const release = self.nodes.items[node_index].release;
        for (release.dependencies, 0..) |dep, index| {
            if (self.nodes.items[node_index].deps_added[index]) continue;
            if (!dependencyApplies(dep, self.options.runtime)) continue;
            if (!dependencyEnabled(dep, self.nodes.items[node_index].features.items)) continue;
            self.nodes.items[node_index].deps_added[index] = true;
            try self.undo.append(self.allocator, .{ .dep = .{ .node = node_index, .dep = index } });
            const range = types.parseRange(self.allocator, dep.req) catch {
                self.recordFailure(.{ .kind = .invalid_range, .id = dep.id, .req = dep.req });
                return false;
            };
            try self.reqs.append(self.allocator, .{
                .decl = declarationOf(dep),
                .origin = node_index,
                .dep_index = index,
                .range = range,
            });
            try self.undo.append(self.allocator, .req);
        }
        return true;
    }

    fn checkFeatureCycle(self: *Solver, release: *const Release) !bool {
        const colors = try self.allocator.alloc(u8, release.features.len);
        @memset(colors, 0);
        for (release.features, 0..) |_, index| {
            if (colors[index] == 0) {
                if (!try self.visitFeature(release, index, colors)) return false;
            }
        }
        return true;
    }

    fn visitFeature(self: *Solver, release: *const Release, index: usize, colors: []u8) !bool {
        colors[index] = 1;
        for (release.features[index].enables) |enabled| {
            const next = findFeatureIndex(release, enabled) orelse {
                self.recordFailure(.{ .kind = .unknown_feature, .req = enabled });
                return false;
            };
            if (colors[next] == 1) {
                self.recordFailure(.{ .kind = .feature_cycle, .req = release.features[index].name });
                return false;
            }
            if (colors[next] == 0) {
                if (!try self.visitFeature(release, next, colors)) return false;
            }
        }
        colors[index] = 2;
        return true;
    }

    fn undoTo(self: *Solver, checkpoint: usize) void {
        while (self.undo.items.len > checkpoint) {
            const item = self.undo.pop().?;
            switch (item) {
                .node => {
                    _ = self.nodes.pop();
                },
                .req => {
                    _ = self.reqs.pop();
                },
                .handled => |index| {
                    self.reqs.items[index].handled = false;
                },
                .feature => |entry| {
                    self.nodes.items[entry.node].features.shrinkRetainingCapacity(entry.len);
                },
                .dep => |entry| {
                    self.nodes.items[entry.node].deps_added[entry.dep] = false;
                },
            }
        }
    }

    fn search(self: *Solver) !bool {
        var open: ?usize = null;
        for (self.reqs.items, 0..) |req, index| {
            if (!req.handled) {
                open = index;
                break;
            }
        }
        if (open == null) return true;
        const req_index = open.?;
        const req = self.reqs.items[req_index];

        if (self.findCommonNode(req.decl.id)) |node_index| {
            const checkpoint = self.undo.items.len;
            if (try self.mergeFeatures(node_index, req.decl)) {
                self.reqs.items[req_index].handled = true;
                try self.undo.append(self.allocator, .{ .handled = req_index });
                if (try self.search()) return true;
            }
            self.undoTo(checkpoint);
            return false;
        }
        if (self.findSatisfying(req.decl.id, req.range)) |node_index| {
            const checkpoint = self.undo.items.len;
            if (try self.mergeFeatures(node_index, req.decl)) {
                self.reqs.items[req_index].handled = true;
                try self.undo.append(self.allocator, .{ .handled = req_index });
                if (try self.search()) return true;
            }
            self.undoTo(checkpoint);
            return false;
        }

        const package = self.findPackage(req.decl.id) orelse {
            self.recordFailure(.{ .kind = .unknown_package, .id = req.decl.id, .req = req.decl.req });
            return false;
        };
        // 深いダイヤモンドで後から届いた要求が既存版と交差しない場合でも、
        // 全要求を満たす共通版があれば二版目を追加しない。ここで失敗を返すと、
        // 既存版を選んだ分岐まで戻って共通版を試す。共通版が本当に無い場合
        // （scoped の交差しない範囲）だけ複数版を残す。
        if (self.strict_common and self.hasConflictingNode(req.decl.id) and self.hasCommonCandidate(package, req)) {
            self.consolidation_required = true;
            return false;
        }
        var any_candidate = false;
        // 一版で全要求を満たす候補を先に試し、共通版を優先する（R-11）。
        var common_pass: u8 = 0;
        while (common_pass < 2) : (common_pass += 1) {
            for (package.candidates) |candidate| {
                if (!req.range.satisfies(candidate.version)) continue;
                if (candidate.release.yanked and !candidate.yanked_allowed) continue;
                any_candidate = true;
                const common = self.satisfiesAllRequirements(req.decl.id, candidate.version);
                if (common != (common_pass == 0)) continue;
                if (!self.canAdd(req.decl.id, candidate)) continue;
                const checkpoint = self.undo.items.len;
                if (try self.addNode(candidate, req.decl)) |_| {
                    self.reqs.items[req_index].handled = true;
                    try self.undo.append(self.allocator, .{ .handled = req_index });
                    if (try self.search()) return true;
                }
                self.undoTo(checkpoint);
            }
        }
        if (!any_candidate and package.candidates.len == 0) {
            self.recordFailure(.{ .kind = .unknown_package, .id = req.decl.id, .req = req.decl.req });
        } else if (self.failure == null) {
            self.recordFailure(.{ .kind = .no_solution, .id = req.decl.id, .req = req.decl.req });
        }
        return false;
    }

    fn validateGlobals(self: *Solver) !bool {
        var providers = std.StringHashMap(Provider).init(self.allocator);
        for (self.nodes.items) |node| {
            if (!node.global) continue;
            for (node.release.global_commands) |name| {
                if (providers.get(name)) |existing| {
                    if (!std.mem.eql(u8, existing.id, node.id) or !std.mem.eql(u8, existing.version, node.version_text)) {
                        self.recordFailure(.{ .kind = .global_command_conflict, .id = node.id, .req = name });
                        return false;
                    }
                } else {
                    try providers.put(name, .{ .id = node.id, .version = node.version_text });
                }
            }
        }
        return true;
    }
};

const Provider = struct {
    id: []const u8,
    version: []const u8,
};

fn declarationOf(dep: types.Dependency) Declaration {
    return .{
        .id = dep.id,
        .req = dep.req,
        .alias = dep.alias,
        .features = dep.features,
        .default_features = dep.default_features,
        .optional = dep.optional,
        .allow_global_commands = dep.allow_global_commands,
        .runtimes = dep.runtimes,
    };
}

fn candidateLessThan(_: void, a: Candidate, b: Candidate) bool {
    if (a.locked != b.locked) return a.locked;
    const order = a.version.order(b.version);
    if (order != .eq) return order == .gt;
    return std.mem.order(u8, a.release.version, b.release.version) == .lt;
}

fn findLockNode(profile: *const lock_mod.Profile, id: []const u8, version: []const u8) ?*const lock_mod.Node {
    for (profile.nodes) |*node| {
        if (std.mem.eql(u8, node.id, id) and std.mem.eql(u8, node.version, version)) return node;
    }
    return null;
}

fn releaseHasArtifact(release: *const Release, kind: types.Kind, sha256: []const u8) bool {
    for (release.artifacts) |artifact| {
        if (artifact.kind == kind and std.mem.eql(u8, artifact.sha256, sha256)) return true;
    }
    return false;
}

/// lock に記録されたアーティファクトだけを選択関数へ渡し、現在の runtime・
/// triple・ABI・glibc と ID＋SHA-256 の許可で利用できるか確認する。単独要素の
/// 選択は「そのアーティファクトが適合するか」の判定になる。
fn lockedArtifactUsable(
    selector: ArtifactSelector,
    candidate: Candidate,
    lock_kind: types.Kind,
    lock_sha: []const u8,
) !bool {
    for (candidate.release.artifacts, 0..) |artifact, index| {
        if (artifact.kind != lock_kind) continue;
        if (!std.mem.eql(u8, artifact.sha256, lock_sha)) continue;
        // 失敗時は選択側が artifacts を保持することがあるため、スタックの
        // 一時配列ではなく release 内の安定した1要素スライスを渡す。
        const selected = selector.select(candidate.id, candidate.release.artifacts[index .. index + 1]) catch return false;
        return selected != null and selected.? == 0;
    }
    return false;
}

fn contains(items: []const []const u8, name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn findFeature(release: *const Release, name: []const u8) ?*const Feature {
    for (release.features) |*feature| {
        if (std.mem.eql(u8, feature.name, name)) return feature;
    }
    return null;
}

fn findFeatureIndex(release: *const Release, name: []const u8) ?usize {
    for (release.features, 0..) |feature, index| {
        if (std.mem.eql(u8, feature.name, name)) return index;
    }
    return null;
}

fn dependencyApplies(dep: types.Dependency, runtime: types.Runtime) bool {
    if (dep.runtimes.len == 0) return true;
    for (dep.runtimes) |declared| {
        if (declared == runtime) return true;
    }
    return false;
}

/// optional 依存の有効化規則。仕様は feature との対応の詳細を実装に委ねて
/// いるため、ここでは Cargo と同じく「feature 名が依存の alias（なければ
/// `name`）と一致する」または `dep:<local>` と一致する場合に有効とする。
fn dependencyEnabled(dep: types.Dependency, features: []const []const u8) bool {
    if (!dep.optional) return true;
    const local = dep.alias orelse packageName(dep.id);
    if (contains(features, local)) return true;
    for (features) |feature| {
        if (std.mem.startsWith(u8, feature, "dep:") and std.mem.eql(u8, feature[4..], local)) return true;
    }
    return false;
}

fn packageName(id: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, id, '/')) |slash| return id[slash + 1 ..];
    return id;
}

// ---------------------------------------------------------------------------
// 公開入口
// ---------------------------------------------------------------------------

/// 依存グラフを解く。論理的な失敗（未知パッケージ・収束不能・命令名衝突・
/// yank 以外の不適合など）は `Outcome.failed` で返し、OOM だけを error に
/// する。成功時は `Graph` を呼出し側が `deinit` する。
///
/// まず共通版への集約を優先して解き、集約のためのバックトラックで解けない
/// 場合だけ、交差しない scoped 要求を複数版のまま受け入れる。これにより
/// 要求の発見順や深さで共通版を逃さない。
pub fn resolve(parent: Allocator, options: Options) !Outcome {
    const attempt = try solve(parent, options, true);
    switch (attempt.outcome) {
        .resolved => return attempt.outcome,
        .failed => {},
    }
    if (!attempt.consolidation_required) return attempt.outcome;
    const relaxed = try solve(parent, options, false);
    return relaxed.outcome;
}

const Attempt = struct {
    outcome: Outcome,
    consolidation_required: bool,
};

fn solve(parent: Allocator, options: Options, strict_common: bool) !Attempt {
    var arena = std.heap.ArenaAllocator.init(parent);
    var keep_arena = false;
    defer if (!keep_arena) arena.deinit();
    const allocator = arena.allocator();

    var solver = try Solver.init(allocator, &options, strict_common);
    if (solver.failure) |failure| {
        return .{ .outcome = .{ .failed = failure }, .consolidation_required = solver.consolidation_required };
    }

    if (!try solver.search()) {
        var failure = solver.failure orelse Failure{ .kind = .no_solution };
        if (solver.saw_global_conflict and failure.kind == .no_solution) {
            failure = .{ .kind = .global_version_conflict, .id = failure.id, .req = failure.req };
        }
        return .{ .outcome = .{ .failed = failure }, .consolidation_required = solver.consolidation_required };
    }
    if (!try solver.validateGlobals()) {
        return .{ .outcome = .{ .failed = solver.failure.? }, .consolidation_required = solver.consolidation_required };
    }

    var edges: std.ArrayList(Edge) = .empty;
    for (solver.reqs.items) |req| {
        const to = solver.findSatisfying(req.decl.id, req.range) orelse {
            return .{
                .outcome = .{ .failed = .{ .kind = .no_solution, .id = req.decl.id, .req = req.decl.req } },
                .consolidation_required = solver.consolidation_required,
            };
        };
        try edges.append(allocator, .{
            .from = req.origin,
            .to = to,
            .dep_index = req.dep_index,
            .id = req.decl.id,
            .req = req.decl.req,
            .alias = req.decl.alias,
            .features = req.decl.features,
            .default_features = req.decl.default_features,
            .optional = req.decl.optional,
            .allow_global_commands = req.decl.allow_global_commands,
            .runtimes = req.decl.runtimes,
        });
    }

    var nodes = try allocator.alloc(Node, solver.nodes.items.len);
    for (solver.nodes.items, 0..) |*slot, index| {
        nodes[index] = .{
            .id = slot.id,
            .version = slot.version_text,
            .release = slot.release,
            .sha256 = slot.sha256,
            .kind = slot.kind,
            .global = slot.global,
            .features = try slot.features.toOwnedSlice(allocator),
        };
    }

    const warnings = try solver.warnings.toOwnedSlice(allocator);
    const graph = Graph{
        .gpa = parent,
        .arena = arena,
        .profile = options.profile,
        .runtime = options.runtime,
        .target_triple = options.target_triple,
        .nodes = nodes,
        .edges = try edges.toOwnedSlice(allocator),
        .root_count = solver.root_count,
        .warnings = warnings,
    };
    keep_arena = true;
    return .{ .outcome = .{ .resolved = graph }, .consolidation_required = false };
}
