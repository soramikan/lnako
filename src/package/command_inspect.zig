//! ソース命令 metadata の静的検査（Issue #52 / PS10）。
//!
//! `lnako check` から呼び、package の初期化・native/JS plugin のロードを
//! 一切行わずに次を行う:
//! - environment に snapshot された `commands` を索引化する
//! - source export がある package は AST から再生成し snapshot と照合する
//! - 標準命令・他 package との命令名衝突を決定的に診断する
//! - metadata 不足・native/JS のみ等の未検査範囲を列挙する
//! - 厳格共用検査（`--strict-sharing`）では未検査が残れば E033
//! - 選択 feature が専用に引き込む root 依存と推移依存を表示する
//!
//! 共用「保証済み」は静的に完全検査できた場合のみ。未検査があれば
//! `partial`、衝突/不一致/厳格失敗は `failed`。

const std = @import("std");
const diag = @import("diagnostics.zig");
const environment_mod = @import("environment.zig");
const features_mod = @import("features.zig");
const manifest_mod = @import("manifest.zig");
const npkg_commands = @import("npkg_commands.zig");
const npkg_commands_gen = @import("npkg_commands_gen.zig");
const npkg_files = @import("npkg_files.zig");
const builtin_commands = @import("../frontend/builtin_commands.zig");

const Allocator = std.mem.Allocator;

pub const Sharing = enum {
    /// 環境が無く命令検査をスキップした。
    skipped,
    /// 静的に検査可能な範囲をすべて検査し、衝突・不一致・未検査が無い。
    guaranteed,
    /// 未検査範囲がある（通常 check では失敗にしない）。
    partial,
    /// 衝突・不一致、または厳格共用検査での未検査。
    failed,
};

pub const UninspectedReason = enum {
    missing_metadata,
    /// source export があるが AST 再生成に失敗（path 解決・読取・構文）。
    source_unreadable,
    native_without_metadata,
    js_without_metadata,
};

pub const Uninspected = struct {
    package_key: []const u8,
    reason: UninspectedReason,

    pub fn reasonText(self: Uninspected) []const u8 {
        return switch (self.reason) {
            .missing_metadata => "missing_metadata",
            .source_unreadable => "source_unreadable",
            .native_without_metadata => "native_without_metadata",
            .js_without_metadata => "js_without_metadata",
        };
    }
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    sharing: Sharing = .skipped,
    inspected_count: usize = 0,
    uninspected: []const Uninspected = &.{},
    collision_count: usize = 0,
    mismatch_count: usize = 0,
    /// 選択 feature の影響。manifest を渡していない、または feature 定義が
    /// 無いときは null（表示しない）。
    features: ?FeatureImpact = null,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn uninspectedCount(self: *const Report) usize {
        return self.uninspected.len;
    }
};

/// `check --features` / `--no-default-features` の選択。展開規則は lock
/// `input.features` と同じ（feature 名と依存 alias の双方を受け付ける）。
pub const FeatureRequest = struct {
    requested: []const []const u8 = &.{},
    use_default_features: bool = true,
};

pub const Options = struct {
    /// 未検査が残れば E033 で失敗する。
    strict_sharing: bool = false,
    /// `nako.toml` の解析結果。null は feature 影響を表示しない。
    manifest: ?*const manifest_mod.Manifest = null,
    features: FeatureRequest = .{},
};

/// 非 default feature だけが引き込む root 依存と、そこからしか到達できない
/// 推移依存。共通（default または feature 非依存）の構成と分けて表示する。
pub const DedicatedFeature = struct {
    name: []const u8,
    /// この feature だけが有効化する root 依存 alias。
    roots: []const []const u8 = &.{},
    /// その root からしか到達できない推移依存 package key。
    packages: []const []const u8 = &.{},
};

/// 選択 feature の影響。環境 graph と manifest `[features]` だけで決まる。
pub const FeatureImpact = struct {
    /// 選択 feature と直接指定 alias（昇順）。
    selected: []const []const u8 = &.{},
    /// default feature または feature 非依存で有効な root 依存 alias（昇順）。
    common_roots: []const []const u8 = &.{},
    /// feature 専用の root 依存と推移依存（feature 名昇順）。
    dedicated: []const DedicatedFeature = &.{},
};

/// 環境 graph の alias 辺。`alias` は import scope の参照名。
const Edge = struct {
    alias: []const u8,
    package_key: []const u8,
};

/// 環境 graph の package 間辺。
const PackageEdge = struct {
    from: []const u8,
    to: []const u8,
};

const Owner = struct {
    package_key: []const u8,
    variable: bool,
    args_len: usize,
    josi_len: usize,
};

/// プロジェクト root dir 配下の `.nako/environment.json` を読み、
/// 命令 metadata を静的検査する。ファイルが無い・読めない場合は
/// `sharing = skipped` の空 Report（lock/env 整合は `inspectForCheck` 側）。
/// plugin のロード・初期化・scanner の実行は一切行わない。
pub fn inspectEnvironmentDir(
    gpa: Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    options: Options,
    diagnostics: *diag.List,
) error{OutOfMemory}!Report {
    var report = Report{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer report.deinit();
    const arena = report.arena.allocator();

    const env_rel = ".nako/" ++ environment_mod.environment_file;
    const bytes = root_dir.readFileAlloc(io, env_rel, gpa, .limited(environment_mod.max_environment_bytes)) catch {
        return report;
    };
    defer gpa.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always }) catch {
        try diagnostics.addFmt(
            diag.E034_INVALID_ENVIRONMENT_REFERENCE,
            .err,
            environment_mod.environment_file,
            .{},
            "environment.json is not valid JSON",
            .{},
        );
        report.sharing = .failed;
        return report;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try diagnostics.addFmt(
            diag.E034_INVALID_ENVIRONMENT_REFERENCE,
            .err,
            environment_mod.environment_file,
            .{},
            "environment.json root must be an object",
            .{},
        );
        report.sharing = .failed;
        return report;
    }
    const packages_value = parsed.value.object.get("packages") orelse {
        report.sharing = .guaranteed;
        return report;
    };
    if (packages_value != .object) {
        try diagnostics.addFmt(
            diag.E034_INVALID_ENVIRONMENT_REFERENCE,
            .err,
            "packages",
            .{},
            "environment.json packages must be an object",
            .{},
        );
        report.sharing = .failed;
        return report;
    }

    var owners: std.StringHashMapUnmanaged(Owner) = .empty;
    // key は arena 所有の command.name。report.arena が生きている間だけ有効。
    defer owners.deinit(gpa);

    var uninspected_list: std.ArrayList(Uninspected) = .empty;
    // 環境 graph の alias 辺と package 間辺。feature 影響の算出にだけ使う。
    // 文字列は `parsed`（関数末尾まで生存）を借用する。
    var root_edges: std.ArrayList(Edge) = .empty;
    defer root_edges.deinit(gpa);
    try collectImportEdges(gpa, parsed.value.object.get("dependencies"), &root_edges);
    var package_edges: std.ArrayList(PackageEdge) = .empty;
    defer package_edges.deinit(gpa);

    var package_it = packages_value.object.iterator();
    while (package_it.next()) |entry| {
        const package_key = try arena.dupe(u8, entry.key_ptr.*);
        if (entry.value_ptr.* != .object) continue;
        const record = entry.value_ptr.*.object;
        try collectPackageEdges(gpa, entry.key_ptr.*, record.get("dependencies"), &package_edges);

        const path_value = record.get("path") orelse continue;
        if (path_value != .string) continue;
        const rel_path = path_value.string;

        var commands = try parseCommands(arena, record.get("commands"));
        const export_flags = exportFlags(record.get("exports"));
        var source_regeneration_failed = false;

        if (export_flags.has_source) {
            const maybe_regenerated = try regenerateCommands(gpa, io, root_dir, rel_path, record.get("exports"), diagnostics);
            if (maybe_regenerated == null) {
                source_regeneration_failed = true;
                try uninspected_list.append(arena, .{
                    .package_key = package_key,
                    .reason = .source_unreadable,
                });
            } else if (maybe_regenerated) |regenerated_ptr| {
                var regenerated = regenerated_ptr;
                defer regenerated.deinit();
                const cmp = compareCommandLists(commands, regenerated.commands);
                if (commands.len != 0 and !cmp.equal) {
                    report.mismatch_count += 1;
                    try diagnostics.addFmt(
                        diag.E029_INVALID_VALUE,
                        .err,
                        package_key,
                        .{},
                        "commands metadata does not match source exports for package \"{s}\" ({s})",
                        .{ package_key, cmp.detail },
                    );
                }
                // snapshot が空でも source から索引できる
                if (commands.len == 0 and regenerated.commands.len != 0) {
                    commands = try cloneCommands(arena, regenerated.commands);
                }
            }
        }

        if (commands.len == 0) {
            if (export_flags.has_native and !export_flags.has_source and !export_flags.has_js) {
                try uninspected_list.append(arena, .{
                    .package_key = package_key,
                    .reason = .native_without_metadata,
                });
            } else if (export_flags.has_js and !export_flags.has_source) {
                try uninspected_list.append(arena, .{
                    .package_key = package_key,
                    .reason = .js_without_metadata,
                });
            } else if (export_flags.has_source and !source_regeneration_failed) {
                try uninspected_list.append(arena, .{
                    .package_key = package_key,
                    .reason = .missing_metadata,
                });
            }
            continue;
        }

        for (commands) |command| {
            report.inspected_count += 1;
            const name = command.name;
            if (isBuiltinCommand(name)) {
                report.collision_count += 1;
                try diagnostics.addFmt(
                    diag.E029_INVALID_VALUE,
                    .err,
                    package_key,
                    .{},
                    "command \"{s}\" in package \"{s}\" collides with a standard builtin command",
                    .{ name, package_key },
                );
                continue;
            }
            const gop = try owners.getOrPut(gpa, name);
            if (!gop.found_existing) {
                // name は arena スライスのまま key にする（dupe 不要）。
                gop.value_ptr.* = .{
                    .package_key = package_key,
                    .variable = command.variable,
                    .args_len = command.args.len,
                    .josi_len = command.josi.len,
                };
            } else {
                const existing = gop.value_ptr.*;
                if (!std.mem.eql(u8, existing.package_key, package_key)) {
                    report.collision_count += 1;
                    try diagnostics.addFmt(
                        diag.E029_INVALID_VALUE,
                        .err,
                        package_key,
                        .{},
                        "command \"{s}\" collides between packages \"{s}\" and \"{s}\"",
                        .{ name, existing.package_key, package_key },
                    );
                } else if (existing.variable != command.variable or
                    existing.args_len != command.args.len or
                    existing.josi_len != command.josi.len)
                {
                    report.mismatch_count += 1;
                    try diagnostics.addFmt(
                        diag.E029_INVALID_VALUE,
                        .err,
                        package_key,
                        .{},
                        "command \"{s}\" has conflicting declarations within package \"{s}\"",
                        .{ name, package_key },
                    );
                }
            }
        }
    }

    report.uninspected = try arena.dupe(Uninspected, uninspected_list.items);

    if (options.manifest) |manifest| {
        var scratch_arena = std.heap.ArenaAllocator.init(gpa);
        defer scratch_arena.deinit();
        report.features = try analyzeFeatureImpact(
            scratch_arena.allocator(),
            arena,
            manifest,
            options.features,
            root_edges.items,
            package_edges.items,
        );
    }

    if (report.collision_count > 0 or report.mismatch_count > 0) {
        report.sharing = .failed;
    } else if (report.uninspected.len > 0) {
        report.sharing = .partial;
        if (options.strict_sharing) {
            report.sharing = .failed;
            for (report.uninspected) |item| {
                try diagnostics.addFmt(
                    diag.E033_STRICT_SHARING_FAILED,
                    .err,
                    item.package_key,
                    .{},
                    "strict sharing check failed: package \"{s}\" has uninspected range ({s})",
                    .{ item.package_key, item.reasonText() },
                );
            }
        }
    } else {
        report.sharing = .guaranteed;
    }
    return report;
}

const ExportFlags = struct {
    has_source: bool = false,
    has_native: bool = false,
    has_js: bool = false,
};

fn exportFlags(exports_value: ?std.json.Value) ExportFlags {
    var flags = ExportFlags{};
    const exports = exports_value orelse return flags;
    if (exports != .array) return flags;
    for (exports.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get("path")) |path| {
            if (path == .string and isNakoSource(path.string)) flags.has_source = true;
            if (path == .string and npkg_commands_gen.isNativePluginArtifact(path.string)) flags.has_native = true;
            if (path == .string and isJsArtifact(path.string)) flags.has_js = true;
        }
        if (item.object.get("native") != null) flags.has_native = true;
        if (item.object.get("esm") != null) flags.has_js = true;
    }
    return flags;
}

fn isNakoSource(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".nako3") or
        std.ascii.eqlIgnoreCase(extension, ".dncl") or
        std.ascii.eqlIgnoreCase(extension, ".dncl2");
}

fn isJsArtifact(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".js") or
        std.ascii.eqlIgnoreCase(extension, ".mjs") or
        std.ascii.eqlIgnoreCase(extension, ".cjs");
}

fn isBuiltinCommand(name: []const u8) bool {
    for (builtin_commands.function_names) |builtin| {
        if (std.mem.eql(u8, builtin, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// feature 影響（専用推移依存の表示）
// ---------------------------------------------------------------------------

/// environment の import 依存配列（`{alias, package}`）を読む。
fn collectImportEdges(gpa: Allocator, value: ?std.json.Value, out: *std.ArrayList(Edge)) error{OutOfMemory}!void {
    const items = value orelse return;
    if (items != .array) return;
    for (items.array.items) |item| {
        if (item != .object) continue;
        const alias_value = item.object.get("alias") orelse continue;
        const package_value = item.object.get("package") orelse continue;
        if (alias_value != .string or package_value != .string) continue;
        try out.append(gpa, .{ .alias = alias_value.string, .package_key = package_value.string });
    }
}

/// package 記録の import 依存を package 間辺として読む。
fn collectPackageEdges(gpa: Allocator, from: []const u8, value: ?std.json.Value, out: *std.ArrayList(PackageEdge)) error{OutOfMemory}!void {
    const items = value orelse return;
    if (items != .array) return;
    for (items.array.items) |item| {
        if (item != .object) continue;
        const package_value = item.object.get("package") orelse continue;
        if (package_value != .string) continue;
        try out.append(gpa, .{ .from = from, .to = package_value.string });
    }
}

/// 環境 graph と manifest `[features]` から feature 影響を求める。
/// 環境に載っている root 依存（= 現行選択で有効な宣言）を feature 定義へ
/// 突き合わせ、非 default feature だけが引き込むものを専用として分離する。
/// 戻り値の文字列はすべて `out`（Report arena）が所有する。
fn analyzeFeatureImpact(
    scratch: Allocator,
    out: Allocator,
    manifest: *const manifest_mod.Manifest,
    request: FeatureRequest,
    root_edges: []const Edge,
    package_edges: []const PackageEdge,
) error{OutOfMemory}!?FeatureImpact {
    // feature 定義が無ければ gated 依存も無く、表示する影響が無い。
    if (manifest.features.count() == 0) return null;

    var aliases = try manifest.dependencyAliases(scratch);
    // 定義外の要求は `inspectForCheck` 側が E028/E027 で診断済み。
    // ここでは表示を諦めて重複診断を増やさない。
    const selection = features_mod.expand(scratch, &manifest.features, request.requested, request.use_default_features, &aliases, null) catch return null;

    // feature 名 → 推移展開した依存 alias 集合。feature 定義の入れ子を
    // 一段だけ見ると別名経由の gated 依存を取りこぼす。
    var feature_aliases = std.StringHashMap(std.StringHashMap(void)).init(scratch);
    var definition_it = manifest.features.keyIterator();
    while (definition_it.next()) |name_ptr| {
        const name = name_ptr.*;
        var set = std.StringHashMap(void).init(scratch);
        if (features_mod.expand(scratch, &manifest.features, &.{name}, false, &aliases, null)) |expanded_value| {
            const expanded = expanded_value;
            var alias_it = expanded.dependency_aliases.keyIterator();
            while (alias_it.next()) |alias| try set.put(alias.*, {});
        } else |_| {}
        try feature_aliases.put(name, set);
    }

    // 選択 = feature 名 + 直接指定された依存 alias。選択 feature が
    // 展開する alias は feature 側に含まれるため重複させない。
    var selected_names: std.ArrayList([]const u8) = .empty;
    var selected_features = selection.features.keyIterator();
    while (selected_features.next()) |name| try selected_names.append(scratch, name.*);
    var selected_aliases = selection.dependency_aliases.keyIterator();
    while (selected_aliases.next()) |name_ptr| {
        const name = name_ptr.*;
        var gated_by_selection = false;
        var selected_feature_it = selection.features.keyIterator();
        while (selected_feature_it.next()) |feature_name| {
            const set = feature_aliases.get(feature_name.*) orelse continue;
            if (set.contains(name)) {
                gated_by_selection = true;
                break;
            }
        }
        if (!gated_by_selection) try selected_names.append(scratch, name);
    }
    sortNames(selected_names.items);

    // root 依存は dep key と明示 alias の両方が環境に載り得るため、
    // package key 単位にまとめてから feature へ突き合わせる。
    var aliases_by_key = std.StringHashMap(std.ArrayList([]const u8)).init(scratch);
    for (root_edges) |edge| {
        const gop = try aliases_by_key.getOrPut(edge.package_key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (!containsName(gop.value_ptr.items, edge.alias)) try gop.value_ptr.append(scratch, edge.alias);
    }

    var manifest_keys = std.StringHashMap(void).init(scratch);
    try collectDependencyKeys(&manifest.dependencies, &manifest_keys);
    try collectDependencyKeys(&manifest.dev_dependencies, &manifest_keys);

    var root_keys: std.ArrayList([]const u8) = .empty;
    var key_it = aliases_by_key.keyIterator();
    while (key_it.next()) |key| try root_keys.append(scratch, key.*);
    sortNames(root_keys.items);

    var display_by_key = std.StringHashMap([]const u8).init(scratch);
    for (root_keys.items) |package_key| {
        try display_by_key.put(package_key, displayName(&manifest_keys, aliases_by_key.get(package_key).?.items));
    }

    var common_roots: std.ArrayList([]const u8) = .empty;
    var feature_root_keys = std.StringHashMap(std.ArrayList([]const u8)).init(scratch);
    for (root_keys.items) |package_key| {
        const root_aliases = aliases_by_key.get(package_key).?.items;
        var owners: std.ArrayList([]const u8) = .empty;
        var feature_it = feature_aliases.iterator();
        while (feature_it.next()) |entry| {
            if (matchesAnyAlias(entry.value_ptr, root_aliases)) try owners.append(scratch, entry.key_ptr.*);
        }
        // 専用は「ちょうど1つの非 default feature だけが所有」する場合のみ。
        // owner 0（feature 非依存）・複数 owner（共有）・default 所有は共通。
        if (owners.items.len != 1 or containsName(owners.items, "default")) {
            try common_roots.append(scratch, display_by_key.get(package_key).?);
            continue;
        }
        for (owners.items) |owner| {
            const gop = try feature_root_keys.getOrPut(owner);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(scratch, package_key);
        }
    }
    sortNames(common_roots.items);

    var dedicated: std.ArrayList(DedicatedFeature) = .empty;
    var dedicated_features: std.ArrayList([]const u8) = .empty;
    var dedicated_it = feature_root_keys.keyIterator();
    while (dedicated_it.next()) |name| try dedicated_features.append(scratch, name.*);
    sortNames(dedicated_features.items);
    for (dedicated_features.items) |feature_name| {
        const dedicated_keys = feature_root_keys.get(feature_name).?.items;
        var feature_closure = std.StringHashMap(void).init(scratch);
        try collectReachable(scratch, package_edges, dedicated_keys, &feature_closure);
        var baseline_starts: std.ArrayList([]const u8) = .empty;
        for (root_keys.items) |package_key| {
            if (containsName(dedicated_keys, package_key)) continue;
            try baseline_starts.append(scratch, package_key);
        }
        var baseline_closure = std.StringHashMap(void).init(scratch);
        try collectReachable(scratch, package_edges, baseline_starts.items, &baseline_closure);

        // 専用 root からしか到達できない推移依存だけを残す（root 自身は
        // roots 側に出るため packages には含めない）。
        var exclusive: std.ArrayList([]const u8) = .empty;
        var closure_it = feature_closure.keyIterator();
        while (closure_it.next()) |package_key| {
            if (containsName(dedicated_keys, package_key.*)) continue;
            if (baseline_closure.contains(package_key.*)) continue;
            try exclusive.append(scratch, package_key.*);
        }
        sortNames(exclusive.items);

        var root_names: std.ArrayList([]const u8) = .empty;
        for (dedicated_keys) |package_key| try root_names.append(scratch, display_by_key.get(package_key) orelse package_key);
        sortNames(root_names.items);

        try dedicated.append(scratch, .{
            .name = try out.dupe(u8, feature_name),
            .roots = try dupeNames(out, root_names.items),
            .packages = try dupeNames(out, exclusive.items),
        });
    }

    return FeatureImpact{
        .selected = try dupeNames(out, selected_names.items),
        .common_roots = try dupeNames(out, common_roots.items),
        .dedicated = try out.dupe(DedicatedFeature, dedicated.items),
    };
}

fn collectDependencyKeys(group: *const manifest_mod.DependencyGroup, out: *std.StringHashMap(void)) error{OutOfMemory}!void {
    var pkg = group.pkg.keyIterator();
    while (pkg.next()) |key| try out.put(key.*, {});
    var npm = group.npm.keyIterator();
    while (npm.next()) |key| try out.put(key.*, {});
    var path = group.path.keyIterator();
    while (path.next()) |key| try out.put(key.*, {});
    var git = group.git.keyIterator();
    while (git.next()) |key| try out.put(key.*, {});
    var http = group.http.keyIterator();
    while (http.next()) |key| try out.put(key.*, {});
}

/// `starts` から環境 graph を辿った package key 集合。
// ponytail: 辺は線形スキャン。env package 数が数百規模になったら隣接表にする。
fn collectReachable(
    scratch: Allocator,
    edges: []const PackageEdge,
    starts: []const []const u8,
    out: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    var stack: std.ArrayList([]const u8) = .empty;
    for (starts) |start| {
        if (out.contains(start)) continue;
        try out.put(start, {});
        try stack.append(scratch, start);
    }
    while (stack.pop()) |current| {
        for (edges) |edge| {
            if (!std.mem.eql(u8, edge.from, current)) continue;
            if (out.contains(edge.to)) continue;
            try out.put(edge.to, {});
            try stack.append(scratch, edge.to);
        }
    }
}

fn sortNames(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
}

fn containsName(items: []const []const u8, name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn matchesAnyAlias(alias_set: *const std.StringHashMap(void), aliases: []const []const u8) bool {
    for (aliases) |alias| {
        if (alias_set.contains(alias)) return true;
    }
    return false;
}

/// 表示名は manifest の dep key を優先する（feature 定義も dep key で
/// 書かれるため読み手の宣言と一致する）。無ければ alias 昇順の先頭。
fn displayName(manifest_keys: *const std.StringHashMap(void), aliases: []const []const u8) []const u8 {
    var best: ?[]const u8 = null;
    for (aliases) |alias| {
        if (!manifest_keys.contains(alias)) continue;
        if (best == null or std.mem.order(u8, alias, best.?) == .lt) best = alias;
    }
    if (best) |name| return name;
    for (aliases) |alias| {
        if (best == null or std.mem.order(u8, alias, best.?) == .lt) best = alias;
    }
    return best.?;
}

fn dupeNames(out: Allocator, names: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const copy = try out.alloc([]const u8, names.len);
    for (names, 0..) |name, index| copy[index] = try out.dupe(u8, name);
    return copy;
}

/// `check --json` の `features` 値を組み立てる（1 行 JSON、キー順固定）。
pub fn featureImpactJson(gpa: Allocator, impact: FeatureImpact) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, "{\"selected\":");
    try appendJsonNames(gpa, &out, impact.selected);
    try out.appendSlice(gpa, ",\"common\":");
    try appendJsonNames(gpa, &out, impact.common_roots);
    try out.appendSlice(gpa, ",\"dedicated\":[");
    for (impact.dedicated, 0..) |feature, index| {
        if (index > 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "{\"feature\":");
        try appendJsonString(gpa, &out, feature.name);
        try out.appendSlice(gpa, ",\"roots\":");
        try appendJsonNames(gpa, &out, feature.roots);
        try out.appendSlice(gpa, ",\"packages\":");
        try appendJsonNames(gpa, &out, feature.packages);
        try out.appendSlice(gpa, "}");
    }
    try out.appendSlice(gpa, "]}");
    return try out.toOwnedSlice(gpa);
}

fn appendJsonNames(gpa: Allocator, out: *std.ArrayList(u8), names: []const []const u8) error{OutOfMemory}!void {
    try out.appendSlice(gpa, "[");
    for (names, 0..) |name, index| {
        if (index > 0) try out.appendSlice(gpa, ",");
        try appendJsonString(gpa, out, name);
    }
    try out.appendSlice(gpa, "]");
}

fn appendJsonString(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) error{OutOfMemory}!void {
    const quoted = try std.json.Stringify.valueAlloc(gpa, text, .{});
    defer gpa.free(quoted);
    try out.appendSlice(gpa, quoted);
}

/// 表示用のカンマ区切り。空なら空文字列。
pub fn joinNames(gpa: Allocator, names: []const []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |name, index| {
        if (index > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, name);
    }
    return try out.toOwnedSlice(gpa);
}

fn parseCommands(arena: Allocator, commands_value: ?std.json.Value) ![]npkg_commands.Command {
    const value = commands_value orelse return &.{};
    if (value != .array) return &.{};
    var list: std.ArrayList(npkg_commands.Command) = .empty;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const name_v = item.object.get("name") orelse continue;
        if (name_v != .string) continue;
        var command = npkg_commands.Command{
            .name = try arena.dupe(u8, name_v.string),
        };
        if (item.object.get("variable")) |variable| {
            if (variable == .bool) command.variable = variable.bool;
        }
        if (item.object.get("args")) |args| {
            if (args == .array) {
                const slice = try arena.alloc([]const u8, args.array.items.len);
                for (args.array.items, 0..) |arg, i| {
                    slice[i] = if (arg == .string) try arena.dupe(u8, arg.string) else "";
                }
                command.args = slice;
            }
        }
        if (item.object.get("josi")) |josi| {
            if (josi == .array) {
                const slice = try arena.alloc([]const u8, josi.array.items.len);
                for (josi.array.items, 0..) |arg, i| {
                    slice[i] = if (arg == .string) try arena.dupe(u8, arg.string) else "";
                }
                command.josi = slice;
            }
        }
        try list.append(arena, command);
    }
    return try list.toOwnedSlice(arena);
}

fn cloneCommands(arena: Allocator, commands: []const npkg_commands.Command) ![]npkg_commands.Command {
    const out = try arena.alloc(npkg_commands.Command, commands.len);
    for (commands, 0..) |command, i| {
        out[i] = .{
            .name = try arena.dupe(u8, command.name),
            .variable = command.variable,
            .args = try cloneStringSlice(arena, command.args),
            .josi = try cloneStringSlice(arena, command.josi),
        };
    }
    return out;
}

fn cloneStringSlice(arena: Allocator, items: []const []const u8) ![]const []const u8 {
    if (items.len == 0) return &.{};
    const out = try arena.alloc([]const u8, items.len);
    for (items, 0..) |item, i| out[i] = try arena.dupe(u8, item);
    return out;
}

const CompareResult = struct {
    equal: bool,
    detail: []const u8,
};

fn compareCommandLists(a: []const npkg_commands.Command, b: []const npkg_commands.Command) CompareResult {
    if (a.len != b.len) return .{ .equal = false, .detail = "command count differs" };
    for (a) |left| {
        var found = false;
        for (b) |right| {
            if (!std.mem.eql(u8, left.name, right.name)) continue;
            if (left.variable != right.variable) return .{ .equal = false, .detail = "variable flag differs" };
            if (left.args.len != right.args.len or left.josi.len != right.josi.len)
                return .{ .equal = false, .detail = "arity or josi count differs" };
            for (left.args, 0..) |arg, i| {
                if (!std.mem.eql(u8, arg, right.args[i])) return .{ .equal = false, .detail = "args differ" };
            }
            for (left.josi, 0..) |josi, i| {
                if (!std.mem.eql(u8, josi, right.josi[i])) return .{ .equal = false, .detail = "josi differ" };
            }
            found = true;
            break;
        }
        if (!found) return .{ .equal = false, .detail = "command missing from regenerated index" };
    }
    // 逆方向: 件数一致でも a 側の重複名で b の一部が照合漏れになるのを防ぐ。
    for (b) |right| {
        var found = false;
        for (a) |left| {
            if (std.mem.eql(u8, left.name, right.name)) {
                found = true;
                break;
            }
        }
        if (!found) return .{ .equal = false, .detail = "command missing from metadata snapshot" };
    }
    return .{ .equal = true, .detail = "" };
}

fn regenerateCommands(
    gpa: Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    rel_package_path: []const u8,
    exports_value: ?std.json.Value,
    diagnostics: *diag.List,
) error{OutOfMemory}!?npkg_commands_gen.Result {
    if (rel_package_path.len == 0 or std.mem.indexOfScalar(u8, rel_package_path, 0) != null)
        return null;
    // path 依存は `..` を含む sibling を許す。境界外・欠落は openDir/realPath で null。
    var package_dir = root_dir.openDir(io, rel_package_path, .{ .follow_symlinks = false }) catch return null;
    defer package_dir.close(io);

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_len = package_dir.realPath(io, &real_buf) catch return null;
    const real_root = real_buf[0..real_len];

    var provider_state = npkg_commands_gen.DirSourceProvider.init(gpa, io, real_root) catch return null;
    defer gpa.free(provider_state.real_root);

    var entries: std.ArrayList([]const u8) = .empty;
    defer {
        for (entries.items) |path| gpa.free(path);
        entries.deinit(gpa);
    }
    const exports = exports_value orelse return null;
    if (exports != .array) return null;
    for (exports.array.items) |item| {
        if (item != .object) continue;
        const path_v = item.object.get("path") orelse continue;
        if (path_v != .string) continue;
        if (!isNakoSource(path_v.string)) continue;
        if (!npkg_files.isCanonicalPath(path_v.string)) continue;
        try entries.append(gpa, try gpa.dupe(u8, path_v.string));
    }
    if (entries.items.len == 0) return null;

    var local = diag.List.init(gpa);
    defer local.deinit();
    const result = npkg_commands_gen.generate(gpa, provider_state.provider(), entries.items, &local) catch {
        for (local.items.items) |item| {
            diagnostics.add(item.code, item.severity, item.message, item.path, item.position) catch {};
        }
        return null;
    };
    return result;
}

pub fn sharingText(sharing: Sharing) []const u8 {
    return switch (sharing) {
        .skipped => "skipped",
        .guaranteed => "guaranteed",
        .partial => "partial",
        .failed => "failed",
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_sandbox = @import("test_sandbox.zig");

fn writeEnv(dir: std.Io.Dir, body: []const u8) !void {
    const io = testing.io;
    try dir.createDirPath(io, ".nako");
    try dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = body });
}

test "command inspect: source metadata をロードせず検査し guaranteed になる" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib/src/index.nako3",
        .data =
        \\!「./side.nako3」を取り込む
        \\●(AをBに)加算とは
        \\  A+Bで戻る
        \\ここまで
        \\
        ,
    });
    // 副作用を持つ初期化文。export 閉包に入り静的生成が読む。
    // 実行されれば process cwd に marker が書かれる。
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib/src/side.nako3",
        .data =
        \\「ran」を「SIDE_EFFECT.txt」に保存
        \\
        ,
    });
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:11111111111111111111111111111111": {
        \\      "name": "lib",
        \\      "version": "1.0.0",
        \\      "id": "pkg:11111111111111111111111111111111",
        \\      "path": "lib",
        \\      "exports": [{"name": "lib", "path": "src/index.nako3"}],
        \\      "commands": [{"name": "加算", "args": ["A", "B"], "josi": ["を", "に"]}]
        \\    }
        \\  }
        \\}
    );

    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, .{ .strict_sharing = false }, &list);
    defer report.deinit();

    try testing.expectEqual(Sharing.guaranteed, report.sharing);
    try testing.expectEqual(@as(usize, 1), report.inspected_count);
    try testing.expectEqual(@as(usize, 0), report.uninspectedCount());
    try testing.expect(!list.hasErrors());
    // 初期化が走れば process cwd に marker が残る。
    std.Io.Dir.cwd().access(io, "SIDE_EFFECT.txt", .{}) catch |err| {
        try testing.expect(err == error.FileNotFound);
        return;
    };
    try testing.expect(false);
}

test "command inspect: native metadata 不足は partial、strict で E033" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib");
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:22222222222222222222222222222222": {
        \\      "name": "nativepkg",
        \\      "version": "1.0.0",
        \\      "path": "lib",
        \\      "exports": [{"name": "plugin", "native": "plugin.so"}],
        \\      "commands": []
        \\    }
        \\  }
        \\}
    );

    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, .{ .strict_sharing = false }, &list);
    defer report.deinit();
    try testing.expectEqual(Sharing.partial, report.sharing);
    try testing.expectEqual(@as(usize, 1), report.uninspectedCount());
    try testing.expectEqual(UninspectedReason.native_without_metadata, report.uninspected[0].reason);
    try testing.expect(!list.hasErrors());

    var strict_list = diag.List.init(a);
    defer strict_list.deinit();
    var report_strict = try inspectEnvironmentDir(a, io, tmp.dir, .{ .strict_sharing = true }, &strict_list);
    defer report_strict.deinit();
    try testing.expectEqual(Sharing.failed, report_strict.sharing);
    try testing.expect(strict_list.find(diag.E033_STRICT_SHARING_FAILED) != null);
}

test "command inspect: 標準命令との衝突を診断する" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();

    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:33333333333333333333333333333333": {
        \\      "name": "bad",
        \\      "version": "1.0.0",
        \\      "path": "lib",
        \\      "exports": [{"name": "bad", "path": "src/index.nako3"}],
        \\      "commands": [{"name": "表示", "args": [], "josi": []}]
        \\    }
        \\  }
        \\}
    );
    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, .{ .strict_sharing = false }, &list);
    defer report.deinit();
    try testing.expectEqual(Sharing.failed, report.sharing);
    try testing.expect(report.collision_count >= 1);
    try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
}

test "command inspect: package 間の命令名衝突を診断する" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();

    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": {
        \\      "name": "a",
        \\      "version": "1.0.0",
        \\      "path": "a",
        \\      "commands": [{"name": "共通処理", "args": [], "josi": []}]
        \\    },
        \\    "pkg:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": {
        \\      "name": "b",
        \\      "version": "1.0.0",
        \\      "path": "b",
        \\      "commands": [{"name": "共通処理", "args": [], "josi": []}]
        \\    }
        \\  }
        \\}
    );
    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, .{ .strict_sharing = false }, &list);
    defer report.deinit();
    try testing.expectEqual(Sharing.failed, report.sharing);
    try testing.expect(report.collision_count >= 1);
}

test "command inspect: snapshot とソース再生成の不一致を診断する" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib/src/index.nako3",
        .data =
        \\●正しいとは
        \\ここまで
        \\
        ,
    });
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee": {
        \\      "name": "lib",
        \\      "version": "1.0.0",
        \\      "path": "lib",
        \\      "exports": [{"name": "lib", "path": "src/index.nako3"}],
        \\      "commands": [{"name": "間違った", "args": [], "josi": []}]
        \\    }
        \\  }
        \\}
    );
    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, .{ .strict_sharing = false }, &list);
    defer report.deinit();
    try testing.expect(report.mismatch_count >= 1);
    try testing.expectEqual(Sharing.failed, report.sharing);
}

test "command inspect: source 再生成失敗は source_unreadable" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib");
    // export は source を指すがファイルが無い → 再生成失敗。
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:ffffffffffffffffffffffffffffffff": {
        \\      "name": "lib",
        \\      "version": "1.0.0",
        \\      "path": "lib",
        \\      "exports": [{"name": "lib", "path": "src/missing.nako3"}],
        \\      "commands": [{"name": "残る命令", "args": [], "josi": []}]
        \\    }
        \\  }
        \\}
    );
    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, .{ .strict_sharing = false }, &list);
    defer report.deinit();
    try testing.expectEqual(Sharing.partial, report.sharing);
    try testing.expectEqual(@as(usize, 1), report.uninspectedCount());
    try testing.expectEqual(UninspectedReason.source_unreadable, report.uninspected[0].reason);
    // snapshot の衝突検査は継続（inspected に加算される）
    try testing.expectEqual(@as(usize, 1), report.inspected_count);
}

/// feature 影響テスト用の環境と manifest を書く。
/// root 依存 `common`(default) / `req`(http) を持ち、`req` だけが
/// 推移依存 `extra` を引き込む構成。
fn writeFeatureFixture(dir: std.Io.Dir, with_req: bool) !void {
    var env: std.ArrayList(u8) = .empty;
    defer env.deinit(testing.allocator);
    try env.appendSlice(testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "dependencies": [
        \\    {"alias": "common", "package": "pkg:cccccccccccccccccccccccccccccccc"}
    );
    if (with_req) {
        try env.appendSlice(testing.allocator,
            \\,
            \\    {"alias": "req", "package": "pkg:rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr"}
        );
    }
    try env.appendSlice(testing.allocator,
        \\  ],
        \\  "packages": {
        \\    "pkg:cccccccccccccccccccccccccccccccc": {
        \\      "name": "common",
        \\      "version": "1.0.0",
        \\      "path": "lib_common",
        \\      "commands": [{"name": "共通命令", "args": [], "josi": []}]
        \\    }
    );
    if (with_req) {
        try env.appendSlice(testing.allocator,
            \\,
            \\    "pkg:rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr": {
            \\      "name": "req",
            \\      "version": "1.0.0",
            \\      "path": "lib_req",
            \\      "dependencies": [{"alias": "extra", "package": "pkg:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}],
            \\      "commands": [{"name": "要求命令", "args": [], "josi": []}]
            \\    },
            \\    "pkg:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee": {
            \\      "name": "extra",
            \\      "version": "1.0.0",
            \\      "path": "lib_extra",
            \\      "commands": [{"name": "追加命令", "args": [], "josi": []}]
            \\    }
        );
    }
    try env.appendSlice(testing.allocator, "\n  }\n}\n");
    try writeEnv(dir, env.items);
}

const feature_fixture_manifest =
    \\[package]
    \\name = "app"
    \\version = "0.1.0"
    \\license = "MIT"
    \\
    \\[dependencies.path]
    \\common = { path = "lib_common" }
    \\req = { path = "lib_req" }
    \\
    \\[features]
    \\default = ["common"]
    \\http = ["req"]
    \\
;

test "command inspect: 専用推移依存と選択 feature 影響を表示する" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeFeatureFixture(tmp.dir, true);
    try tmp.dir.createDirPath(io, "lib_common");
    try tmp.dir.createDirPath(io, "lib_req");
    try tmp.dir.createDirPath(io, "lib_extra");

    var parse_diags = diag.List.init(a);
    defer parse_diags.deinit();
    var manifest = try manifest_mod.parse(a, feature_fixture_manifest, &parse_diags);
    defer manifest.deinit();
    try testing.expect(!parse_diags.hasErrors());

    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, .{
        .manifest = &manifest,
        .features = .{ .requested = &.{"http"} },
    }, &list);
    defer report.deinit();
    try testing.expectEqual(Sharing.guaranteed, report.sharing);
    try testing.expect(!list.hasErrors());

    const impact = report.features orelse return error.MissingFeatureImpact;
    try testing.expectEqual(@as(usize, 2), impact.selected.len);
    try testing.expectEqualStrings("default", impact.selected[0]);
    try testing.expectEqualStrings("http", impact.selected[1]);
    try testing.expectEqual(@as(usize, 1), impact.common_roots.len);
    try testing.expectEqualStrings("common", impact.common_roots[0]);
    try testing.expectEqual(@as(usize, 1), impact.dedicated.len);
    try testing.expectEqualStrings("http", impact.dedicated[0].name);
    try testing.expectEqual(@as(usize, 1), impact.dedicated[0].roots.len);
    try testing.expectEqualStrings("req", impact.dedicated[0].roots[0]);
    // req → extra は共通 root から到達できないため専用推移依存。
    try testing.expectEqual(@as(usize, 1), impact.dedicated[0].packages.len);
    try testing.expectEqualStrings("pkg:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", impact.dedicated[0].packages[0]);
}

test "command inspect: 未選択 feature の依存は専用に出さない" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    // 環境は default 選択（req 無し）で構築済み。
    try writeFeatureFixture(tmp.dir, false);
    try tmp.dir.createDirPath(io, "lib_common");

    var parse_diags = diag.List.init(a);
    defer parse_diags.deinit();
    var manifest = try manifest_mod.parse(a, feature_fixture_manifest, &parse_diags);
    defer manifest.deinit();

    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, .{
        .manifest = &manifest,
    }, &list);
    defer report.deinit();
    const impact = report.features orelse return error.MissingFeatureImpact;
    try testing.expectEqual(@as(usize, 1), impact.selected.len);
    try testing.expectEqualStrings("default", impact.selected[0]);
    try testing.expectEqual(@as(usize, 1), impact.common_roots.len);
    try testing.expectEqualStrings("common", impact.common_roots[0]);
    try testing.expectEqual(@as(usize, 0), impact.dedicated.len);
}

test "command inspect: 複数非 default feature が共有する root は common_roots へ" {
    // shared を http と ssl の両方が引き込む構成。owner が 2 件でも
    // 各 dedicated に重複せず common に分類されること。
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "dependencies": [
        \\    {"alias": "shared", "package": "pkg:ssssssssssssssssssssssssssssssss"}
        \\  ],
        \\  "packages": {
        \\    "pkg:ssssssssssssssssssssssssssssssss": {
        \\      "name": "shared",
        \\      "version": "1.0.0",
        \\      "path": "lib_shared",
        \\      "commands": [{"name": "共有命令", "args": [], "josi": []}]
        \\    }
        \\  }
        \\}
    );
    try tmp.dir.createDirPath(io, "lib_shared");

    var parse_diags = diag.List.init(a);
    defer parse_diags.deinit();
    var manifest = try manifest_mod.parse(a,
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\shared = { path = "lib_shared" }
        \\
        \\[features]
        \\http = ["shared"]
        \\ssl = ["shared"]
        \\
    , &parse_diags);
    defer manifest.deinit();
    try testing.expect(!parse_diags.hasErrors());

    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, .{
        .manifest = &manifest,
        .features = .{ .requested = &.{ "http", "ssl" }, .use_default_features = false },
    }, &list);
    defer report.deinit();
    try testing.expect(!list.hasErrors());

    const impact = report.features orelse return error.MissingFeatureImpact;
    try testing.expectEqual(@as(usize, 1), impact.common_roots.len);
    try testing.expectEqualStrings("shared", impact.common_roots[0]);
    try testing.expectEqual(@as(usize, 0), impact.dedicated.len);
}

test "command inspect: feature 定義が無ければ影響を表示しない" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeFeatureFixture(tmp.dir, true);

    var parse_diags = diag.List.init(a);
    defer parse_diags.deinit();
    var manifest = try manifest_mod.parse(a,
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\common = { path = "lib_common" }
        \\
    , &parse_diags);
    defer manifest.deinit();

    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, .{
        .manifest = &manifest,
    }, &list);
    defer report.deinit();
    try testing.expect(report.features == null);
}

test "command inspect: feature 影響 JSON は固定順で出力する" {
    const a = testing.allocator;
    const impact = FeatureImpact{
        .selected = &.{ "default", "http" },
        .common_roots = &.{"common"},
        .dedicated = &.{.{
            .name = "http",
            .roots = &.{"req"},
            .packages = &.{"pkg:extra"},
        }},
    };
    const json = try featureImpactJson(a, impact);
    defer a.free(json);
    try testing.expectEqualStrings(
        "{\"selected\":[\"default\",\"http\"],\"common\":[\"common\"],\"dedicated\":[{\"feature\":\"http\",\"roots\":[\"req\"],\"packages\":[\"pkg:extra\"]}]}",
        json,
    );

    const empty = try featureImpactJson(a, .{});
    defer a.free(empty);
    try testing.expectEqualStrings("{\"selected\":[],\"common\":[],\"dedicated\":[]}", empty);
}
